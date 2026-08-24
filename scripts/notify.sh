#!/usr/bin/env bash
# notify.sh - webhook 通知
# 兼容 astrbot_plugin_push_lite：该插件以 token 提供“向已绑定目标发送文本消息”的 API。
# 这里向 ASTROBOT_PUSH_URL 发送 POST，携带 token 与 url-encoded message。
# URL/鉴权完全可用环境变量覆盖，以兼容该插件或其它兼容端点。
#
# 用法：notify.sh <消息文本>
set -o pipefail
: "${WEBHOOK_ENABLE:=false}"
: "${ASTROBOT_PUSH_URL:=}"
: "${ASTROBOT_PUSH_TOKEN:=}"
: "${ASTROBOT_PUSH_KEY:=token}"     # 鉴权字段名，兼容 astrbot 默认 token

# 引入日志
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh" >/dev/null 2>&1 || true

send_notify() {
    local msg="$1"
    [ "${WEBHOOK_ENABLE}" = "true" ] || return 0
    [ -n "${ASTROBOT_PUSH_URL}" ] || { log_warn "webhook 已开启但未配置 ASTROBOT_PUSH_URL"; return 1; }

    local code
    # 构造表单。astrbot_plugin_push_lite 通常接受 token + message（urlencoded 表单）。
    # 这里用 --data-urlencode 做安全编码，避免引号/换行破坏请求。
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 10 --max-time 30 \
        -X POST "${ASTROBOT_PUSH_URL}" \
        --data-urlencode "${ASTROBOT_PUSH_KEY}=${ASTROBOT_PUSH_TOKEN}" \
        --data-urlencode "message=${msg}" 2>/dev/null)"
    if [ "$?" -ne 0 ] || [ -z "$code" ] || [ "${code:0:1}" = "5" ] || [ "$code" = "0" ]; then
        log_error "webhook 发送失败 (http=$code) 至 ${ASTROBOT_PUSH_URL}"
        # 留存原始消息以便排查
        echo "$msg" > /var/lib/oh-my-rclone/webhook-fail-$(date +%s).txt 2>/dev/null || true
        return 1
    fi
    log_info "webhook 已发送 (http=$code)"
    return 0
}

# 允许被 source 使用
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    send_notify "${1:-}"
    exit $?
fi