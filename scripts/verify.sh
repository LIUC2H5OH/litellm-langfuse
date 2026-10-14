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

printf '\n全部通过。在界面里查看这条记录:\n  http://%s:%s/project/%s/traces/%s\n' \
  "${PUBLIC_HOST:-localhost}" "${LANGFUSE_PORT:-3000}" "${LANGFUSE_INIT_PROJECT_ID}" "$trace_id"
