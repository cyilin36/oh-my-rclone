#!/usr/bin/env bash
# entrypoint.sh - oh-my-rclone 容器入口
# 职责：
#   1. 读取 conf/config.toml（合并 .env 环境变量默认）→ 自动生成 rclone.conf（各 sftp 远端）
#   2. 注册 cron 定时任务（全局 schedule）
#   3. 导出全局配置到环境，供 run-backup.sh / job.sh 使用
#   4. 常驻运行（输出日志到 stdout/stderr）
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

CONF_DIR="${CONF_DIR:-/etc/oh-my-rclone/conf}"
# rclone.conf 生成到可写目录（conf 卷可能是只读挂载）
RCLONE_CONF="${RCLONE_CONF:-/var/lib/oh-my-rclone/rclone.conf}"

# 加载全局有效配置（合并 .env 默认 + config.toml 顶部覆盖）到当前 shell 环境。
load_globals_into_env() {
    local line k v
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        k="${line%%=*}"; v="${line#*=}"
        # 仅导出字母数字下划线开头的键（安全）
        case "$k" in
            [A-Za-z_]*=*) export "$k=$v" ;;
        esac
    done < <(python3 "$PARSE_PY" --global "$CONFIG_TOML" 2>/dev/null)
}

# 由 --remotes 输出生成 rclone.conf（每个远端一段）。
# 若 RCLONE_CONF 已存在（用户预置，如 local 后端测试或手工配置），则沿用。
generate_rclone_conf() {
    if [ -s "$RCLONE_CONF" ]; then
        log_info "rclone.conf 已存在（沿用）：$RCLONE_CONF"
        return 0
    fi
    mkdir -p "$(dirname "$RCLONE_CONF")"
    : > "$RCLONE_CONF"
    local block="" line
    local rname rhost ruser rpass rport rkey
    rname=""; rhost=""; ruser="root"; rpass=""; rport="22"; rkey=""

    flush_remote() {
        if [ -z "$rname" ] || [ -z "$rhost" ]; then return; fi
        log_info "生成 sftp 远端 [$rname] → ${ruser}@${rhost}:${rport}"
        {
            echo "[${rname}]"
            echo "type = sftp"
            echo "host = ${rhost}"
            echo "user = ${ruser}"
            echo "port = ${rport}"
            if [ -n "$rpass" ]; then
                echo "pass = $(rclone obscure "$rpass" 2>/dev/null || echo "$rpass")"
            fi
            if [ -n "$rkey" ] && [ -f "$rkey" ]; then
                echo "key_file = ${rkey}"
            fi
        } >> "$RCLONE_CONF"
        rname=""; rhost=""; ruser="root"; rpass=""; rport="22"; rkey=""
    }

    while IFS= read -r line; do
        [ -z "$line" ] && { flush_remote; continue; }
        # 值带单引号，eval 解析
        eval "k=${line%%=*}; v=${line#*=}"
        case "$k" in
            REMOTE) rname="$v" ;;
            REMOTE_HOST) rhost="$v" ;;
            REMOTE_USER) ruser="$v" ;;
            REMOTE_PASS) rpass="$v" ;;
            REMOTE_PORT) rport="$v" ;;
            REMOTE_KEY_FILE) rkey="$v" ;;
        esac
    done < <(python3 "$PARSE_PY" --remotes "$CONFIG_TOML" 2>/dev/null)
    flush_remote

    if [ -s "$RCLONE_CONF" ]; then
        log_info "rclone.conf 已生成（远端数: $(grep -c '^\[.*\]$' "$RCLONE_CONF" 2>/dev/null || echo 0)）"
        return 0
    else
        log_error "未生成任何 sftp 远端：请至少配置 REMOTE_HOST（.env 或 config.toml），否则无法备份"
        return 1
    fi
}

setup_cron() {
    local schedule="${CRON_SCHEDULE:-0 3 * * *}"
    mkdir -p /var/spool/cron/crontabs
    local crontab_file="/var/spool/cron/crontabs/root"
    # 使用 flock 防止容器内并发重入导致重复备份
    echo "${schedule} flock -n /var/lib/oh-my-rclone/backup.lock ${SCRIPT_DIR}/run-backup.sh >> /var/lib/oh-my-rclone/backup.log 2>&1" \
        > "$crontab_file"
    # 启动 dcron
    if command -v crond >/dev/null 2>&1; then
        /usr/sbin/crond 2>/dev/null || crond 2>/dev/null || true
    else
        log_error "未找到 crond，定时将不可用（可手动调用 run-backup.sh）"
    fi
    log_info "cron 已注册: ${schedule}"
    cat "$crontab_file"
}

# 常驻：保持容器存活并把各处日志汇流
keepalive() {
    log_info "oh-my-rclone 已就绪。容器名: ${CONTAINER_NAME}（将被 docker 适配强制排除）"
    log_info "rclone 版本: $(rclone version 2>/dev/null | head -1 || echo unknown)"
    log_info "reflink=${REFLINK_ENABLE} docker_adapt=${DOCKER_ADAPT_ENABLE} webhook=${WEBHOOK_ENABLE}"
    if [ "${DOCKER_ADAPT_ENABLE}" = "true" ] && [ -S "${DOCKER_API}" ]; then
        log_warn "docker 适配已开启，将与宿主机 Docker 交互；本容器始终被排除避免自冻。"
    fi
    # tail 备份日志到 stdout，并常驻
    touch /var/lib/oh-my-rclone/backup.log
    tail -F /var/lib/oh-my-rclone/backup.log &
    # 无限循环保持存活
    while :; do sleep 3600; done
}

main() {
    load_globals_into_env
    generate_rclone_conf || log_warn "rclone.conf 未生成，请检查 config.toml / .env 的远端配置"
    setup_cron
    keepalive
}

main "$@"
exit $?