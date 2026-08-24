#!/usr/bin/env bash
# run-backup.sh - 遍历 jobs.conf 串行执行所有备份任务，汇总统计并上报 webhook。
#
# 用法：
#   CONFIG_JOBS=/etc/oh-my-rclone/conf/jobs.conf ./run-backup.sh
#   FORCE_DRY_RUN=1 ./run-backup.sh      # 全部任务 dry-run（预检）
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/notify.sh" >/dev/null 2>&1 || true

CONFIG_JOBS="${CONFIG_JOBS:-${CONF_DIR}/jobs.conf}"
: "${FORCE_DRY_RUN:=0}"
STATS_DIR="$(mktemp -d)"
trap 'rm -rf "$STATS_DIR"' EXIT

overall_ok=0
job_count=0
bytes_sum=0
fail_global=""
fail_big=0

main() {
    local t_start t_end
    t_start="$(date +%s)"
    log_info "========== 备份批次开始 $(date '+%F %T') =========="

    local total_lines
    total_lines="$(parse_jobs "$CONFIG_JOBS" | wc -l)"
    if [ "${total_lines}" -eq 0 ]; then
        log_warn "未解析到任何任务（jobs.conf 为空或格式错误？）：$CONFIG_JOBS"
    fi

    local block=() line key
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        key="${line%%=*}"
        # 用 JOBNAME 作为任务边界：遇到新任务名时先处理上一个完整块（不依赖固定行数）
        if [ "$key" = "JOBNAME" ] && [ ${#block[@]} -gt 0 ]; then
            run_one_jobblock "${block[@]}"
            block=()
        fi
        block+=("$line")
    done < <(parse_jobs "$CONFIG_JOBS")

    if [ ${#block[@]} -gt 0 ]; then
        run_one_jobblock "${block[@]}"
    fi

    t_end="$(date +%s)"
    local duration
    duration="$(fmt_duration $((t_end - t_start)))"
    log_info "========== 备份批次结束 $(date '+%F %T') 总耗时 $duration =========="

    # ---- webhook 汇总 ----
    if [ "${WEBHOOK_ENABLE}" = "true" ]; then
        local status overall_success_name start_s end_s
        if [ "$overall_ok" -eq 0 ]; then overall_success_name="成功"; else overall_success_name="失败"; fi
        start_s="$(date -d "@$t_start" '+%F %T' 2>/dev/null || date '+%F %T')"
        end_s="$(date -d "@$t_end" '+%F %T' 2>/dev/null || date '+%F %T')"
        build_batch_notice "$overall_success_name" "$duration" "$start_s" "$end_s" \
            "$bytes_sum" "$fail_global" "$job_count" "$fail_big"
    fi

    return $overall_ok
}

# 执行单个任务块。参数为若干键值行（key=val，来自 parse_jobs 单任务输出），JOBNAME 从中提取。
run_one_jobblock() {
    local line key val start_j end_j rc
    local jname b_src b_dest b_extra
    jname="_unnamed"; b_src=""; b_dest=""; b_extra=""
    for line in "$@"; do
        key="${line%%=*}"; val="${line#*=}"
        case "$key" in
            JOBNAME) jname="$val" ;;
            SRC)    b_src="$val" ;;
            DEST)   b_dest="$val" ;;
            EXTRA_EXCLUDE) b_extra="$val" ;;
        esac
    done
    start_j="$(date +%s)"
    log_info ">>> 执行任务 [$jname] src=$b_src dest=$b_dest"

    # 用环境变量调用 job.sh
    env JOBNAME="$jname" \
        SRC="$b_src" DEST="$b_dest" EXTRA_EXCLUDE="$b_extra" \
        FORCE_DRY_RUN="$FORCE_DRY_RUN" \
        STATS_FILE="${STATS_DIR}/job-${jname}-$$" \
        "${SCRIPT_DIR}/job.sh"
    rc=$?
    end_j="$(date +%s)"
    log_info "<<< 任务 [$jname] 结束 rc=$rc 耗时 $(fmt_duration $((end_j - start_j)))"

    # 读取任务统计（由 job.sh 写入 STATS_FILE）
    local bytes=0 fails="" fbytes=""
    if [ -f "${STATS_DIR}/job-${jname}-$$" ]; then
        bytes="$(grep -E '^bytes=' "${STATS_DIR}/job-${jname}-$$" | head -1 | cut -d= -f2 || echo "0 B")"
        fails="$(grep -E '^fails=' "${STATS_DIR}/job-${jname}-$$" | head -1 | cut -d= -f2- || echo "")"
        fbytes="$(grep -E '^fail_bytes=' "${STATS_DIR}/job-${jname}-$$" | head -1 | cut -d= -f2 || echo 0)"
    fi
    bytes_sum=$(( bytes_sum + $(to_bytes "$bytes") ))
    fail_big=$(( fail_big + ${fbytes:-0} ))
    if [ -n "$fails" ]; then
        fail_global="${fail_global}${fail_global:+, }[$jname] ${fails}"
    fi

    overall_ok=$(( overall_ok || rc ))
    job_count=$(( job_count + 1 ))
}

# 组装最终 webhook 文本（send_notify 在 notify.sh 中）
build_batch_notice() {
    local status="$1" duration="$2" start_s="$3" end_s="$4" \
          bytes="$5" fail="$6" jcount="$7" fbytes="$8"
    local msg
    msg="【oh-my-rclone 备份报告】${status}\n"
    msg+="任务数: ${jcount}\n"
    msg+="上传数据: ${bytes} B\n"
    msg+="失败文件大小: ${fbytes:-0} B\n"
    msg+="开始: ${start_s}  结束: ${end_s}\n"
    msg+="总耗时: ${duration}\n"
    if [ "$status" = "失败" ]; then
        msg+="失败文件: ${fail:-（无详细清单，见日志）}\n"
    else
        msg+="失败文件: 无\n"
    fi
    msg+="\n（完整日志见容器 stdout / /var/lib/oh-my-rclone/.*.log）"
    # 把字面 \n 解释为真实换行，保证各类推送端正确换行。
    printf -v msg '%b' "$msg"
    send_notify "$msg"
}

main "$@"
exit $?