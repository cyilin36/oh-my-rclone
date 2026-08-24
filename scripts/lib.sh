#!/usr/bin/env bash
# lib.sh - oh-my-rclone 公共函数库
# 被 entrypoint.sh / run-backup.sh / job.sh / notify.sh 引用。
# 仅定义函数与只读配置，不执行主流程。

set -o pipefail
shopt -s globstar nocasematch 2>/dev/null || true

# ----------------------------------------------------------- 基础环境
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${CONF_DIR:-/etc/oh-my-rclone/conf}"

# 默认配置（可被环境变量覆盖）
OMR_TMP_ROOT="${OMR_TMP_ROOT:-/tmp/oh-my-rclone}"      # reflink 快照根目录
: "${REFLINK_ENABLE:=true}"
: "${REFLINK_STRICT:=false}"
: "${DOCKER_ADAPT_ENABLE:=false}"
: "${DOCKER_MODE:=whitelist}"
: "${DOCKER_CONTAINERS:=}"
: "${WEBHOOK_ENABLE:=false}"
: "${WEBHOOK_SUCCESS_ONLY:=false}"
: "${ASTROBOT_PUSH_URL:=}"
: "${ASTROBOT_PUSH_TOKEN:=}"
: "${FAIL_LIST_MAX:=50}"
: "${SELF_CONTAINER:=oh-my-rclone}"
: "${DOCKER_API:=/var/run/docker.sock}"
: "${UNPAUSE_RETRY:=5}"
: "${UNPAUSE_WAIT:=2}"

# 本容器名：通过 /proc/self/cgroup 或 hostname 推断，用于“永远不自冻”强守卫。
CONTAINER_NAME="${CONTAINER_NAME:-$(hostname 2>/dev/null || echo unknown)}"
if [ -z "${CONTAINER_NAME}" ] || [ "${CONTAINER_NAME}" = "unknown" ]; then
    CONTAINER_NAME="${HOSTNAME}"
fi

# ----------------------------------------------------------- 输出与日志
# 所有 log_* 统一写向 stderr，让 stdout 保持干净，专供函数返回值使用。
_log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')][${level}] $*" >&2
}
log_info()  { _log "INFO " "$@"; }
log_warn()  { _log "WARN " "$@" >&2; }
log_error() { _log "ERROR" "$@" >&2; }

# 秒级耗时格式化：seconds -> "1h2m3s"
fmt_duration() {
    local s="$1" h m
    s="${s%.*}"
    h=$(( s / 3600 )); s=$(( s % 3600 ))
    m=$(( s / 60 ));   s=$(( s % 60 ))
    if [ "$h" -gt 0 ]; then echo "${h}h${m}m${s}s"
    elif [ "$m" -gt 0 ]; then echo "${m}m${s}s"
    else echo "${s}s"; fi
}

# ----------------------------------------------------------- 配置读取
# config.toml 由 parse_config.py 解析（合并 .env 环境变量默认 + 任务块覆盖）。
# 优先级：任务块 > config.toml 顶部(可选) > .env 默认。
PARSE_PY="${PARSE_PY:-${SCRIPT_DIR}/parse_config.py}"
CONFIG_TOML="${CONFIG_TOML:-${CONF_DIR}/config.toml}"

# 加载全局有效配置（key=value 行 -> 环境变量）。供 entrypoint 使用。
load_global_config() {
    python3 "$PARSE_PY" --global "$CONFIG_TOML" 2>/dev/null
}

# 输出每任务合并配置：空行分隔，键为 JOBNAME=... 等（单引号转义）。
# 调用方需按空行切块并 eval/解析。此处仅输出原始行。
parse_toml_jobs() {
    python3 "$PARSE_PY" --jobs "$CONFIG_TOML" 2>&1
}

# 由单个任务块文本（含引号转义）生成 shell 变量到当前环境。
# 输入形如：
#   JOBNAME='postgres'
#   SRC='/data/postgres'
#   ...
# 用 eval 安全执行（值已由 python 单引号转义）。
load_job_env() {
    local block="$1"
    eval "$(printf '%s\n' "$block" | sed -e "s/^\([A-Z_]*\)=/\1=/")"
}

# 解析 sftp 远程目标 —— remote:path 拆成 remote 名与路径
split_remote_path() {
    local rp="$1"
    case "$rp" in
        *:*) echo "${rp%%:*}" ; echo "${rp#*:}" ;;
        *)   echo "" ; echo "$rp" ;;
    esac
}

# ----------------------------------------------------------- 排除项加载与过滤
# excludes.conf 行格式（# 注释、空行跳过）：
#   file=relative/path/foo.bin       # 排除单个文件
#   dir=logs/                        # 排除整个文件夹
#   ext=.log                         # 排除所有 .log
#   glob=logs/**/*.log               # 通配（grep -E 风格取自 find 路径，见实现）
#   path=*/node_modules              # 任意层级匹配该段路径
# 每行为一条；行内可含多个以分号分隔（兼容分号分隔多规则）。
load_excludes() {
    local file="$1" r
    [ -r "$file" ] || return 0
    while IFS= read -r r; do
        [ -z "$r" ] && continue
        case "$r" in \#*) continue ;; esac
        # 去除首尾空白
        r="${r#"${r%%[![:space:]]*}"}"
        [ -z "$r" ] && continue
        echo "$r"
    done < "$file"
}

# 判断某相对路径是否命中排除规则。
# 参数：$1=相对路径（不带前导 /），$2=类型(file|dir)，$3 = 规则列表字符串
# 返回 0=应排除，1=不排除。
excluded_path() {
    local rel="$1" type="$2" rules="$3" base
    local r key val
    # 剥离末尾斜杠
    rel="${rel%/}"
    base="$(basename "$rel")"
    while IFS= read -r r; do
        [ -z "$r" ] && continue
        key="${r%%=*}"; val="${r#*=}"
        case "$key" in
            file)
                [ "${rel}" = "${val}" ] && return 0 ;;
            dir)
                # 目录前缀匹配：rel 位于 val 目录之下（含本身）
                case "/${rel}/" in "/${val%/}/"*) return 0 ;; esac
                ;;
            ext)
                # 匹配 basename 类型：.log 表示以 .log 结尾；*.part 表示通配后缀。
                case "$val" in
                    \**) [[ "$base" == $val ]] && return 0 ;;
                    *)   [[ "$base" == *$val ]] && return 0 ;;
                esac
                ;;
            glob)
                # globstar 启用：** 匹配零或多个目录。与 rclone --exclude ** 语义一致。
                [[ "$rel" == $val ]] && return 0
                ;;
            path)
                case "/${rel}" in *"/${val}"*) return 0 ;; esac
                ;;
        esac
    done <<< "$rules"
    return 1
}

# 生成 rclone 的 --exclude 参数数组。规则转成 rclone glob 语法。
# 参数：规则列表字符串。将文件/文件夹直接转 /path，ext/glob 原样，path 转 glob。
build_rclone_excludes() {
    local rules="$1" r key val
    while IFS= read -r r; do
        [ -z "$r" ] && continue
        key="${r%%=*}"; val="${r#*=}"
        case "$key" in
            file)  printf -- '%s\n' "/${val}" ;;
            dir)   printf -- '%s\n' "/${val%/}/**" "${val%/}/" ;;
            ext)   printf -- '%s\n' "**${val}" ;;
            glob)  printf -- '%s\n' "$val" ;;
            path)  printf -- '%s\n' "**/${val}/**" ;;
        esac
    done <<< "$rules"
}

# ----------------------------------------------------------- reflink 快照
# 将源目录按排除规则复制为“行为瞬间”副本到 $OMR_TMP_ROOT/<job>/stage/。
# reflink 用途：源文件持续写入时，仅复制一次块，上传期间源再写入不影响已快照数据，
#              避免“边写边传导致反复上传”。
# cp --reflink=auto：支持 reflink 的文件系统（btrfs/xfs）别名零拷贝，否则降级为普通复制。
make_reflink_stage() {
    local src="$1" job="$2" rules="$3"
    local stage="$OMR_TMP_ROOT/$job/stage"
    rm -rf "$stage"; mkdir -p "$stage"

    # 源可用性检查
    [ -e "$src" ] || { log_error "[$job] 源路径不存在: $src"; return 1; }

    # 若严格模式且当前 FS 不支持 reflink，报错（由调用方决定是否中止任务）。
    # 注意必须用 cp -a（保留属性 + 递归复制目录），否则目录复制会 "omitting directory" 退出非零，
    # 被误判为"不支持 reflink"。
    if [ "${REFLINK_STRICT}" = "true" ]; then
        if ! cp -a --reflink=always "$src"/. "$stage"/. </dev/null 2>&1; then
            log_error "[$job] REFLINK_STRICT 且当前文件系统不支持 reflink（源与暂存须同 FS）"; return 2
        fi
    else
        cp -a --reflink=auto "$src"/. "$stage"/. 2>/dev/null \
            || cp -a "$src"/. "$stage"/. \
            || { log_error "[$job] 复制到快照区失败"; return 1; }
    fi

    # 依据排除规则删除不需要上传的文件（stage 内相对路径 == 源相对路径）
    local rel delete_count=0
    while IFS= read -r -d '' f; do
        rel="${f#"$stage"/}"
        if excluded_path "$rel" file "$rules"; then
            rm -f -- "$f"; delete_count=$((delete_count+1))
        fi
    done < <(find "$stage" -type f -print0)
    # 删除空目录（排除 dir 或删除文件后）
    while IFS= read -r -d '' d; do
        rel="${d#"$stage"/}"
        if excluded_path "$rel" dir "$rules"; then
            rm -rf -- "$d"
        fi
    done < <(find "$stage" -depth -type d -empty -print0)
    # 再清理因删除文件而变空的目录
    find "$stage" -depth -type d ! -path "$stage" -empty -delete 2>/dev/null || true

    log_info "[$job] reflink 快照完成: $(du -sh "$stage" 2>/dev/null | cut -f1) (排除 ${delete_count} 个文件)"
    echo "$stage"
}

cleanup_stage() {
    local job="$1"
    # 删除整个 job 快照目录（含 stage 与空目录残留），释放磁盘。
    rm -rf "${OMR_TMP_ROOT:-/tmp/oh-my-rclone}/$job"
    # 若根目录已空（无其他任务残留），一并删除，避免 /tmp 留空壳。
    rmdir "${OMR_TMP_ROOT:-/tmp/oh-my-rclone}" 2>/dev/null || true
}

# ----------------------------------------------------------- Docker 适配
# 返回 0 当且仅当 docker.sock 可用且 docker 适配开启。
docker_available() {
    [ "${DOCKER_ADAPT_ENABLE}" = "true" ] || return 1
    [ -S "${DOCKER_API}" ] || { log_warn "docker 适配已开启但 ${DOCKER_API} 不可用，跳过 docker 协同"; return 1; }
    return 0
}

# 计算本次要 pause 的容器集合（命中规则且正在运行、且绝不包含本容器）。
# 通过 curl 访问 docker.sock 的 API：GET /containers/json 拿到运行中的容器。
get_pause_targets() {
    [ -S "${DOCKER_API}" ] || { echo ""; return 1; }
    local json containers
    json="$(curl -s --unix-socket "${DOCKER_API}" "http://localhost/containers/json" 2>/dev/null)"
    [ -z "$json" ] && { echo ""; return 1; }

    local record=1 names name
    # DOCKER_CONTAINERS 逗号分隔记录表
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        [ "$record" = "1" ] || record=1
        # 记录表
    done <<< "${DOCKER_CONTAINERS//,/ }"

    containers=""
    # 用 python 解析（容器内无 python 则用 jq 不存在，改用 grep 方案）。
    # 简化实现：用 shell 提取 name 列表。
    # api 返回数组：[{"Id":"...","Names":["/name"]}, ...]
    # 用 grep/sed 提取 /name
    local list
    list="$(echo "$json" | grep -o '"Names":\[[^]]*\]' | sed -E 's/.*\[([^]]*)\].*/\1/; s/"//g; s/,/\n/g' | sed 's#^/##')"

    case "${DOCKER_MODE}" in
        whitelist)
            for n in $list; do
                if contains "$n" "${DOCKER_CONTAINERS}" && [ "$n" != "$CONTAINER_NAME" ] && [ "$n" != "$SELF_CONTAINER" ]; then
                    containers="${containers}${n} "
                fi
            done
            ;;
        blacklist)
            for n in $list; do
                if ! contains "$n" "${DOCKER_CONTAINERS}" && [ "$n" != "$CONTAINER_NAME" ] && [ "$n" != "$SELF_CONTAINER" ]; then
                    containers="${containers}${n} "
                fi
            done
            ;;
    esac
    # 强守卫：无论如何去掉自己，杜绝自冻死循环
    containers="$(echo "$containers" | tr ' ' '\n' | grep -vx "$CONTAINER_NAME" | grep -vx "$SELF_CONTAINER" | grep -vx '' | tr '\n' ' ')"
    echo "$containers"
}

contains() {
    local item="$1" list="$2" x
    for x in $(echo "$list" | tr ',' ' '); do
        [ "$x" = "$item" ] && return 0
    done
    return 1
}

docker_pause_all() {
    local list="$1" c pause_err=0
    for c in $list; do
        if curl -s -X POST --unix-socket "${DOCKER_API}" \
            "http://localhost/containers/${c}/pause" >/dev/null 2>&1; then
            log_info "已 pause 容器: $c"
        else
            log_warn "pause 失败: $c"; pause_err=1
        fi
    done
    return $pause_err
}

docker_unpause_all() {
    local list="$1" c ret=0 i
    for c in $list; do
        i=0
        while [ "$i" -lt "${UNPAUSE_RETRY}" ]; do
            if curl -s -X POST --unix-socket "${DOCKER_API}" \
                "http://localhost/containers/${c}/unpause" >/dev/null 2>&1; then
                log_info "已 unpause 容器: $c"; break
            fi
            i=$((i+1)); [ "$i" -lt "${UNPAUSE_RETRY}" ] && sleep "${UNPAUSE_WAIT}"
        done
        [ "$i" -ge "${UNPAUSE_RETRY}" ] && { log_error "unpause 失败: $c"; ret=1; }
    done
    return $ret
}

# ----------------------------------------------------------- rclone 统计解析
# 解析 rclone sync 输出：累计 bytes transferred，并捕获失败/差异文件。
# rclone 默认输出 "Transferred: X ... (Y Bytes, Z%)" 等；也收集 "ERROR : file" 行。
# 通过临时文件交互更稳妥，此处由 job.sh 把输出写入文件后回调收集。
gather_stats() {
    local logfile="$1"
    printf 'bytes=0\nfailed=\n'
    local bytes failed_lines
    bytes="$(grep -oE 'bytes transferred[^,)]*' "$logfile" 2>/dev/null | head -1 | grep -oE '[0-9.]+ ?[GMk]?i?B' | head -1 || echo "")"
    # 提取 ERROR 记录中的失败文件（格式：2024/.. ERROR : /path/x: message）
    failed_lines="$(grep -iE 'ERROR\s*:' "$logfile" 2>/dev/null | sed -E 's/^.*ERROR\s*:\s+(.*):.*/\1/' | grep -vE 'sync.*:.*ERROR' | head -n "${FAIL_LIST_MAX}")"
    echo "bytes=$bytes"
    echo "failed=$failed_lines"
}

# 把容量字符串（如 "1.5 MiB"）解析为字节，便于失败文件大小合计。
to_bytes() {
    local v="$1" mul=1 num unit
    v=$(echo "$v" | tr -d ' ')
    unit=$(echo "$v" | grep -oE '[A-Za-z]+$' || true)
    num=$(echo "$v" | grep -oE '^[0-9.]+' || echo 0)
    case "$unit" in
        KiB|KiB) mul=1024 ;;
        MiB) mul=$((1024*1024)) ;;
        GiB) mul=$((1024*1024*1024)) ;;
        TiB) mul=$((1024*1024*1024*1024)) ;;
        kB|KB) mul=1000 ;;
        MB) mul=$((1000*1000)) ;;
        GB) mul=$((1000*1000*1000)) ;;
        B) mul=1 ;;
        *) mul=1 ;;
    esac
    awk -v n="$num" -v m="$mul" 'BEGIN{printf "%d", n*m}'
}