#!/usr/bin/env bash
# 端到端自检：经网关调用一次模型，再确认这次调用的请求和响应已写入 Langfuse。
#
#   scripts/verify.sh               用内置的模拟模型 mock-model，不需要任何 API key
#   scripts/verify.sh <模型名>       用你在网关里添加的真实模型（会产生一次真实调用）
#
# 只依赖 bash 和 curl。全部通过时退出码为 0。
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "没有找到 .env，请先执行 ./deploy.sh" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
. ./.env
set +a

MODEL="${1:-mock-model}"
ADDR="${BIND_ADDRESS:-127.0.0.1}"
[ "$ADDR" = "0.0.0.0" ] && ADDR=127.0.0.1
GATEWAY="http://${ADDR}:${LITELLM_PORT:-4000}"
LANGFUSE="http://${ADDR}:${LANGFUSE_PORT:-3000}"
LF_AUTH="${LANGFUSE_INIT_PROJECT_PUBLIC_KEY}:${LANGFUSE_INIT_PROJECT_SECRET_KEY}"
# Langfuse 是异步落库的（OTEL -> 队列 -> ClickHouse），留出轮询时间
POLL_SECONDS=90

ok() { printf '[OK]   %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

rand_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$1"
  else
    od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
  fi
}

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${GATEWAY}/health/liveliness" || true)
[ "$code" = "200" ] || fail "LiteLLM 网关不可用：${GATEWAY} 返回 HTTP ${code}"
ok "LiteLLM 网关存活  ${GATEWAY}"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${LANGFUSE}/api/public/health" || true)
[ "$code" = "200" ] || fail "Langfuse 不可用：${LANGFUSE} 返回 HTTP ${code}"
ok "Langfuse 存活  ${LANGFUSE}"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -u "$LF_AUTH" "${LANGFUSE}/api/public/projects" || true)
[ "$code" = "200" ] || fail "Langfuse 项目 API Key 无效：HTTP ${code}"
ok "Langfuse 项目 API Key 有效"

# 自己生成 trace ID，经 traceparent 头传给网关，之后按这个 ID 去 Langfuse 精确查找
trace_id="$(rand_hex 16)"
marker="verify-${trace_id}"
body=$(printf '{"model":"%s","messages":[{"role":"user","content":"[%s] Reply with one short sentence."}],"max_tokens":800,"user":"verify-script","metadata":{"tags":["verify"]}}' "$MODEL" "$marker")
resp=$(curl -s --max-time 180 -w '\n%{http_code}' "${GATEWAY}/v1/chat/completions" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -H "traceparent: 00-${trace_id}-$(rand_hex 8)-01" \
  -d "$body" || true)
code="${resp##*$'\n'}"
resp="${resp%$'\n'*}"
[ "$code" = "200" ] || fail "经网关调用 ${MODEL} 失败：HTTP ${code} ${resp:0:300}"
grep -Eq '"content": ?"[^"]' <<<"$resp" || fail "模型返回了空回答（思考型模型请检查 max_tokens 是否够用）：${resp:0:300}"
ok "经网关调用 ${MODEL} 成功"

found=""
deadline=$(($(date +%s) + POLL_SECONDS))
while [ "$(date +%s)" -lt "$deadline" ]; do
  obs=$(curl -s --max-time 15 -u "$LF_AUTH" \
    "${LANGFUSE}/api/public/v2/observations?traceId=${trace_id}&type=GENERATION&fields=core,basic,io" || true)
  if grep -q "$marker" <<<"$obs"; then
    found=1
    break
  fi
  sleep 3
done
[ -n "$found" ] || fail "${POLL_SECONDS} 秒内没有在 Langfuse 里找到这次调用，请查看 docker compose logs litellm langfuse-worker"
ok "Langfuse 中找到了这次调用"

grep -q '"output":null' <<<"$obs" && fail "Langfuse 里这次调用的响应正文为空"
ok "请求和响应正文都已写入 Langfuse"

# 思维链：只有模型确实返回了思维链、且开关开着时才检查（内置模拟模型没有思维链）
case "$(printf '%s' "${LANGFUSE_LOG_REASONING:-true}" | tr '[:upper:]' '[:lower:]')" in
  false | 0 | no | off)
    printf '[--]   思维链写入已关闭（LANGFUSE_LOG_REASONING=false），跳过思维链检查\n'
    ;;
  *)
    if grep -Eq '"reasoning_content": ?"[^"]' <<<"$resp"; then
      grep -q 'thinking' <<<"$obs" || fail "模型返回了思维链，但 Langfuse 输出里没有（检查 litellm 启动日志里的 langfuse_reasoning 一行）"
      ok "思维链已写入 Langfuse 输出"
    else
      printf '[--]   模型没有返回思维链，跳过思维链检查\n'
    fi
    ;;
esac

# 原始请求和响应：开关开着时检查两项都已附加到 Langfuse
case "$(printf '%s' "${LANGFUSE_LOG_RAW_PAYLOAD:-false}" | tr '[:upper:]' '[:lower:]')" in
  true | 1 | yes | on)
    meta=$(curl -s --max-time 15 -u "$LF_AUTH" \
      "${LANGFUSE}/api/public/v2/observations?traceId=${trace_id}&type=GENERATION&fields=core,metadata" || true)
    grep -q 'litellm.raw_request' <<<"$meta" && grep -q 'litellm.raw_response' <<<"$meta" ||
      fail "开关已开启，但 Langfuse 里没有原始请求或响应（检查 litellm 启动日志里的 langfuse_raw_payload 一行）"
    ok "原始请求和响应 JSON 已附加到 Langfuse"
    ;;
  *)
    printf '[--]   原始报文写入未开启（LANGFUSE_LOG_RAW_PAYLOAD=false），跳过检查\n'
    ;;
esac

printf '\n全部通过。在界面里查看这条记录:\n  http://%s:%s/project/%s/traces/%s\n' \
  "${PUBLIC_HOST:-localhost}" "${LANGFUSE_PORT:-3000}" "${LANGFUSE_INIT_PROJECT_ID}" "$trace_id"
