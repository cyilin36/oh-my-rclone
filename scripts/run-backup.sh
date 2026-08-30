#!/usr/bin/env bash
# run-backup.sh - 遍历 conf/config.toml 的任务，串行执行所有备份，汇总统计并上报批次 webhook。
#
# 用法：
#   FORCE_DRY_RUN=1 ./run-backup.sh      # 全部任务 dry-run（预检）
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/notify.sh" >/dev/null 2>&1 || true

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

    # 解析 config.toml 的任务块（空行分隔）
    local block="" line
    local has_job=0
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            # 空行 = 任务块结束
            if [ -n "$block" ]; then
                run_one_jobblock "$block"
                has_job=1
                block=""
            fi
            continue
        fi
        block="${block}${block:+$'\n'}${line}"
    done < <(parse_toml_jobs)

    if [ -n "$block" ]; then
        run_one_jobblock "$block"
        has_job=1
    fi

    if [ "$has_job" -eq 0 ]; then
        log_warn "未解析到任何任务（config.toml 为空或格式错误？）：$CONFIG_TOML"
    fi

    t_end="$(date +%s)"
    local duration
    duration="$(fmt_duration $((t_end - t_start)))"
    log_info "========== 备份批次结束 $(date '+%F %T') 总耗时 $duration =========="

    # 批次结束后触发日志自动清理（轮转 + 按保留天数删除），维护留痕进 backup.log
    cleanup_logs

    return $overall_ok
}

# 执行单个任务块。参数为单任务块文本（含引号转义的 key=value 多行）。
run_one_jobblock() {
    local block="$1"
    local start_j end_j rc
    local jname b_src b_dest b_remote b_exclude
    local b_reflink b_dockeren b_dockermode b_dockercontainers
    local b_stopcontainers b_stoptim b_startretry b_startwait
    local b_whenable b_whsuccess b_whurl b_whtoken b_whumo

    # 从块文本解析出各字段（值已由 python 单引号转义）
    eval "$(printf '%s\n' "$block")"
    jname="${JOBNAME:-_unnamed}"; b_src="${SRC:-}"; b_dest="${DEST:-}"
    b_remote="${REMOTE:-default}"; b_exclude="${EXCLUDE:-}"
    b_reflink="${REFLINK_ENABLE:-true}"; b_dockeren="${DOCKER_ADAPT_ENABLE:-false}"
    b_dockermode="${DOCKER_MODE:-whitelist}"; b_dockercontainers="${DOCKER_CONTAINERS:-}"
    b_stopcontainers="${DOCKER_STOP_CONTAINERS:-}"; b_stoptim="${DOCKER_STOP_TIMEOUT:-30}"
    b_startretry="${DOCKER_START_RETRY:-5}"; b_startwait="${DOCKER_START_WAIT:-2}"
    b_whenable="${WEBHOOK_ENABLE:-false}"; b_whsuccess="${WEBHOOK_SUCCESS_ONLY:-false}"
    b_whurl="${ASTROBOT_PUSH_URL:-}"; b_whtoken="${ASTROBOT_PUSH_TOKEN:-}"
    b_whumo="${ASTROBOT_PUSH_UMO:-}"

    start_j="$(date +%s)"
    log_info ">>> 执行任务 [$jname] src=$b_src dest=$b_dest remote=$b_remote"

    # 用环境变量调用 job.sh
    env JOBNAME="$jname" \
        SRC="$b_src" DEST="$b_dest" REMOTE="$b_remote" EXCLUDE="$b_exclude" \
        REFLINK_ENABLE="$b_reflink" \
        DOCKER_ADAPT_ENABLE="$b_dockeren" DOCKER_MODE="$b_dockermode" DOCKER_CONTAINERS="$b_dockercontainers" \
        DOCKER_STOP_CONTAINERS="$b_stopcontainers" DOCKER_STOP_TIMEOUT="$b_stoptim" \
        DOCKER_START_RETRY="$b_startretry" DOCKER_START_WAIT="$b_startwait" \
        WEBHOOK_ENABLE="$b_whenable" WEBHOOK_SUCCESS_ONLY="$b_whsuccess" \
        ASTROBOT_PUSH_URL="$b_whurl" ASTROBOT_PUSH_TOKEN="$b_whtoken" ASTROBOT_PUSH_UMO="$b_whumo" \
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

main "$@"
exit $?