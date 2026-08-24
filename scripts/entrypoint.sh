#!/usr/bin/env bash
# entrypoint.sh - oh-my-rclone 容器入口
# 职责：
#   1. 从环境变量生成 rclone.conf（主要针对 sftp 远程，密码/密钥）
#   2. 注册 cron 定时任务
#   3. 常驻运行（输出日志到 stdout/stderr）
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

CONF_DIR="${CONF_DIR:-/etc/oh-my-rclone/conf}"
RCLONE_CONF="${RCLONE_CONF:-${CONF_DIR}/rclone.conf}"
: "${CRON_SCHEDULE:=0 3 * * *}"
: "${RCLONE_ALIAS:=backup-sftp}"
: "${SSH_HOST:=}"
: "${SSH_USER:=root}"
: "${SSH_PASS:=}"
: "${SSH_PORT:=22}"
: "${SSH_KEY:=}"
: "${SSH_KEY_FILE:=}"

# 生成/补充 rclone.conf 中的 sftp 远程。
# 优先使用 conf/rclone.conf.example 中已有的 sftp 定义；若未定义则按 env 自动生成一个。
ensure_rclone_conf() {
    mkdir -p "$(dirname "$RCLONE_CONF")"
    if [ -f "$RCLONE_CONF" ] && grep -q "\[${RCLONE_ALIAS}\]" "$RCLONE_CONF" 2>/dev/null; then
        log_info "rclone.conf 已含远程 [$RCLONE_ALIAS]，沿用现有配置"
        return 0
    fi
    # 未找到：若没有 SSH_HOST 则只能提示（需用户提供 conf）
    if [ -z "$SSH_HOST" ]; then
        log_error "未找到远程 [$RCLONE_ALIAS] 且未设置 SSH_HOST，无法自动生成 sftp 远程。"
        log_error "请提供 conf/rclone.conf（含 sftp 远程）或设置对应 SSH_* 环境变量。"
        return 1
    fi
    log_info "自动生成 sftp 远程 [$RCLONE_ALIAS] → ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
    {
        echo "[${RCLONE_ALIAS}]"
        echo "type = sftp"
        echo "host = ${SSH_HOST}"
        echo "user = ${SSH_USER}"
        echo "port = ${SSH_PORT}"
        if [ -n "${SSH_PASS}" ]; then
            # 用 rclone obscure 加密密码写入
            echo "pass = $(rclone obscure "${SSH_PASS}" 2>/dev/null || echo "${SSH_PASS}")"
        fi
        if [ -n "${SSH_KEY_FILE}" ] && [ -f "${SSH_KEY_FILE}" ]; then
            echo "key_file = ${SSH_KEY_FILE}"
        elif [ -n "${SSH_KEY}" ] && [ -f "${SSH_KEY}" ]; then
            echo "key_file = ${SSH_KEY}"
        fi
    } >> "$RCLONE_CONF"
}

setup_cron() {
    mkdir -p /var/spool/cron/crontabs
    local crontab_file="/var/spool/cron/crontabs/root"
    # 使用 flock 防止容器内并发重入导致重复备份
    echo "${CRON_SCHEDULE} flock -n /var/lib/oh-my-rclone/backup.lock ${SCRIPT_DIR}/run-backup.sh >> /var/lib/oh-my-rclone/backup.log 2>&1" \
        > "$crontab_file"
    # 启动 dcron
    if command -v crond >/dev/null 2>&1; then
        /usr/sbin/crond 2>/dev/null || crond 2>/dev/null || true
    else
        log_error "未找到 crond，定时将不可用（可手动调用 run-backup.sh）"
    fi
    log_info "cron 已注册: ${CRON_SCHEDULE}"
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
    ensure_rclone_conf || log_warn "rclone.conf 未就绪，可稍后通过 conf 卷提供"
    setup_cron
    keepalive
}

main "$@"
exit $?