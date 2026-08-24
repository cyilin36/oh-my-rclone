# oh-my-rclone

基于 **rclone** 的单向同步备份 Docker 工具。传输使用 **sftp**（SSH 密码为主，可选密钥），基于 **cron** 定时执行，可配置**多条同步备份**。

> ⚠️ **首次接入请先 dry-run**：`FORCE_DRY_RUN=1` 跑一次 `run-backup.sh`，确认日志/远端行为符合预期后再正式启用 cron。
> 本项目设计与自测时**不会** touch 你在宿主机运行的任何生产容器；docker 适配永远排除工具自身容器，且在您的真实环境部署时请先在隔离数据上验证。

---

## 目录结构

```
oh-my-rclone/
├── Dockerfile
├── docker-compose.yml.example   # 编排示例（复制为 docker-compose.yml）
├── .env.example                 # 环境变量示例（复制为 .env）
├── README.md
├── scripts/
│   ├── entrypoint.sh            # 容器入口：生成 rclone.conf、注册 cron、常驻
│   ├── run-backup.sh            # 遍历 jobs.conf 串行执行所有备份、汇总、webhook
│   ├── job.sh                   # 单条任务流程（reflink/docker/排除/统计）
│   ├── lib.sh                   # 公共库（解析、日志、docker pause、reflink、排除）
│   └── notify.sh                # webhook 发送
└── conf/
    ├── jobs.conf.example        # 多任务定义
    ├── rclone.conf.example      # sftp 远程定义
    └── excludes.conf.example    # 同步排除项
```

---

## 快速开始

```bash
# 1) 准备配置
cp .env.example .env
cp conf/jobs.conf.example   conf/jobs.conf
cp conf/rclone.conf.example conf/rclone.conf
cp conf/excludes.conf.example conf/excludes.conf
#   → 编辑 .env / conf/jobs.conf / conf/rclone.conf（填绝对路径、sftp 凭据、任务）

# 2) 启动
docker compose up -d --build

# 3) 立即触发一次备份（建议先用 dry-run 预检）
docker compose exec oh-my-rclone /scripts/run-backup.sh FORCE_DRY_RUN=1
docker compose exec oh-my-rclone /scripts/run-backup.sh

# 4) 查看日志
docker compose logs -f oh-my-rclone
```

---

## 多任务配置：`conf/jobs.conf`

每行一条任务，字段以 `|` 分隔：

```
name|src|dest|extra_exclude
```

字段|说明
---|---
`name`|任务名（唯一）
`src`|源目录（容器内路径，对应 `docker-compose` 挂载的 `/data` 下子目录）
`dest`|rclone 远程:路径（对应 `rclone.conf` 的 sftp 远程）
`extra_exclude`|任务级额外排除（可选，`;` 分隔，与 `excludes.conf` 同语法）

> ⚠️ **sftp 连接凭据（host/user/pass/密钥）只需在 `conf/rclone.conf` 配置一次**，
> 多个任务通过 `dest` 里的远程名（如 `backup-sftp:...`）共用，**不需要在每行重复**。

示例：
```
postgres|/data/postgres|backup-sftp:backup/postgres|
docs|/data/docs|backup-sftp:backup/docs|ext=.tmp;dir=logs/
```

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
  > **强烈建议优先使用 `whitelist`**，把需要暂停的容器明确列出；只有在明确理解语义时才用 blacklist。
- **必定排除本容器**（`oh-my-rclone` / 运行时容器名），**绝不 pause 自身** → 杜绝冻结自身导致死循环。
- 与 reflink 联动：
  - reflink **关**：pause(命中容器) → **全程** rclone 上传 → unpause。
  - reflink **开**：pause(命中容器) → 完成快照（瞬时）→ **立即 unpause** 恢复业务容器 → rclone 后台上传快照。避免长时间上传让业务容器停摆。
- `trap` 保障 pause 后必有 unpause（含重试 & 超时），即使任务中断也不会残留冻结容器。

### 3. 同步目录排除项（`EXCLUDE_CONF`）

见 `conf/excludes.conf.example`，支持：

- 文件：`file=relative/path/foo.bin`
- 文件夹：`dir=logs/`
- 类型：`ext=.log` / `ext=*.part`（任意层级）
- 通配（实现“某目录下某类型全排除”）：`glob=cache/**/*.log`
- 路径段：`path=node_modules`

被排除文件会被**彻底无视**：不上传、不计入失败清单、不触发任何动作。

### 4. Webhook 通知（`WEBHOOK_ENABLE=false`，默认关闭）

兼容 [`astrbot_plugin_push_lite`](https://github.com/Raven95676/astrbot_plugin_push_lite)。统一在整批备份结束（回到静默态）后上报一条报告，内容含：

- 本次同步成功/失败（整体）
- 本次同步上传数据大小
- 本次哪些文件同步失败（≤ `FAIL_LIST_MAX` 条）
- 本次同步失败文件大小（合计字节）
- 本次同步开始时间、结束时间、总耗时

发送方式（`scripts/notify.sh`）：

```bash
curl -X POST "${ASTROBOT_PUSH_URL}" \
     --data-urlencode "token=${ASTROBOT_PUSH_TOKEN}" \
     --data-urlencode "message=<报告文本>"
```

`ASTROBOT_PUSH_URL` / `ASTROBOT_PUSH_TOKEN` 全可配；默认鉴权字段名 `token`（可经 `ASTROBOT_PUSH_KEY` 覆盖），以兼容该插件或其它兼容端点。`WEBHOOK_SUCCESS_ONLY` 可设为仅在成功时通知。

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

- **传输**：sftp，密码优先（`sshpass`），可选密钥（`--key_file`）。
- **调度**：容器内 `dcron`（零外部依赖）按 `CRON_SCHEDULE` 触发 `run-backup.sh`；`flock` 防止重入。
- **统计口径**：上传量为 rclone 报告字节；失败文件大小按本地对应源文件 `stat` 合计；rclone 输出解析失败时保留原始日志并标注。
- **目录建议绝对路径**：`.env` 中宿主机目录一律使用绝对路径，避免 relative 解析歧义。
- **多任务串行**：避免 tmp 冲突与重复 pause。
- 单向覆盖同步。如需版本历史可自行在任务中引入 rclone `--backup-dir`（脚本预留注释位）。

---

## 故障排查

| 现象 | 排查 |
|---|---|
| 容器启动报“未找到远程/未设置 SSH_HOST” | 在 `conf/rclone.conf` 定义 sftp 远程，或补齐 `.env` 的 `SSH_*` |
| docker 适配无效果 | 确认 `DOCKER_ADAPT_ENABLE=true` 且挂载了 `docker.sock`、容器名正确 |
| reflink 变成了普通复制 | 源与 `/tmp` 不在同一可 reflink 文件系统（btrfs/xfs）；这是预期降级 |
| 没有 webhook | 确认 `WEBHOOK_ENABLE=true`、`ASTROBOT_PUSH_URL` 可达、token 正确 |
| 想要测试失败分支 | 用不存在/无权限的 `dest`；`FORCE_DRY_RUN=1` 不会真正上传 |

---

## 测试验证（隔离环境，未触碰生产）

以下功能已在**隔离的测试容器环境**中验证通过（用自带临时容器 + 本地目标，未对任何真实生产容器/远端执行过同步或 pause）：

| 功能 | 验证结果 |
|---|---|
| reflink 快照 + 排除 + 上传后清理 | ✅ 首传 3 文件，`.log` 正确排除，stage/job 目录完全清理 |
| 上传量统计 | ✅ 首传显示 `26 B`，与 rclone 统计行一致；增量无变化显示 `0 B` |
| 同步排除项（`ext=.log` / `dir=` / `path=` / `glob=`） | ✅ 单元 + 容器内均验证 |
| docker 适配（whitelist，真实 pause/unpause） | ✅ 只对测试容器 `omr-fake-app` 执行 pause→快照→unpause；工具自身从未被 pause |
| docker 适配 reflink 联动 | ✅ reflink 开：pause→快照→立即 unpause→上传；reflink 关：pause→全程上传→unpause |
| docker 目标选区（whitelist/blacklist/强黑名单自身） | ✅ mock API 验证：记录表过滤正确、自身始终被排除 |
| webhook 成功报告 | ✅ 含 状态/上传数据/失败文件/失败文件大小/起止时间/总耗时 |
| webhook 失败报告 | ✅ 失败任务正确上报 |
| cron 注册 + 容器常驻 | ✅ 容器内 crond 运行、crontab 正确 |
| docker compose 配置解析 | ✅ `docker compose config` 通过 |

> 说明：blacklist 模式仅通过 mock API 验证了**选区逻辑**，未在真实环境执行（因其会对记录表外所有运行容器操作，存在生产风险）。请优先使用 whitelist。