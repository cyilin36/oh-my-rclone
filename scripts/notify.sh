#!/usr/bin/env bash
# notify.sh - webhook 通知
# 兼容 astrbot_plugin_push_lite（https://github.com/Raven95676/astrbot_plugin_push_lite）
# 真实 API 规范（见该插件 README / api.py）：
#   POST /send   请求体 JSON { "content": 消息, "umo": 目标会话标识 }
#   Header: Authorization: Bearer <API_TOKEN>
#   (umo 为必填，可在 astrbot 里用 /sid 查询)
#
# 用法（被 source）：
#   send_notify "<消息>" [push_url] [push_token] [umo]
# 参数可省略，省略则用环境变量（ASTROBOT_PUSH_URL / ASTROBOT_PUSH_TOKEN / ASTROBOT_PUSH_UMO）。
set -o pipefail
: "${WEBHOOK_ENABLE:=false}"
: "${ASTROBOT_PUSH_URL:=}"
: "${ASTROBOT_PUSH_TOKEN:=}"
: "${ASTROBOT_PUSH_UMO:=}"       # 目标会话标识（astrbot /sid 查询），必填
: "${WEBHOOK_SUCCESS_ONLY:=false}"

# 引入日志
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh" >/dev/null 2>&1 || true

# 发送 webhook（astrbot_plugin_push_lite）。
# 参数：$1=消息  $2=push_url(可选)  $3=push_token(可选)  $4=umo(可选)
# 是否发送由 WEBHOOK_ENABLE 决定；success_only 由调用方在调用前判断。
# 返回 0 发送成功/跳过，1 失败。
send_notify() {
    local msg="$1"
    local url="${2:-${ASTROBOT_PUSH_URL}}"
    local token="${3:-${ASTROBOT_PUSH_TOKEN}}"
    local umo="${4:-${ASTROBOT_PUSH_UMO}}"

    [ "${WEBHOOK_ENABLE}" = "true" ] || return 0
    [ -n "$url" ] || { log_warn "webhook 已开启但未配置 ASTROBOT_PUSH_URL"; return 1; }
    [ -n "$umo" ] || { log_warn "webhook 已开启但未配置 ASTROBOT_PUSH_UMO（目标会话标识，astrbot /sid 查询）"; return 1; }

    # 兼容 url 已含 /send 或 /send_form 路径的情况
    local endpoint="$url"
    case "$endpoint" in
        */send|*/send_form|*/health) : ;;   # 已带路径
        */) endpoint="${endpoint}send" ;;   # 以 / 结尾
        *)  endpoint="${endpoint}/send" ;;  # 裸地址
    esac

    local code
    # 用 JSON 请求体（/send 端点），Authorization: Bearer 鉴权
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 10 --max-time 30 \
        -X POST "$endpoint" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        --data "$(python3 -c 'import json,sys; print(json.dumps({"content": sys.argv[1], "umo": sys.argv[2]}))' "$msg" "$umo")" 2>/dev/null)"
    if [ "$?" -ne 0 ] || [ -z "$code" ] || [ "${code:0:1}" = "5" ] || [ "$code" = "0" ]; then
        log_error "webhook 发送失败 (http=$code) 至 $endpoint"
        mkdir -p "${LOG_DIR:-/var/lib/oh-my-rclone/logs}/webhook" 2>/dev/null || true
        echo "$msg" > "${LOG_DIR:-/var/lib/oh-my-rclone/logs}/webhook/webhook-fail-$(date +%Y%m%d-%H%M%S).txt" 2>/dev/null || true
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