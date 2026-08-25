# oh-my-rclone

基于 **rclone** 的单向同步备份 Docker 工具。传输使用 **sftp**（SSH 密码为主，可选密钥），基于 **cron** 定时执行，可配置**多条同步备份**。

> ⚠️ **首次接入请先 dry-run**：`FORCE_DRY_RUN=1` 跑一次 `run-backup.sh`，确认日志/远端行为符合预期后再正式启用 cron。
> 本项目设计与自测时**不会** touch 你在宿主机运行的任何生产容器；docker 适配永远排除工具自身容器，且在您的真实环境部署时请先在隔离数据上验证。

---

## 配置架构（三份文件各司其职）

| 文件 | 职责 | 内容 |
|---|---|---|
| **`.env`** | **全局默认层** | 默认远端服务器、功能开关默认值、默认定时、webhook 全局默认 |
| **`conf/config.toml`** | **任务层 + 覆盖层**（frpc 风格） | 每个任务一个 `[[job]]` 块：src/dest/排除/webhook/远端覆盖/开关覆盖 |
| **`docker-compose.yml`** | 宿主机挂载 | 所有宿主机目录挂载（绝对路径）、env_file 引入 `.env` |

- **优先级**：任务块 > config.toml 顶部(可选) > `.env` 默认。任务没写的字段自动继承 `.env`。
- **挂载只写 compose**；**src/dest、排除、任务级 webhook 只写 config.toml**；`.env` 只做默认。

---

## 目录结构

```
oh-my-rclone/
├── Dockerfile
├── docker-compose.yml.example   # 编排示例（复制为 docker-compose.yml）
├── .env.example                 # 全局默认示例（复制为 .env）
├── README.md
├── scripts/
│   ├── entrypoint.sh            # 容器入口：生成 rclone.conf、注册 cron、常驻
│   ├── parse_config.py          # 解析 config.toml + .env 合并出全局/每任务配置
│   ├── run-backup.sh            # 遍历 config.toml 的任务串行执行、汇总、webhook
│   ├── job.sh                   # 单条任务流程（reflink/docker/排除/统计/单任务 webhook）
│   ├── lib.sh                   # 公共库（解析、日志、docker pause、reflink、排除）
│   └── notify.sh                # webhook 发送
└── conf/
    └── config.toml.example      # 任务配置示例（复制为 config.toml）
```

---

## 快速开始

```bash
# 1) 准备配置
cp .env.example .env
cp conf/config.toml.example conf/config.toml
#   → 编辑 .env（默认远端/开关/定时/webhook 默认）
#   → 编辑 conf/config.toml（每个任务一个块）
#   → 编辑 docker-compose.yml（宿主机源目录挂载，绝对路径）

# 2) 启动
docker compose up -d --build

# 3) 立即触发一次备份（建议先用 dry-run 预检）
docker compose exec oh-my-rclone /scripts/run-backup.sh FORCE_DRY_RUN=1
docker compose exec oh-my-rclone /scripts/run-backup.sh

# 4) 查看日志
docker compose logs -f oh-my-rclone
```

---

## 配置详解

### `.env`（全局默认）

```ini
# 默认远端服务器（任务没单独写就用它）
REMOTE_HOST=192.168.1.50
REMOTE_USER=backupuser
REMOTE_PASS=your_password      # 明文，启动时自动 rclone obscure 加密写入 rclone.conf
REMOTE_PORT=22
# REMOTE_KEY_FILE=/keys/id_ed25519

# 各项功能开关（默认值，任务可在 config.toml 覆盖）
REFLINK_ENABLE=true
DOCKER_ADAPT_ENABLE=false
DOCKER_MODE=whitelist
DOCKER_CONTAINERS=postgres,mysql
FAIL_LIST_MAX=50

# webhook 全局默认（任务可在 config.toml 覆盖）
WEBHOOK_ENABLE=false
WEBHOOK_SUCCESS_ONLY=false
ASTROBOT_PUSH_URL=https://your-astrbot.example.com/api/push
ASTROBOT_PUSH_TOKEN=your_token

# 默认定时
CRON_SCHEDULE="0 3 * * *"

# 全局排除（可选，所有任务生效，任务级 exclude 再叠加）
# EXCLUDE_GLOBAL="ext=.log; dir=node_modules/"
```

### `conf/config.toml`（任务层，一个任务一个块）

```toml
[[job]]
name = "postgres"               # 任务名（必填）
src = "/data/postgres"          # 同步哪个文件夹（容器内路径，必填）
dest = "backup/postgres"        # 远端哪个路径（必填，用 .env 默认远端）

[[job]]
name = "docs"
src = "/data/docs"
dest = "backup/docs"
exclude = ["ext=.tmp", "dir=node_modules/"]   # 决定哪些文件不同步
webhook = true                  # 该任务完成后单独发一份 webhook

[[job]]
name = "mysql-other"            # 单独指定远端（覆盖 .env 默认）
src = "/data/mysql"
dest = "backup/mysql"
remote_host = "192.168.1.60"
remote_user = "backup2"
remote_pass = "another_password"
webhook_success_only = false
# enabled = false               # 禁用该任务
# reflink = false               # 覆盖该任务开关
```

任务块可用键：

| 键 | 说明 | 缺省 |
|---|---|---|
| `name` / `src` / `dest` | 必填 | - |
| `remote_host/user/pass/port/key_file` | 单独指定远端（覆盖 .env 默认） | 继承 .env |
| `remote` | 指定 rclone.conf 中已有的手工远端名 | - |
| `exclude` | 任务级排除（数组/分号），叠加全局 | 继承全局 |
| `webhook` / `webhook_success_only` | 该任务 webhook 开关 | 继承 .env |
| `enabled` | 是否启用该任务 | `true` |
| `reflink` / `reflink_strict` | 覆盖该任务开关 | 继承 .env |

> ⚠️ **docker 适配是全局配置**，只在 `.env` 里设置（`DOCKER_ADAPT_ENABLE` / `DOCKER_MODE` / `DOCKER_CONTAINERS`），**不支持任务级覆盖**——因为它是针对整批容器的操作，任务级配置会导致冲突。任务块里写 docker_* 会被忽略。

### `docker-compose.yml`（挂载）

```yaml
services:
  oh-my-rclone:
    env_file: .env
    volumes:
      - /path/to/postgres_data:/data/postgres:ro    # 宿主机绝对路径 → /data/postgres
      - /path/to/docs:/data/docs:ro
      - /path/to/oh-my-rclone/tmp:/tmp               # reflink 暂存区（源内时需排除，见下）
      - /var/run/docker.sock:/var/run/docker.sock:ro # docker 适配
      - ./conf:/etc/oh-my-rclone/conf:ro
```

> 挂载只在这里配；config.toml 任务的 `src` 填对应的容器内路径（如 `/data/postgres`）。
>
> ⚠️ **reflink 暂存区**：若 `/tmp` 的宿主机路径位于源目录**内部**（如源挂载整个 `<源父目录>`、tmp 为 `<源父目录>/oh-my-rclone/tmp`），**必须**在对应任务加排除：
> ```toml
> [[job]]
> src = "/data/docker-backup"
> exclude = ["dir=oh-my-rclone/tmp/"]   # 排除 reflink 暂存区，避免复制递归
> ```

---

## 特别功能

### 1. Reflink 快照（`REFLINK_ENABLE=true`，默认开启）

- 上传前在容器 `/tmp` 以 **reflink** 方式复制一份源文件的“行为瞬间”副本；rclone 只上传该副本。
- 目的：源文件被持续/间歇写入时，快照是一份稳定副本，**避免边写边传导致反复上传**。
- 上传完成后删除副本，释放磁盘（`trap` 兜底清理）。
- 跨文件系统时 `--reflink=auto` 自动降级为普通复制；若需硬性要求，设 `REFLINK_STRICT=true`（不支持时任务报错）。
- **请把 `/tmp`（reflink 暂存区）列入同步排除项**，避免复制/上传递归。工具也会**自动**把该目录加入运行时排除，双保险。

### 2. Docker 适配（`DOCKER_ADAPT_ENABLE=false`，默认关闭）

针对宿主机上**正在运行、尤其在持续写库**的容器（如数据库）进行 pause/unpause 协同，保证快照一致性。需要挂载宿主机 `/var/run/docker.sock`。

- `DOCKER_MODE=whitelist`：只对 `DOCKER_CONTAINERS` 记录表内**正在运行**的容器 pause/unpause。
- `DOCKER_MODE=blacklist`：把 `DOCKER_CONTAINERS` 记录表内的容器排除，处理其余运行中容器。
  > ⚠️ **blacklist 有真实风险**：它会对**记录表之外所有运行中的容器**执行 pause/unpause。若你有很多业务容器且未全部列入记录表，它们都会被短暂冻结。
  > **强烈建议优先使用 `whitelist`**。
- **必定排除本容器**（`oh-my-rclone` / 运行时容器名），**绝不 pause 自身** → 杜绝冻结自身导致死循环。
- 与 reflink 联动：
  - reflink **关**：pause(命中容器) → **全程** rclone 上传 → unpause。
  - reflink **开**：pause(命中容器) → 完成快照（瞬时）→ **立即 unpause** 恢复业务容器 → rclone 后台上传快照。
- `trap` 保障 pause 后必有 unpause（含重试 & 超时）。

### 3. 同步目录排除项

排除规则（`EXCLUDE_GLOBAL` 或任务 `exclude`），支持：

- 文件：`file=relative/path/foo.bin`
- 文件夹：`dir=logs/`
- 类型：`ext=.log` / `ext=*.part`（任意层级）
- 通配（实现“某目录下某类型全排除”）：`glob=cache/**/*.log`
- 路径段：`path=node_modules`

被排除文件会被**彻底无视**：不上传、不计入失败清单、不触发任何动作。

### 4. Webhook 通知

兼容 [`astrbot_plugin_push_lite`](https://github.com/Raven95676/astrbot_plugin_push_lite)。支持**两层通知**：

- **单任务 webhook**：任务块 `webhook = true` → 该任务**完成后单独发一份报告**（任务名/成败/上传量/失败文件/失败文件大小/起止时间/耗时）。没写则继承 `.env` 的 `WEBHOOK_ENABLE` 默认。
- **批次汇总 webhook**：整批备份结束（回到静默态）发一份汇总，含批次起止时间与总耗时。

报告必含：同步成功/失败、上传数据量、失败文件清单（≤ `FAIL_LIST_MAX` 条）、失败文件大小、开始时间、结束时间、总耗时。

发送方式（`scripts/notify.sh`）：

```bash
curl -X POST "${ASTROBOT_PUSH_URL}" \
     --data-urlencode "token=${ASTROBOT_PUSH_TOKEN}" \
     --data-urlencode "message=<报告文本>"
```

默认鉴权字段名 `token`（可经 `ASTROBOT_PUSH_KEY` 覆盖）。`WEBHOOK_SUCCESS_ONLY` 可设为仅在成功时通知。

---

## 常用运维命令

```bash
docker compose up -d --build                                   # 构建启动
docker compose logs -f oh-my-rclone                            # 日志
docker compose exec oh-my-rclone /scripts/run-backup.sh        # 立即备份
docker compose exec oh-my-rclone /scripts/run-backup.sh FORCE_DRY_RUN=1  # dry-run 预检
docker compose restart oh-my-rclone                            # 重启
```

---

## 设计说明与边界

- **传输**：sftp，密码优先（`sshpass`），可选密钥。远端凭据由 `.env`/`config.toml` 自动生成 `rclone.conf`，启动时 `rclone obscure` 加密。
- **调度**：容器内 `dcron` 按全局 `CRON_SCHEDULE` 触发 `run-backup.sh`；`flock` 防止重入。
- **统计口径**：上传量为 rclone 报告字节；失败文件大小按本地对应源文件 `stat` 合计；rclone 输出解析失败时保留原始日志并标注。
- **挂载绝对路径**：宿主机目录一律在 `docker-compose.yml` 使用绝对路径。
- **多任务串行**：避免 tmp 冲突与重复 pause。
- 单向覆盖同步。如需版本历史可自行在任务中引入 rclone `--backup-dir`。
- 敏感项（密码/token）在 `.env` / `conf/config.toml`（已 `.gitignore`，不随仓库提交）。

---

## 故障排查

| 现象 | 排查 |
|---|---|
| 容器启动报"未生成任何 sftp 远端" | 在 `.env` 填 `REMOTE_HOST`（默认远端），或任务块填 `remote_host` |
| docker 适配无效果 | 确认 `DOCKER_ADAPT_ENABLE=true` 且挂载了 `docker.sock`、容器名正确 |
| reflink 变成了普通复制 | 源与 `/tmp` 不在同一可 reflink 文件系统（btrfs/xfs）；这是预期降级 |
| 没有 webhook | 确认 `WEBHOOK_ENABLE=true`（全局或任务级）、`ASTROBOT_PUSH_URL` 可达、token 正确 |
| 任务没执行 | 检查 `conf/config.toml` 语法、任务块是否 `enabled = false`、是否有 name/src/dest |
| 想要测试失败分支 | 用不存在/无权限的 `dest`；`FORCE_DRY_RUN=1` 不会真正上传 |

---

## 测试验证（隔离环境，未触碰生产）

以下功能已在**隔离的测试容器环境**中验证通过（用自带临时容器 + 本地目标，未对任何真实生产容器/远端执行过同步或 pause）：

| 功能 | 验证结果 |
|---|---|
| TOML 配置解析（继承/覆盖远端/exclude 叠加/enabled=false 跳过/任务级 webhook） | ✅ 单测通过 |
| reflink 快照 + 排除 + 上传后清理 | ✅ 首传文件正确，`.log` 排除，stage/job 目录完全清理 |
| 上传量统计 | ✅ 首传显示正确字节，增量无变化显示 `0 B` |
| 同步排除项（`ext=` / `dir=` / `path=` / `glob=`） | ✅ 单元 + 容器内均验证 |
| docker 适配（whitelist，真实 pause/unpause） | ✅ 只对测试容器执行 pause→快照→unpause；工具自身从未被 pause |
| 单任务 webhook + 批次汇总 webhook | ✅ 每任务各发一份 + 批次汇总一份，内容含成败/上传量/失败文件/大小/起止时间/耗时 |
| cron 注册 + 容器常驻 | ✅ 容器内 crond 运行、crontab 正确 |
| docker compose 配置解析 | ✅ `docker compose config` 通过 |

> 说明：blacklist 模式仅通过 mock API 验证了**选区逻辑**，未在真实环境执行（因其会对记录表外所有运行容器操作，存在生产风险）。请优先使用 whitelist。