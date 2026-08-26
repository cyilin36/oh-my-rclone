#!/usr/bin/env bash
# cleanup-logs.sh - 手动/定时触发日志自动清理。
#
# 清理逻辑（见 lib.sh 的 cleanup_logs）：
#   1. backup.log 超过 LOG_MAX_SIZE（默认 20M）时轮转，保留 LOG_ROTATE_KEEP 份旧日志；
#   2. 删除 $LOG_DIR 下 mtime 超过 LOG_RETENTION_DAYS（默认 7 天）的文件；
#   3. 清理空子目录。
# 触发方式：entrypoint 启动、每批备份结束、每日 cron（LOG_CLEANUP_SCHEDULE）。
#
# 用法：
#   docker compose exec oh-my-rclone /scripts/cleanup-logs.sh
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

mkdir -p "$LOG_DIR" 2>/dev/null || true

# 持有清理锁，避免与其它清理/轮转并发。
exec 9>"${LOG_DIR}/cleanup.lock"
if ! flock -n 9; then
    log_warn "日志清理已在运行（${LOG_DIR}/cleanup.lock 被占用），本次跳过"
    exit 0
fi

cleanup_logs
exit $?
