#!/usr/bin/env bash
# notify.sh - webhook 通知
# 兼容 astrbot_plugin_push_lite：该插件以 token 提供“向已绑定目标发送文本消息”的 API。
# 这里向 ASTROBOT_PUSH_URL 发送 POST，携带 token 与 url-encoded message。
# URL/鉴权完全可用环境变量覆盖，以兼容该插件或其它兼容端点。
#
# 用法（被 source）：
#   send_notify "<消息>" [push_url] [push_token] [success_only]
# 参数可省略，省略则用环境变量（ASTROBOT_PUSH_URL / ASTROBOT_PUSH_TOKEN / WEBHOOK_SUCCESS_ONLY）。
set -o pipefail
: "${WEBHOOK_ENABLE:=false}"
: "${ASTROBOT_PUSH_URL:=}"
: "${ASTROBOT_PUSH_TOKEN:=}"
: "${ASTROBOT_PUSH_KEY:=token}"     # 鉴权字段名，兼容 astrbot 默认 token
: "${WEBHOOK_SUCCESS_ONLY:=false}"

# 引入日志
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh" >/dev/null 2>&1 || true

# 发送 webhook。
# 参数：$1=消息  $2=push_url(可选)  $3=push_token(可选)
# 是否发送由 WEBHOOK_ENABLE 决定；success_only 由调用方在调用前判断。
# 返回 0 发送成功/跳过，1 失败。
send_notify() {
    local msg="$1"
    local url="${2:-${ASTROBOT_PUSH_URL}}"
    local token="${3:-${ASTROBOT_PUSH_TOKEN}}"

    [ "${WEBHOOK_ENABLE}" = "true" ] || return 0
    [ -n "$url" ] || { log_warn "webhook 已开启但未配置 ASTROBOT_PUSH_URL"; return 1; }

    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 10 --max-time 30 \
        -X POST "$url" \
        --data-urlencode "${ASTROBOT_PUSH_KEY}=${token}" \
        --data-urlencode "message=${msg}" 2>/dev/null)"
    if [ "$?" -ne 0 ] || [ -z "$code" ] || [ "${code:0:1}" = "5" ] || [ "$code" = "0" ]; then
        log_error "webhook 发送失败 (http=$code) 至 $url"
        echo "$msg" > /var/lib/oh-my-rclone/webhook-fail-$(date +%s).txt 2>/dev/null || true
        return 1
    fi
    log_info "webhook 已发送 (http=$code)"
    return 0
}

# 允许被 source 使用
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    send_notify "${1:-}" "${2:-}" "${3:-}" "${4:-}"
    exit $?
fi