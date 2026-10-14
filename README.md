# LiteLLM + Langfuse 一键部署

在任意一台装了 Docker 的机器上，一条命令部署 **LiteLLM 网关**和自托管的 **Langfuse**，并把两者对接好：应用通过网关（OpenAI 兼容接口）调用任意大模型，**每一次调用的请求和响应全文**都会自动写入 Langfuse，可以在网页上逐条查看、检索和统计。

- 部署时自动生成全部随机密码，部署完成后汇总到 `CREDENTIALS.md`
- 内置一个模拟模型，不需要任何 API key 就能验证对接是否成功
- 真实模型部署后在网关管理界面里添加，不需要改代码、不需要重启

## 目录

- [架构](#架构)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [部署后得到什么](#部署后得到什么)
- [接入自己的模型](#接入自己的模型)
- [调用网关](#调用网关)
- [在 Langfuse 里看日志](#在-langfuse-里看日志)
- [对接是怎么实现的](#对接是怎么实现的)
- [配置项](#配置项)
- [运维](#运维)
- [排错](#排错)
- [安全说明](#安全说明)
- [测试情况](#测试情况)

## 架构

```
你的应用 / curl / OpenAI SDK
      │   OpenAI 兼容 API，Authorization: Bearer <网关 key>
      ▼
LiteLLM 网关 (:4000) ─────────▶ 任意大模型服务（OpenAI、DeepSeek、通义、本地模型……）
      │
      │   每次调用结束后异步上报请求和响应（OpenTelemetry），不阻塞业务请求
      ▼
Langfuse web (:3000) ──▶ Redis 队列 ──▶ Langfuse worker
                                             │
                  ┌──────────────────────────┼──────────────────────┐
                  ▼                          ▼                      ▼
         ClickHouse（日志正文）    PostgreSQL（账号、配置）    MinIO（原始事件）
```

| 服务 | 镜像 | 作用 |
|---|---|---|
| `litellm` | `docker.litellm.ai/berriai/litellm:v1.96.2` | 网关：统一接口、鉴权、路由、用量与费用统计 |
| `langfuse-web` | `langfuse/langfuse:4.55.0` | Langfuse 界面和接收日志的 API |
| `langfuse-worker` | `langfuse/langfuse-worker:4.55.0` | 异步把日志写入 ClickHouse |
| `postgres` | `postgres:16-alpine` | 一个实例两个库：`langfuse` 和 `litellm` |
| `clickhouse` | `clickhouse/clickhouse-server:25.12` | 存日志正文 |
| `redis` | `redis:7.2-alpine` | Langfuse 的任务队列 |
| `minio` | `cgr.dev/chainguard/minio:latest` | S3 兼容存储，存 Langfuse 收到的原始事件 |

对宿主机只开放 3 个端口：网关 `4000`、Langfuse `3000`、MinIO `9090`。数据库、ClickHouse、Redis 只在容器网络内可见，不会和机器上已有的服务抢端口。

## 环境要求

- Docker 和 Docker Compose v2（`docker compose` 子命令）
- 分配给 Docker 的内存**不少于 6 GB**：整套空载时实测占用约 4.8 GB
- 磁盘：7 个镜像在本机共占用约 6.7 GB
- `bash` 和 `curl`（自检用）
- 端口 `3000`、`4000`、`9090` 空闲；被占用时可以换，见[配置项](#配置项)
- 能访问 Docker Hub、`docker.litellm.ai`、`cgr.dev` 拉取镜像；访问不了时见[排错](#排错)

## 快速开始

```bash
git clone https://github.com/LIUC2H5OH/litellm-langfuse.git
cd litellm-langfuse
./deploy.sh
```

仓库是私有的，克隆前这台机器需要有访问权限，比如先执行 `gh auth login`，或者使用有权限的 SSH key / 访问令牌。

脚本会依次：检查环境 → 生成随机密钥写入 `.env` → 检查端口 → 拉取镜像 → 启动并等待全部服务就绪 → 生成 `CREDENTIALS.md` → 经网关调用内置模拟模型，确认请求和响应已经写入 Langfuse。成功时最后输出：

```
[OK]   LiteLLM 网关存活  http://127.0.0.1:4000
[OK]   Langfuse 存活  http://127.0.0.1:3000
[OK]   Langfuse 项目 API Key 有效
[OK]   经网关调用 mock-model 成功
[OK]   Langfuse 中找到了这次调用
[OK]   请求和响应正文都已写入 Langfuse

部署完成。
  Langfuse 控制台:  http://localhost:3000
  网关 API:         http://localhost:4000/v1
  网关管理界面:     http://localhost:4000/ui
  账号密码:         /path/to/litellm-langfuse/CREDENTIALS.md
```

### 部署到服务器，让其他机器访问

默认只允许本机访问。部署到服务器时，用 `--host` 指定其他机器访问这台服务器用的 IP 或域名：

```bash
./deploy.sh --host 10.0.0.5
```

这会把 3 个端口改为对所有网卡开放，并把 Langfuse 的登录跳转地址、`CREDENTIALS.md` 里的地址都换成 `http://10.0.0.5:...`。已经部署过的也可以直接加 `--host` 重新执行，密码不会变。

`deploy.sh` 可以重复执行：已有的 `.env` 会被沿用，不会重新生成密码。

## 部署后得到什么

| 地址 | 用途 | 登录方式 |
|---|---|---|
| `http://<地址>:3000` | **Langfuse**：查看每次调用的请求和响应 | 邮箱 + 密码 |
| `http://<地址>:4000/v1` | **网关 API**（OpenAI 兼容） | `Authorization: Bearer <key>` |
| `http://<地址>:4000/ui` | 网关管理界面：添加模型、发放 key、看用量费用 | 用户名 `admin` + Master Key |

所有账号、密码、密钥都在部署目录下的 **`CREDENTIALS.md`** 里，包括内部组件（PostgreSQL、ClickHouse、Redis、MinIO）的密码和进入方式。这个文件和 `.env` 权限都是 600，并且已在 `.gitignore` 里忽略。

## 接入自己的模型

内置的 `mock-model` 不连接任何外部服务，固定返回一句话，只用来验证对接。接入真实模型有两种方式：

**方式一：管理界面（推荐，不用重启）**

打开 `http://<地址>:4000/ui`，用 `admin` 和 Master Key 登录，在 **Models + Endpoints** 页面添加模型：选择服务商、填模型名和 API Key。模型配置存进数据库，API Key 用 `LITELLM_SALT_KEY` 加密保存。

**方式二：配置文件**

在 [litellm/config.yaml](litellm/config.yaml) 的 `model_list` 里加一段，然后执行 `docker compose restart litellm`。以 DeepSeek 为例：

```yaml
model_list:
  - model_name: deepseek-flash          # 客户端请求时用的名字
    litellm_params:
      model: deepseek/deepseek-flash    # 服务商/模型 ID
      api_key: os.environ/DEEPSEEK_API_KEY
```

用这种写法时，还要在 `.env` 里加上 `DEEPSEEK_API_KEY=...`，并在 `docker-compose.yml` 中 `litellm` 服务的 `environment` 下加一行 `DEEPSEEK_API_KEY: ${DEEPSEEK_API_KEY}`。各服务商的写法见 [LiteLLM 文档](https://docs.litellm.ai/docs/providers)。

**加好之后验证一下**（会产生一次真实调用）：

```bash
scripts/verify.sh deepseek-flash
```

确认对接无误后，可以把 `config.yaml` 里的 `mock-model` 删掉。

## 调用网关

先把 `.env` 读进当前 shell，避免把密钥贴进命令里：

```bash
set -a; source .env; set +a
```

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "mock-model", "messages": [{"role": "user", "content": "hello"}]}'
```

Python（OpenAI SDK）：

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:4000/v1", api_key="<网关 key>")
resp = client.chat.completions.create(
    model="mock-model",
    messages=[{"role": "user", "content": "hello"}],
)
print(resp.choices[0].message.content)
```

任何支持“自定义 OpenAI Base URL”的工具都能这样接入。给应用和其他人用时，不要把 Master Key 给出去，在管理界面的 **Virtual Keys** 里另发 key，可以限定能用的模型和预算。

### 给日志带上用户、会话、标签

请求里加上这几个字段，Langfuse 里就能按用户、会话、标签筛选和统计：

```json
{
  "model": "mock-model",
  "messages": [{"role": "user", "content": "hello"}],
  "user": "alice",
  "metadata": {"session_id": "chat-001", "tags": ["客服"]}
}
```

用 OpenAI SDK 时，`metadata` 放进 `extra_body={"metadata": {...}}`。

## 在 Langfuse 里看日志

登录 Langfuse，左侧菜单 **Observability → Tracing**，点任意一行进入详情。日志是异步写入的，调用结束后一般几秒内出现。

每次调用会产生两条记录：

| 记录名 | 类型 | 内容 |
|---|---|---|
| `litellm_request` | GENERATION | Input 是请求的 messages 全文，Output 是模型的回答；还有模型名、参数、token 用量、费用、耗时、用户、会话、标签 |
| `raw_gen_ai_request` | SPAN（上一条的子节点） | 网关与上游模型服务之间的原始报文，在 Attributes 页签的 Metadata 里 |

只想每次调用看一行：在左侧 Filters 的 Type 里只勾 `GENERATION`。只看失败的：搜索框输入 `level:ERROR`。

用 API 查日志（Langfuse v4 起旧的 `/api/public/traces` 已下线，要用 v2）：

```bash
curl -u "$LANGFUSE_INIT_PROJECT_PUBLIC_KEY:$LANGFUSE_INIT_PROJECT_SECRET_KEY" \
  "http://localhost:3000/api/public/v2/observations?type=GENERATION&limit=20&fields=core,basic,io,usage"
```

## 对接是怎么实现的

关键就两处：

1. [litellm/config.yaml](litellm/config.yaml) 里开启回调 `callbacks: ["langfuse_otel"]`，网关每次调用结束后把请求和响应通过 OpenTelemetry 发给 Langfuse。
2. [docker-compose.yml](docker-compose.yml) 里给 `litellm` 服务配好 `LANGFUSE_PUBLIC_KEY`、`LANGFUSE_SECRET_KEY`、`LANGFUSE_OTEL_HOST`。

这对 Langfuse API Key 不用手动去界面创建：Langfuse 首次启动时按 `.env` 里的 `LANGFUSE_INIT_*` 自动创建组织、项目、管理员和这对 key，网关直接用同一对。

**把应用自己的链路也串进来（可选）**：调用网关时带上 W3C 标准的 `traceparent` 请求头，网关记录的这次模型调用就会挂到应用自己上报给 Langfuse 的那条链路下面，比如智能体的一次任务。`scripts/verify.sh` 就是用这个办法精确找到自己那条记录的。

## 配置项

都在 `.env` 里，改完重新执行 `./deploy.sh`（或 `docker compose up -d`）生效。完整说明见 [.env.example](.env.example)。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PUBLIC_HOST` | `localhost` | 访问者打开页面用的地址，`--host` 会改它 |
| `BIND_ADDRESS` | `127.0.0.1` | `127.0.0.1` 只允许本机访问，`0.0.0.0` 允许其他机器访问 |
| `LITELLM_PORT` | `4000` | 网关端口 |
| `LANGFUSE_PORT` | `3000` | Langfuse 端口 |
| `MINIO_PORT` | `9090` | MinIO 端口（浏览器加载 Langfuse 里的媒体文件用） |
| `COMPOSE_PROJECT_NAME` | `llm-gateway` | 容器和数据卷的名字前缀；同一台机器部署多套时，每套用不同的值和端口 |
| `*_IMAGE` | 见 `.env.example` | 替换镜像地址，用于镜像加速或内网仓库 |

**第一次部署前**就要改端口或项目名的话：先执行一次 `./deploy.sh`，它生成 `.env` 后如果端口冲突会停下并提示；改好 `.env` 再执行一次即可。

## 运维

| 操作 | 命令 |
|---|---|
| 看状态 | `docker compose ps` |
| 看网关日志 | `docker compose logs -f litellm` |
| 看 Langfuse 日志 | `docker compose logs -f langfuse-web langfuse-worker` |
| 停止（保留数据） | `docker compose down` |
| 启动 | `./deploy.sh` 或 `docker compose up -d --wait` |
| 改了 `config.yaml` 后生效 | `docker compose restart litellm` |
| 自检 | `scripts/verify.sh` |
| 升级 | 改 `docker-compose.yml` 或 `.env` 里的镜像版本，然后 `docker compose pull && docker compose up -d --wait` |

数据都在 Docker 命名卷里（`<项目名>_postgres_data`、`_clickhouse_data`、`_minio_data` 等），`docker compose down` 不会删除。

**彻底重置**（删除全部日志、账号、模型配置）：

```bash
docker compose down -v
rm .env CREDENTIALS.md
./deploy.sh
```

## 排错

| 现象 | 处理 |
|---|---|
| `端口 xxxx 已被占用` | 在 `.env` 里把对应的 `*_PORT` 改成空闲端口，再执行 `./deploy.sh` |
| 镜像拉取失败 | 在 `.env` 里用 `*_IMAGE` 变量换成可访问的地址（镜像加速或内网仓库），再执行 `./deploy.sh` |
| `Docker 没有运行，或当前用户没有权限` | 启动 Docker；Linux 上把当前用户加入 `docker` 组，或用 `sudo ./deploy.sh` |
| 有服务没能正常启动 | `docker compose logs <服务名>` 看原因；最常见的是内存不足，确认 Docker 可用内存不少于 6 GB |
| 调用真实模型返回 500，提示连不上服务商 | 先在宿主机上确认能访问该服务商的地址；机器走代理时，容器也需要能出网 |
| 返回 200 但回答是空的 | 思考型模型的思考过程也计入 `max_tokens`，给太小会被用光。调大或不传 |
| Langfuse 里看不到刚才的调用 | 等几秒再刷新，并检查右上角时间范围；仍没有就执行 `scripts/verify.sh` 看卡在哪一步 |
| 调 `/api/public/traces` 返回 404 | Langfuse v4 已下线该接口，改用 `/api/public/v2/observations` |
| 想改 Langfuse 登录密码 | 界面里改密码需要邮件验证码，本部署没有配置邮件服务。测试环境可按上面的方法彻底重置 |
| 改了 `.env` 里的数据库密码后连不上 | 这些密码只在数据第一次初始化时写入，改密码需要重置，见 `CREDENTIALS.md` 的“改密码须知” |

## 安全说明

- `.env` 和 `CREDENTIALS.md` 含明文密钥，已在 `.gitignore` 里忽略，不要提交、不要外发。
- 默认只监听 `127.0.0.1`。用 `--host` 对外开放后，3 个端口对所有网卡开放，请配合防火墙只放行需要访问的机器；正式环境建议在前面加 HTTPS 反向代理。
- **Langfuse 里存的是请求和响应全文**，能登录 Langfuse 的人都能看到业务数据。
- Master Key 权限最大，只留给管理员。
- 已关闭 Langfuse 向官方上报匿名使用统计（`TELEMETRY_ENABLED=false`）。

### 已知限制

- 流式请求的模型思考过程（`reasoning_content`）不会被记录进 Langfuse，只记录最终回答；这是 LiteLLM 上报代码的限制。
- Langfuse 里显示的费用是 LiteLLM 按内置价格表估算的美元金额，对账请以服务商账单为准。

## 测试情况

在 macOS（Apple Silicon）、Docker 29.5.2、Docker Compose v5.1.3 上，从 `git clone` 出的全新副本实际验证过：

- 全新部署：镜像已在本地时约 1 分钟完成，自检全部通过
- 端口被占用时给出明确提示并停止
- 内置模拟模型、经管理接口添加的真实模型（DeepSeek），请求和响应都正确写入 Langfuse
- `CREDENTIALS.md` 中每一组账号密码都能登录，错误密码被拒
- 内部组件端口确实没有对宿主机开放
- `--host` 部署：端口改为对外开放，经局域网 IP 能访问和登录
- 重复执行 `deploy.sh` 不会改动已有的 `.env`

**Linux 服务器上尚未实测。**脚本只用了 bash、curl、awk、openssl（没有时退回 `/dev/urandom`）这些常见工具，按理可以直接运行；第一次在 Linux 上部署时请留意输出。
