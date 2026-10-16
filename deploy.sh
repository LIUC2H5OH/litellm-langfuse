#!/usr/bin/env bash
# 一键部署 LiteLLM 网关 + Langfuse。
#
#   ./deploy.sh                    只允许本机访问（http://localhost:4000、http://localhost:3000）
#   ./deploy.sh --host 10.0.0.5    允许其他机器通过这个 IP 或域名访问（端口对所有网卡开放）
#
# 可以重复执行：已有的 .env 会被沿用，不会重新生成密码。
# 部署完成后，所有账号密码写在 CREDENTIALS.md 里。
set -euo pipefail
cd "$(dirname "$0")"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[警告]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

HOST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host)
      [ $# -ge 2 ] && [ -n "$2" ] || die "--host 后面要跟 IP 或域名"
      HOST="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "不认识的参数：$1（用 ./deploy.sh --help 查看用法）" ;;
  esac
done

# ------------------------------------------------------------------ 环境检查
command -v docker >/dev/null 2>&1 || die "没有找到 docker，请先安装 Docker"
docker info >/dev/null 2>&1 || die "Docker 没有运行，或当前用户没有权限访问 Docker（Linux 上可以试试 sudo ./deploy.sh）"
docker compose version >/dev/null 2>&1 || die "需要 Docker Compose v2（docker compose 子命令）"

rand_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$1"
  else
    od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
  fi
}

# 修改 .env 里的一个变量，没有就追加（用 cat 回写以保留文件权限）
set_env() {
  local tmp
  tmp="$(mktemp)"
  awk -v k="$1" -v v="$2" '$0 ~ "^"k"=" { print k"="v; found=1; next } { print } END { if (!found) print k"="v }' .env >"$tmp"
  cat "$tmp" >.env
  rm -f "$tmp"
}

port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# 标准端口被占用时改用 +10000 的端口（如 5432 -> 15432），避免和机器上已有的数据库、Redis 冲突
pick_port() {
  if ! port_in_use "$1"; then
    echo "$1"
  elif ! port_in_use $(($1 + 10000)); then
    echo $(($1 + 10000))
  else
    echo "$1"
  fi
}

# 给 .env 补上中间件调试端口的配置：首次部署时生成，从旧版本升级时补齐
ensure_middleware_ports() {
  local pair key std port
  grep -q '^MIDDLEWARE_BIND_ADDRESS=' .env ||
    printf '\n# ---------- 中间件调试端口（宿主机端口） ----------\nMIDDLEWARE_BIND_ADDRESS=127.0.0.1\n' >>.env
  for pair in POSTGRES_PORT:5432 CLICKHOUSE_HTTP_PORT:8123 CLICKHOUSE_NATIVE_PORT:9000 REDIS_PORT:6379 MINIO_CONSOLE_PORT:9091; do
    key="${pair%%:*}"
    std="${pair##*:}"
    grep -q "^${key}=" .env && continue
    port="$(pick_port "$std")"
    [ "$port" != "$std" ] && info "端口 ${std} 已被占用，${key} 改用 ${port}"
    printf '%s=%s\n' "$key" "$port" >>.env
  done
}

# 给 .env 补上功能开关：首次部署时生成，从旧版本升级时补齐
ensure_feature_switches() {
  grep -q '^LANGFUSE_LOG_REASONING=' .env ||
    printf '\n# ---------- 功能开关 ----------\n# 是否把模型的思维链（reasoning_content）写进 Langfuse 的输出：true 开启，false 关闭。\n# 改完重新执行 ./deploy.sh 生效。\nLANGFUSE_LOG_REASONING=true\n' >>.env
  grep -q '^LANGFUSE_LOG_RAW_PAYLOAD=' .env ||
    printf '# 是否把原始请求和响应 JSON 原样（不截断）附加到 Langfuse：true 开启，false 关闭（默认）。\n# 原始请求里有完整请求头和 key 的鉴权信息。改完重新执行 ./deploy.sh 生效。\nLANGFUSE_LOG_RAW_PAYLOAD=false\n' >>.env
  grep -q '^OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=' .env ||
    printf '# 是否生成 raw_gen_ai_request 子记录（发给模型服务商的原始请求和响应）：false 不生成，留空为 LiteLLM 默认（生成）。\n# 不影响 litellm_request 记录的 input/output。改完重新执行 ./deploy.sh 生效。\nOTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=\n' >>.env
}

# ------------------------------------------------------------------ 生成 .env
if [ ! -f .env ]; then
  info "首次部署：生成随机密钥，写入 .env"
  if [ -n "$HOST" ]; then public_host="$HOST" bind_address="0.0.0.0"; else public_host="localhost" bind_address="127.0.0.1"; fi
  (
    umask 077
    cat >.env <<EOF
# 由 deploy.sh 生成，含明文密钥，不要提交到版本库。说明见 .env.example。

# ---------- 访问方式 ----------
COMPOSE_PROJECT_NAME=llm-gateway
PUBLIC_HOST=${public_host}
BIND_ADDRESS=${bind_address}
LITELLM_PORT=4000
LANGFUSE_PORT=3000
MINIO_PORT=9090

# ---------- 基础组件 ----------
POSTGRES_PASSWORD=$(rand_hex 16)
CLICKHOUSE_PASSWORD=$(rand_hex 16)
REDIS_AUTH=$(rand_hex 16)
MINIO_ROOT_PASSWORD=$(rand_hex 16)

# ---------- Langfuse ----------
NEXTAUTH_SECRET=$(rand_hex 32)
LANGFUSE_SALT=$(rand_hex 16)
LANGFUSE_ENCRYPTION_KEY=$(rand_hex 32)
TELEMETRY_ENABLED=false
LANGFUSE_INIT_ORG_ID=default-org
LANGFUSE_INIT_ORG_NAME=Default
LANGFUSE_INIT_PROJECT_ID=llm-gateway
LANGFUSE_INIT_PROJECT_NAME="LLM Gateway"
LANGFUSE_INIT_PROJECT_PUBLIC_KEY=pk-lf-$(rand_hex 16)
LANGFUSE_INIT_PROJECT_SECRET_KEY=sk-lf-$(rand_hex 16)
LANGFUSE_INIT_USER_EMAIL=admin@langfuse.local
LANGFUSE_INIT_USER_NAME=admin
LANGFUSE_INIT_USER_PASSWORD=Lf-$(rand_hex 10)

# ---------- LiteLLM ----------
LITELLM_MASTER_KEY=sk-$(rand_hex 24)
LITELLM_SALT_KEY=sk-$(rand_hex 24)
EOF
  )
elif [ -n "$HOST" ]; then
  info "沿用已有的 .env，把访问地址改为 ${HOST}"
  set_env PUBLIC_HOST "$HOST"
  set_env BIND_ADDRESS 0.0.0.0
else
  info "沿用已有的 .env"
fi
ensure_middleware_ports
ensure_feature_switches

set -a
# shellcheck disable=SC1091
. ./.env
set +a

# ------------------------------------------------------------------ 端口检查
# 本项目的容器已经在跑时（重复执行）不检查，端口本来就是它们占着的
if [ -z "$(docker compose ps -q 2>/dev/null)" ]; then
  for pair in "LITELLM_PORT:${LITELLM_PORT}" "LANGFUSE_PORT:${LANGFUSE_PORT}" "MINIO_PORT:${MINIO_PORT}" \
    "POSTGRES_PORT:${POSTGRES_PORT}" "CLICKHOUSE_HTTP_PORT:${CLICKHOUSE_HTTP_PORT}" \
    "CLICKHOUSE_NATIVE_PORT:${CLICKHOUSE_NATIVE_PORT}" "REDIS_PORT:${REDIS_PORT}" "MINIO_CONSOLE_PORT:${MINIO_CONSOLE_PORT}"; do
    name="${pair%%:*}"
    port="${pair##*:}"
    if port_in_use "$port"; then
      die "端口 ${port} 已被占用。请在 .env 里把 ${name} 改成一个空闲端口，然后重新执行 ./deploy.sh"
    fi
  done
fi

# ------------------------------------------------------------------ 启动
info "拉取镜像（第一次需要几分钟，取决于网络）"
if ! docker compose pull --quiet; then
  # 网络波动时拉取会失败；本机已经有全部镜像（比如重复部署）就继续用本地的
  missing=""
  for img in $(docker compose config --images); do
    docker image inspect "$img" >/dev/null 2>&1 || missing="${missing} ${img}"
  done
  [ -z "$missing" ] || die "镜像拉取失败，本机也没有这些镜像:${missing}。网络受限时，可以在 .env 里用 *_IMAGE 变量换成可访问的镜像地址（见 README）"
  warn "镜像拉取失败（可能是网络波动），本机已有全部所需镜像，继续使用本地镜像"
fi

info "启动服务并等待全部就绪（第一次要初始化数据库，通常 1 到 3 分钟）"
if ! docker compose up -d --wait; then
  docker compose ps
  die "有服务没能正常启动，可以用 docker compose logs <服务名> 查看原因"
fi

# ------------------------------------------------------------------ 账号密码文件
LANGFUSE_URL="http://${PUBLIC_HOST}:${LANGFUSE_PORT}"
GATEWAY_URL="http://${PUBLIC_HOST}:${LITELLM_PORT}"
MINIO_S3_URL="http://${PUBLIC_HOST}:${MINIO_PORT}"
SSH_SECTION=""
case "${MIDDLEWARE_BIND_ADDRESS}" in
  127.0.0.1 | localhost)
    MW_HOST=127.0.0.1
    MW_SCOPE="只允许这台机器本身连接。从其他电脑调试请用文末的 SSH 隧道；或者把 .env 里的 MIDDLEWARE_BIND_ADDRESS 改成 0.0.0.0 再执行 ./deploy.sh（公网机器不建议）。"
    SSH_SECTION=$(
      cat <<EOF

### 从其他电脑调试：SSH 隧道

在你自己的电脑上执行，保持这个窗口不关，然后用上面的端口连接 \`127.0.0.1\` 即可：

\`\`\`bash
ssh -N -L ${POSTGRES_PORT}:127.0.0.1:${POSTGRES_PORT} -L ${CLICKHOUSE_HTTP_PORT}:127.0.0.1:${CLICKHOUSE_HTTP_PORT} -L ${CLICKHOUSE_NATIVE_PORT}:127.0.0.1:${CLICKHOUSE_NATIVE_PORT} -L ${REDIS_PORT}:127.0.0.1:${REDIS_PORT} -L ${MINIO_CONSOLE_PORT}:127.0.0.1:${MINIO_CONSOLE_PORT} <用户名>@<这台服务器的地址>
\`\`\`
EOF
    )
    ;;
  0.0.0.0)
    MW_HOST="${PUBLIC_HOST}"
    MW_SCOPE="已对所有网卡开放，能访问这台机器的人都可以尝试连接，请用防火墙只放行可信的机器。"
    ;;
  *)
    MW_HOST="${MIDDLEWARE_BIND_ADDRESS}"
    MW_SCOPE="绑定在 ${MIDDLEWARE_BIND_ADDRESS} 这块网卡上。"
    ;;
esac
(
  umask 077
  cat >CREDENTIALS.md <<EOF
# 账户密码汇总

> 由 deploy.sh 于 $(date '+%Y-%m-%d %H:%M:%S') 生成。**含全部明文密钥，不要提交到版本库、不要外发。**
> 实际生效的值以 .env 为准；改了 .env 后重新执行 ./deploy.sh 会刷新本文件。

## 一、日常会用到的

### 1. Langfuse 控制台（查看每次调用的请求和响应）

| 项 | 值 |
|---|---|
| 地址 | ${LANGFUSE_URL} |
| 邮箱 | \`${LANGFUSE_INIT_USER_EMAIL}\` |
| 密码 | \`${LANGFUSE_INIT_USER_PASSWORD}\` |
| 组织 / 项目 | ${LANGFUSE_INIT_ORG_NAME} / ${LANGFUSE_INIT_PROJECT_NAME}（项目 ID \`${LANGFUSE_INIT_PROJECT_ID}\`） |

### 2. Langfuse 项目 API Key（网关写日志用；你用 API 查日志时也用它）

| 项 | 值 |
|---|---|
| Public Key | \`${LANGFUSE_INIT_PROJECT_PUBLIC_KEY}\` |
| Secret Key | \`${LANGFUSE_INIT_PROJECT_SECRET_KEY}\` |
| Host | ${LANGFUSE_URL} |

调用 Langfuse 公共 API 时用 HTTP Basic 认证：用户名填 Public Key，密码填 Secret Key。

### 3. LiteLLM 网关

| 项 | 值 |
|---|---|
| API 地址（OpenAI 兼容） | ${GATEWAY_URL}/v1 |
| Master Key（管理员密钥） | \`${LITELLM_MASTER_KEY}\` |
| 管理界面 | ${GATEWAY_URL}/ui |
| 管理界面用户名 | \`admin\` |
| 管理界面密码 | 同 Master Key |

Master Key 权限最大。给应用或其他人用时，请在管理界面 Virtual Keys 里另发独立的 key。

## 二、中间件（调试用）

| 中间件 | 地址 | 用户名 | 密码 | 存的是什么 |
|---|---|---|---|---|
| PostgreSQL | \`${MW_HOST}:${POSTGRES_PORT}\` | \`postgres\` | \`${POSTGRES_PASSWORD}\` | 库 \`litellm\`：网关的 key、模型、用量、请求日志；库 \`langfuse\`：Langfuse 的账号、项目、API Key |
| ClickHouse | HTTP \`${MW_HOST}:${CLICKHOUSE_HTTP_PORT}\`，原生协议 \`${MW_HOST}:${CLICKHOUSE_NATIVE_PORT}\` | \`clickhouse\` | \`${CLICKHOUSE_PASSWORD}\` | Langfuse 的日志正文（库 \`default\`） |
| Redis | \`${MW_HOST}:${REDIS_PORT}\` | （无） | \`${REDIS_AUTH}\` | Langfuse 的任务队列 |
| MinIO | S3 接口 ${MINIO_S3_URL}，网页控制台 http://${MW_HOST}:${MINIO_CONSOLE_PORT} | \`minio\` | \`${MINIO_ROOT_PASSWORD}\` | 桶 \`langfuse\`：Langfuse 收到的原始事件（events/）和媒体文件（media/） |

> 中间件端口的访问范围：${MW_SCOPE}

不想在本机装客户端时，每个中间件都可以用 \`docker compose exec\` 直接进去（在部署目录下执行）。

### PostgreSQL

\`\`\`text
postgresql://postgres:${POSTGRES_PASSWORD}@${MW_HOST}:${POSTGRES_PORT}/litellm
postgresql://postgres:${POSTGRES_PASSWORD}@${MW_HOST}:${POSTGRES_PORT}/langfuse
\`\`\`

\`\`\`bash
psql "postgresql://postgres:${POSTGRES_PASSWORD}@${MW_HOST}:${POSTGRES_PORT}/litellm"
docker compose exec postgres psql -U postgres -d litellm
\`\`\`

\`litellm\` 库里常看的表：\`"LiteLLM_SpendLogs"\`（每次请求的用量、费用、耗时；打开“存储请求和响应”后还有正文）、\`"LiteLLM_VerificationToken"\`（发放的 key）、\`"LiteLLM_ProxyModelTable"\`（界面里添加的模型）、\`"LiteLLM_Config"\`（界面里改过的设置）。表名有大写字母，SQL 里要加双引号。

### ClickHouse

DBeaver、DataGrip 等图形客户端用 HTTP 端口 ${CLICKHOUSE_HTTP_PORT} 连接，数据库填 \`default\`。

\`\`\`bash
curl -u 'clickhouse:${CLICKHOUSE_PASSWORD}' 'http://${MW_HOST}:${CLICKHOUSE_HTTP_PORT}/' --data-binary 'SELECT count() FROM events_full'
clickhouse-client --host ${MW_HOST} --port ${CLICKHOUSE_NATIVE_PORT} --user clickhouse --password '${CLICKHOUSE_PASSWORD}'
docker compose exec clickhouse clickhouse-client --password '${CLICKHOUSE_PASSWORD}'
\`\`\`

常看的表：\`events_full\`（每次调用的完整记录，输入输出全文）、\`events_core\`（同一批记录的精简副本，输入输出只留前 200 字符）、\`scores\`（评分）。例如看最近 10 条：

\`\`\`sql
SELECT start_time, type, name, substring(output, 1, 200) FROM events_full ORDER BY start_time DESC LIMIT 10
\`\`\`

### Redis

\`\`\`bash
redis-cli -h ${MW_HOST} -p ${REDIS_PORT} -a '${REDIS_AUTH}'
docker compose exec redis redis-cli
\`\`\`

连接串：\`redis://:${REDIS_AUTH}@${MW_HOST}:${REDIS_PORT}/0\`

### MinIO

网页控制台 http://${MW_HOST}:${MINIO_CONSOLE_PORT} ，用户名 \`minio\`，密码同上。命令行：

\`\`\`bash
mc alias set llm-gateway ${MINIO_S3_URL} minio '${MINIO_ROOT_PASSWORD}'
mc ls --recursive llm-gateway/langfuse/events/
\`\`\`

S3 客户端配置：Endpoint \`${MINIO_S3_URL}\`，Access Key \`minio\`，Secret Key 同密码，开启 path-style。
${SSH_SECTION}

## 三、内部密钥（不是登录用的，设定后不要改）

| 变量 | 值 | 改了会怎样 |
|---|---|---|
| \`NEXTAUTH_SECRET\` | \`${NEXTAUTH_SECRET}\` | 所有人需要重新登录 Langfuse |
| \`LANGFUSE_SALT\` | \`${LANGFUSE_SALT}\` | 现有 Langfuse API Key 全部失效 |
| \`LANGFUSE_ENCRYPTION_KEY\` | \`${LANGFUSE_ENCRYPTION_KEY}\` | Langfuse 已加密的数据无法解密 |
| \`LITELLM_SALT_KEY\` | \`${LITELLM_SALT_KEY}\` | 在管理界面里添加的模型凭据无法解密 |

## 四、改密码须知

除 LiteLLM Master Key 外，上面的密码都是在数据第一次初始化时写进去的，之后只改 .env 不会生效，还会导致服务连不上。

- 改 Master Key：改 .env 的 \`LITELLM_MASTER_KEY\`，再执行 \`docker compose up -d\`。
- 其他密码：测试环境最省事的办法是 \`docker compose down -v\`（会删除全部数据），删掉 .env，再执行 \`./deploy.sh\` 重新生成。
- Langfuse 界面里的"修改密码"要给邮箱发验证码，本部署没有配置邮件服务，所以用不了。
EOF
)
info "账号密码已写入 CREDENTIALS.md"

# ------------------------------------------------------------------ 自检
if command -v curl >/dev/null 2>&1; then
  info "端到端自检：经网关调用内置模拟模型，确认请求和响应已写入 Langfuse"
  scripts/verify.sh || warn "自检没有通过，服务已经启动，可以稍后手动执行 scripts/verify.sh 再试"
else
  warn "没有找到 curl，跳过自检"
fi

case "$(printf '%s' "${OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT:-}" | tr '[:upper:]' '[:lower:]')" in
  false | 0 | no_content) raw_span_state="不生成" ;;
  '') raw_span_state="生成（LiteLLM 默认）" ;;
  *) raw_span_state="${OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT}" ;;
esac

cat <<EOF

部署完成。
  Langfuse 控制台:  ${LANGFUSE_URL}
  网关 API:         ${GATEWAY_URL}/v1
  网关管理界面:     ${GATEWAY_URL}/ui
  中间件调试端口:   PostgreSQL ${POSTGRES_PORT}、ClickHouse ${CLICKHOUSE_HTTP_PORT}/${CLICKHOUSE_NATIVE_PORT}、Redis ${REDIS_PORT}、MinIO 控制台 ${MINIO_CONSOLE_PORT}
  思维链写入 Langfuse: ${LANGFUSE_LOG_REASONING}（.env 里的 LANGFUSE_LOG_REASONING）
  原始报文写入 Langfuse: ${LANGFUSE_LOG_RAW_PAYLOAD}（.env 里的 LANGFUSE_LOG_RAW_PAYLOAD）
  原始请求子记录:   ${raw_span_state}（.env 里的 OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT）
  账号密码:         $(pwd)/CREDENTIALS.md

下一步：在网关管理界面 Models + Endpoints 里添加你自己的模型，之后经网关的调用都会出现在 Langfuse 里。
EOF
