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

set -a
# shellcheck disable=SC1091
. ./.env
set +a

# ------------------------------------------------------------------ 端口检查
# 本项目的容器已经在跑时（重复执行）不检查，端口本来就是它们占着的
if [ -z "$(docker compose ps -q 2>/dev/null)" ]; then
  for pair in "LITELLM_PORT:${LITELLM_PORT}" "LANGFUSE_PORT:${LANGFUSE_PORT}" "MINIO_PORT:${MINIO_PORT}"; do
    name="${pair%%:*}"
    port="${pair##*:}"
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
      die "端口 ${port} 已被占用。请在 .env 里把 ${name} 改成一个空闲端口，然后重新执行 ./deploy.sh"
    fi
  done
fi

# ------------------------------------------------------------------ 启动
info "拉取镜像（第一次需要几分钟，取决于网络）"
docker compose pull --quiet || die "镜像拉取失败。网络受限时，可以在 .env 里用 *_IMAGE 变量换成可访问的镜像地址（见 README）"

info "启动服务并等待全部就绪（第一次要初始化数据库，通常 1 到 3 分钟）"
if ! docker compose up -d --wait; then
  docker compose ps
  die "有服务没能正常启动，可以用 docker compose logs <服务名> 查看原因"
fi

# ------------------------------------------------------------------ 账号密码文件
LANGFUSE_URL="http://${PUBLIC_HOST}:${LANGFUSE_PORT}"
GATEWAY_URL="http://${PUBLIC_HOST}:${LITELLM_PORT}"
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

## 二、内部组件（不对宿主机开放，只在容器网络内可见）

| 组件 | 容器内地址 | 用户名 | 密码 | 需要时这样进去 |
|---|---|---|---|---|
| PostgreSQL | postgres:5432 | \`postgres\` | \`${POSTGRES_PASSWORD}\` | \`docker compose exec postgres psql -U postgres -d litellm\`（或 \`-d langfuse\`） |
| ClickHouse | clickhouse:8123 | \`clickhouse\` | \`${CLICKHOUSE_PASSWORD}\` | \`docker compose exec clickhouse clickhouse-client --password '${CLICKHOUSE_PASSWORD}'\` |
| Redis | redis:6379 | （无） | \`${REDIS_AUTH}\` | \`docker compose exec redis redis-cli\` |
| MinIO | minio:9000（宿主机端口 ${MINIO_PORT}） | \`minio\` | \`${MINIO_ROOT_PASSWORD}\` | 桶名 \`langfuse\`，存 Langfuse 收到的原始事件和媒体文件 |

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

cat <<EOF

部署完成。
  Langfuse 控制台:  ${LANGFUSE_URL}
  网关 API:         ${GATEWAY_URL}/v1
  网关管理界面:     ${GATEWAY_URL}/ui
  账号密码:         $(pwd)/CREDENTIALS.md

下一步：在网关管理界面 Models + Endpoints 里添加你自己的模型，之后经网关的调用都会出现在 Langfuse 里。
EOF
