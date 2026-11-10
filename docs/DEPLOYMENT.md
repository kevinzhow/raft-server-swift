# Linux Docker 部署与验收

目标是 Linux amd64 上的 PostgreSQL + Redis 部署。**当前仍有生产阻断项：应用业务持久化、Redis 业务接入、迁移 Main 接线及重启恢复尚待完成并实际验收。** 旧版代码的领域数据在内存中，旧版 `DATABASE_URL` 只执行 PostgreSQL `SELECT 1`；不能因增加两个容器就宣称账号、会话、频道、消息、任务等已经持久化。

当前迁移入口刻意拒绝执行，App 等待迁移成功后才启动。不要绕过这个检查，或把数据库健康、HTTP 200 当成生产就绪。待真实接口和验收完成后，交付方才能移除本阻断说明。

本次选择接入**现有 Raft daemon**，通过域名的 `/daemon/connect` 转发到服务端 8081；需使用实际客户端验收认证、重连及任务往返，不能只凭 TLS 或握手成功承诺执行能力。本交付不要求仓库中的 Swift `RaftDaemon` CLI 承担 provider CLI 执行，也不包含该 CLI。

公开后端地址为 **`https://raft.example.com`**。镜像没有 Web SPA；`APP_URL` 暂设同域只是链接配置占位，仍须部署真实 Web 前端处理 `?verify`、`?reset` 等页面。只启动后端或本文件的 TLS 反代不会出现完整 UI。真实邮件 provider（Resend 或 Cloudflare Email Sending）、生产密钥配置及邮件往返需单独验收。当前没有验证 arm64。

## 1. 初始化配置

主机需要 Docker Engine、Docker Compose v2、Bash，以及 `git`、`date`、`od`、`head`、`base64`、`tr`。构建需要下载公开的 Swift 包和 Ubuntu 软件包，不需要把 Git 凭据传入镜像。

在源码根目录运行：

```bash
./scripts/init-deployment.sh
```

[初始化脚本](../scripts/init-deployment.sh)生成权限 `600` 的 `.env`：JWT、PostgreSQL 密码、Redis 密码分别使用独立的 32 字节随机数，编码成 64 位十六进制；另用独立的 32 字节随机数生成 canonical base64 的 `CREDENTIAL_ENCRYPTION_KEY`，供 provider AES-GCM 加密使用。脚本同时记录当前 Git 的完整 SHA、分支和 UTC 构建准备时间。**已有 `.env` 时拒绝覆盖，不轮换、不打印密钥。** 请保留这份配置，不要提交、分发或贴进工单。[Docker 上下文排除规则](../.dockerignore)会排除 `.env`、备份和 Caddy 证书目录，但不会替你阻止 Git 提交它们。

**凭据主密钥必须保存在 PostgreSQL/Redis snapshot 之外的受控密钥库，不能复用或派生自 JWT，也不能写入业务快照。** 单独保管其加密备份；恢复 provider 密文时需要原主密钥，重新生成无法解密原记录。

### 已有三密钥配置的增量升级

不要重跑初始化来覆盖旧 `.env`，也不要改动现有 PostgreSQL/Redis 密码。在源码根目录用 Bash 执行下列块，只在完全缺失该配置项时追加主密钥，不打印密钥：

```bash
(
  set -euo pipefail
  umask 077
  [[ -f .env && ! -L .env ]] || { printf '%s\n' '需要本机常规 .env 文件。' >&2; exit 1; }
  if grep -Eq '^[[:space:]]*(export[[:space:]]+)?CREDENTIAL_ENCRYPTION_KEY[[:space:]]*=' .env; then
    printf '%s\n' '主密钥配置项已存在，拒绝新增或覆盖。' >&2
    exit 1
  fi
  chmod 600 .env
  encryption_key="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
  printf '\nCREDENTIAL_ENCRYPTION_KEY=%s\n' "$encryption_key" >> .env
  unset encryption_key
)
```

已有该项但为空时，通过受控编辑把独立生成的主密钥填入原项，不新增重复键。邮件使用 `RAFT_EMAIL_PROVIDER` 选择：Resend 需要 `RESEND_API_KEY`，Cloudflare 需要 `CLOUDFLARE_ACCOUNT_ID` 和 `CLOUDFLARE_EMAIL_API_TOKEN`；两者都需要已验证的 `FROM_EMAIL` 与实际 Web `APP_URL`。模板不会生成假服务凭据。

源码归档不带 `.git` 时，必须使用交付方提供的真实身份：

```bash
RAFT_RELEASE_SHA='<交付版本的完整40位Git SHA>' \
RAFT_RELEASE_BRANCH='<交付版本实际分支，或detached>' \
./scripts/init-deployment.sh
```

也可参考[环境模板](../.env.example)手动创建 `.env` 并执行 `chmod 600 .env`。JWT 至少 32 字符；数据库密码至少 32 个 URL 安全字符（字母、数字、下划线、连字符）。不要用占位 SHA 或示例密码。构建应基于交付的干净、已提交源码。

| 配置 | 默认值或要求 | 用途 |
| --- | --- | --- |
| `JWT_SECRET` | 必填，初始化时随机生成 | 会话与签名密钥 |
| `POSTGRES_PASSWORD` | 必填，初始化时随机生成 | 内部 PostgreSQL 用户 `raft` / 数据库 `raft` |
| `REDIS_PASSWORD` | 必填，初始化时随机生成 | 内部 Redis 认证 |
| `CREDENTIAL_ENCRYPTION_KEY` | 独立随机 32 字节的 canonical base64 | provider AES-GCM 外部主密钥；不入业务 snapshot、不复用 JWT |
| `RAFT_EMAIL_PROVIDER` | `resend`（兼容默认）或 `cloudflare` | 选择实际邮件发送器；不影响 outbox payload codec |
| `RESEND_API_KEY` | Resend 模式必填，模板为空 | Resend 发送凭据 |
| `CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_EMAIL_API_TOKEN` | Cloudflare 模式必填：32位十六进制账户ID / 有发送权限的token | Cloudflare Email Sending REST；不是Email Routing或R2凭据 |
| `FROM_EMAIL` | 已验证发件地址，可含显示名，模板为空 | 两种provider均必填；缺失时App不就绪 |
| `RAFT_RELEASE_SHA` / `RAFT_RELEASE_BRANCH` | 真实提交 SHA / 分支 | 镜像构建身份 |
| `RAFT_BUILD_AT` | UTC，如 `2026-11-08T01:23:45Z` | 本次构建前的真实时间 |
| `SERVER_URL` | `https://raft.example.com` | 浏览器、客户端可访问的公开后端地址 |
| `APP_URL` | 暂为 `https://raft.example.com` | 真实 Web 前端的 origin；当前镜像不提供 SPA，须另行部署验证/重置页面 |
| `RAFT_BIND_ADDRESS` | `127.0.0.1` | 宿主机发布地址；显式设 `0.0.0.0` 才向所有 IPv4 网卡开放 |
| `RAFT_HTTP_PORT` | `8080` | HTTP → 容器 8080 |
| `RAFT_DAEMON_PORT` | `8081` | `/daemon/connect` 握手 → 容器 8081 |
| `RAFT_SOCKET_PORT` | `8082` | Socket.IO → 容器 8082 |
| `E2E_AUTO_VERIFY_EMAIL` | `0` | 仅受控测试使用的邮箱验证绕过；生产保持关闭 |

### Cloudflare Email Sending

已实现直接从服务端调用 [Cloudflare REST API](https://developers.cloudflare.com/email-service/api/send-emails/rest-api/)，无需邮件中转 Worker。私密环境配置选择 `RAFT_EMAIL_PROVIDER=cloudflare`，填写 `CLOUDFLARE_ACCOUNT_ID`、`CLOUDFLARE_EMAIL_API_TOKEN`、`FROM_EMAIL`、`APP_URL`。生产endpoint固定为Cloudflare官方HTTPS地址；环境变量不能指定任意发送目标。

向任意注册用户发送事务邮件需要Workers Paid及Email Sending启用。Email Routing不替代发送能力。发送子域需按[官方子域配置](https://developers.cloudflare.com/email-service/configuration/subdomains/)独立onboard并验证，不能假设父域已验证就能使用子域。

发送器要求HTTP成功、`success=true`且唯一目标收件人明确出现在delivered/queued数组；bounce/suppression、缺失收件人状态、非法响应都不会被当成接受成功。只有provider message ID允许缺失，且不会伪造ID。queued不等于已投递到收件箱。重定向被拒绝，provider原响应及凭据不进入诊断。

沿用持久化outbox的有界重试。Cloudflare未文档承诺该接口的Idempotency-Key或去重窗口，因此发送后超时或丢失数据库确认可能重复邮件，不能声称exactly-once；Resend仍使用原有稳定幂等键。本地验收使用真实loopback HTTP服务，覆盖请求和回执契约；它不代替真实账号、域名、邮件投递与token消费验收，也不解除生产Agent启动阻断。

[Compose](../compose.yaml)通过内部服务名构造 `DATABASE_URL` 和 `REDIS_URL` 并传给 App。数据库和 Redis **不发布宿主机端口**。PostgreSQL 内部 URL 明确采用当前驱动支持的 `sslmode=disable`，不要把它复制为对公网数据库的连接方案。

正式部署使用 `SERVER_URL=https://raft.example.com`；`APP_URL` 必须最终指向真实前端 origin。同域部署前端时也需要配置到 Web SPA 的实际路由，不能把后端根路径当成前端。前置代理需分别处理 HTTP、Daemon 握手和 Socket.IO，并验收 TLS、DNS 和 WebSocket 转发。

### 可选 TLS 反代模板

[反代模板](../deploy/Caddyfile)将 `/daemon/connect` 原路径转发到 8081、`/socket.io` 原路径转发到 8082，其余请求转发到 8080；WebSocket 升级由反代处理。它目前不会提供 SPA。**DNS、证书签发和现有 daemon 兼容性尚未实测，`tls` profile 默认关闭；不要在已有 80/443 服务的主机上直接启用。** Caddy tag 也需在正式启用前核验并固定 digest。

首次使用新的证书目录时，明确准备持久目录并授予容器非 root 用户访问权；已有目录应先确认用途，不覆盖现有证书：

```bash
mkdir -p deploy/caddy-data deploy/caddy-config
sudo chown 10001:10001 deploy/caddy-data deploy/caddy-config
sudo chmod 700 deploy/caddy-data deploy/caddy-config
```

Caddy 在容器内以非 root 监听 8080/8443。待 DNS 指向部署主机、确认没有端口冲突、HTTP/HTTPS challenge 可达且 App 已验收后，才考虑显式公开 80/443：

```bash
CADDY_BIND_ADDRESS=0.0.0.0 docker compose --profile tls up -d caddy
```

仅写入模板不会启动该服务，也不会占用主机端口。若使用现有主机代理，可完全不启用这个 profile，保持 App 三端口回环发布并自行接入。证书目录含私钥，需要单独保管，不进入 Docker 构建上下文。

## 2. 构建、迁移与启动顺序

```bash
# 只检查配置，不把展开后的密码输出到终端。
docker compose config --quiet
docker compose build
# 可先独立验收基础设施；这不表示 App 已可生产使用。
docker compose up -d postgres redis
docker compose ps
```

[Dockerfile](../Dockerfile)固定 Swift 6.4.1 官方镜像 digest，保留 `Package.resolved` 和 Vapor revision，以 release 模式、4 个并行任务编译 `RaftServer`。运行层为 Ubuntu 26.04 和匹配的 Swift 共享库。服务以非 root、只读根文件系统运行，仅显式数据卷及 tmpfs 可写，并移除 capabilities、开启 `no-new-privileges`。

完整启动顺序为：

1. PostgreSQL 和 Redis 启动，并通过各自健康检查。
2. 一次性 `migrate` 服务执行 `RaftServer --migrate-only` 真实数据库迁移，成功退出。
3. App 在迁移成功后启动，使用同一组数据库与 Redis 配置。

**`--migrate-only` 的 Main 接线尚待完成，入口脚本仍明确拒绝执行该模式，App 因依赖条件而不会启动。** 完成真实接口和迁移验证后再使用完整命令：

```bash
docker compose up -d
docker compose logs --tail=100 migrate server
docker compose ps
```

PostgreSQL 使用 `postgres-data` 命名卷；Redis 使用 `redis-data` 命名卷、AOF 和 `appendfsync everysec`。Redis 主机突然断电仍可能丢失约一秒内的写入，卷也不能替代备份。默认项目名是 `raft`；使用 `-p` 会改变卷所属项目，部署时必须保持项目名一致。

## 3. 验收

必须同时确认迁移退出码、实际业务读写和重启恢复；不能只看以下基础探针：

```bash
docker compose exec -T postgres pg_isready -U raft -d raft
docker compose exec -T redis sh -ec 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --no-auth-warning ping'
curl --fail --silent --show-error http://127.0.0.1:8080/api/version
curl --include http://127.0.0.1:8080/health
docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q server)"
```

镜像健康检查使用 `/api/version`；正常响应应为 HTTP 200，带镜像构建时的 `sha`、`builtAt`、`branch`。这个检查不代表数据库 schema、Redis 用法、三个协议端口或业务持久化均已通过。

原 `/health` 仅执行 `SELECT 1`：没有数据库时 503、有数据库时成功，都不足以说明领域数据存储正确。生产交付验收还必须在真实 HTTP 创建账号、服务器、频道、消息等业务记录后，重启 App、重新登录并读回同一记录；重启 PostgreSQL 和 Redis 后再验证数据及所承诺的会话/队列行为。本文件不宣称这些未完成的验收已经通过。

生产保持 `E2E_AUTO_VERIFY_EMAIL=0`。它映射到实际环境变量 `SLOCK_E2E_AUTO_VERIFY_EMAIL`；只有受控测试主动设 `1` 且注册请求带 `"__e2eAutoVerify": true` 才绕过邮箱验证，不能替代真实邮件。生产需要真实 `RESEND_API_KEY` 和 Resend 已验证的 `FROM_EMAIL`；任一缺失时入口明确判定邮件不就绪并拒绝启动 App。adapter 接线、投递和链接往返尚待实际验证，配置了两个非空字符串也不等于邮件验收成功。

验证和重置链接使用 `APP_URL` 的 `?verify`、`?reset` Web 入口。必须有真实前端接收这些链接并完成对应 API 调用；当前同域 Caddy 模板只反代后端，不会自动实现这些页面。验收需包括实际收件、链接有效性、过期/重复使用行为，不要通过开启自动验证把未完成的邮件链路隐藏掉。

## 4. 停止与升级

```bash
# 正常停止，不删除命名卷。
docker compose stop
# 再次启动，卷保持原样；业务恢复能力仍须上述真实验收。
docker compose up -d
# 删除容器与项目网络，保留命名卷和本机 .env。
docker compose down
```

**不要运行 `docker compose down -v`、`docker volume prune` 或删除数据卷来处理启动失败。** 当前应用内存中的未持久化业务数据仍会在进程重启后丢失。

升级前完成并校验备份、确认迁移兼容性与回滚方案。保留 `.env` 的四个独立密钥，尤其不要轮换丢失 provider 原主密钥；修改 `POSTGRES_PASSWORD` 环境变量不会自动修改已有数据库用户密码。换到交付的新源码后，更新 `.env` 中真实 `RAFT_RELEASE_SHA`、`RAFT_RELEASE_BRANCH`、`RAFT_BUILD_AT`（时间可用 `date -u +%Y-%m-%dT%H:%M:%SZ` 获取），然后：

```bash
docker compose config --quiet
docker compose build
docker compose stop server
docker compose up -d --force-recreate migrate
docker compose up -d server
```

迁移失败就停下排查，不启动 App、不自动重置数据库。回滚镜像不等于回滚 schema 或数据；不能未经兼容性评估直接换回旧程序。

## 5. 备份与隔离恢复演练

下述命令针对**真实 PostgreSQL/Redis 卷**，不能备份仍留在 App 内存的业务数据。备份含业务信息和凭据密文，应存入受控、加密的异机存储；`CREDENTIAL_ENCRYPTION_KEY` 必须独立保存于受控密钥库，不进入这些 snapshot/归档。恢复时需通过外部配置提供原主密钥，否则 provider 密文无法解密。先在测试部署完成恢复演练，再依赖这些备份。

维护窗口内暂停 App 写入，导出 PostgreSQL，并停住 Redis 后归档其整个数据目录，保留 Redis 7 多文件 AOF 的一致性：

```bash
umask 077
backup_dir="backups/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$backup_dir"
docker compose stop server
docker compose exec -T postgres pg_dump -U raft -d raft --format=custom > "$backup_dir/postgres.dump"
docker compose exec -T redis sh -ec 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --no-auth-warning SAVE' > /dev/null
docker compose stop redis
docker compose run --rm --no-deps -T --entrypoint sh redis -ec 'tar -C /data -cf - .' > "$backup_dir/redis.tar"
# 检查命令返回值及归档可读性；失败时不要把空文件视为有效备份。
docker compose exec -T postgres pg_restore --list < "$backup_dir/postgres.dump" > "$backup_dir/postgres.contents"
tar -tf "$backup_dir/redis.tar" > "$backup_dir/redis.contents"
(cd "$backup_dir" && sha256sum postgres.dump redis.tar > SHA256SUMS)
docker compose up -d redis server
```

如果某一步失败，停止操作并保留已有文件和数据卷；不要继续把该备份标成有效。

恢复演练使用**全新、从未使用过的项目名** `raft-restore-check`，不碰运行项目的卷。先将下面路径替换为备份目录，核验 checksum：

```bash
backup_dir='backups/<备份时间目录>'
(cd "$backup_dir" && sha256sum -c SHA256SUMS)
docker compose -p raft-restore-check up -d --wait postgres
docker compose -p raft-restore-check exec -T postgres \
  pg_restore --exit-on-error --no-owner --no-privileges -U raft -d raft < "$backup_dir/postgres.dump"
# 目标 Redis 卷必须为空；已有内容时拒绝解包。
docker compose -p raft-restore-check run --rm --no-deps -T --entrypoint sh redis \
  -ec 'test -z "$(ls -A /data)"; tar -C /data -xf -' < "$backup_dir/redis.tar"
docker compose -p raft-restore-check up -d --wait redis
docker compose -p raft-restore-check exec -T redis \
  sh -ec 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --no-auth-warning ping'
```

再检查恢复的 schema、记录数量及真实业务读回。若要启动隔离 App，需给该项目另配不冲突的三个宿主机端口、匹配 URL，并使用与备份 schema 兼容的镜像/迁移。不要将本演练直接套到已有目标库，不要加入 `--clean` 或删除卷来“修复”恢复冲突；清理演练卷应由操作者另行明确决定。
