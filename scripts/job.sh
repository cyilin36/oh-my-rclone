#!/usr/bin/env bash
# job.sh - 执行单条同步备份任务
# 由 run-backup.sh 调用。参数为环境变量：
#   JOBNAME SRC DEST SSH_HOST SSH_USER SSH_PASS SSH_PORT SSH_KEY EXTRA_EXCLUDE
# 也可直接以 `JOBNAME=.. SRC=.. DEST=.. ./job.sh` 形式手工调用用于测试。
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

: "${JOBNAME:=unnamed}"
: "${SRC:=}"
: "${DEST:=}"
: "${SSH_HOST:=}"
: "${SSH_USER:=root}"
: "${SSH_PASS:=}"
: "${SSH_PORT:=22}"
: "${SSH_KEY:=}"
: "${EXTRA_EXCLUDE:=}"

# 任务返回后统一处理：卸载 trap 中的临时变量。
RESULT=0

# 供外部读取的统计（由 run-backup 汇总）
JOB_BYTES=0
JOB_FAILED_COUNT=0

# 解析 sftp 远程：DEST=remote:path
IFS=: read -r RCLONE_ALIAS RCLONE_PATH <<< "${DEST}"

# reflink 阶段必须的 stage 根
STAGE=""

# docker 待处理集合（引用级），仅为会话内安全引用避免被误清
PAUSE_LIST=""

_cleanup_job() {
    # 1) 无论成败，确保已 pause 的容器被 unpause（自身永不在列表中）
    if [ -n "$PAUSE_LIST" ]; then
        log_info "[$JOBNAME] 任务结束，确保 unpause: $PAUSE_LIST"
        docker_unpause_all "$PAUSE_LIST" || true
    fi
    # 2) 删除 reflink 快照，避免磁盘占用
    if [ -n "$JOBNAME" ] && [ "${REFLINK_ENABLE}" = "true" ]; then
        cleanup_stage "$JOBNAME"
    fi
}
trap '_cleanup_job' EXIT

run_one_job() {
    local start_total end_total
    if [ -z "$SRC" ] || [ -z "$DEST" ]; then
        log_error "[$JOBNAME] 缺少 SRC 或 DEST"; return 1
    fi

    log_info "[$JOBNAME] ===== 开始备份 ===== src=$SRC dest=$DEST"

    # ---- 排除规则（任务级 extra + 全局 excludes.conf + 自动排除 reflink 区）----
    local rules="$(load_excludes "${EXCLUDE_CONF}")"
    [ -z "$rules" ] && rules=""
    if [ -n "$EXTRA_EXCLUDE" ]; then
        # 额外规则用 ; 分隔追加
        rules="${rules}${rules:+$'\n'}$(echo "$EXTRA_EXCLUDE" | tr ';' '\n')"
    fi
    # 自动排除 /tmp 快照根，杜绝复制/上传环（双向保护）
    rules="${rules}${rules:+$'\n'}dir=${OMR_TMP_ROOT#/}"
    rules="${rules}${rules:+$'\n'}path=${OMR_TMP_ROOT#/}"

    # ---- docker 适配：得到待 pause 列表（强守卫已在本库内去掉本容器）----
    local need_docker=0
    PAUSE_LIST=""
    if docker_available; then
        PAUSE_LIST="$(get_pause_targets)"
        if [ -n "$PAUSE_LIST" ]; then
            log_info "[$JOBNAME] docker 适配：待 pause 容器 = $PAUSE_LIST"
            # 强自冻守卫（双保险）
            if echo "$PAUSE_LIST" | grep -qx "$CONTAINER_NAME" \
                || echo "$PAUSE_LIST" | grep -qx "$SELF_CONTAINER"; then
                log_error "[$JOBNAME] 检测到列表包含本容器！已强制移除避免自冻。"
                PAUSE_LIST="$(echo "$PAUSE_LIST" | sed "s/\b${SELF_CONTAINER}\b//g; s/\b${CONTAINER_NAME}\b//g" | tr -s ' ')"
            fi
            need_docker=1
        fi
    else
        log_info "[$JOBNAME] docker 适配未启用或不可用，跳过容器协同"
    fi

    # ---- reflink 联动决策 ----
    # 目标 rclone 使用的源
    local rclone_src="$SRC"
    local uploaded_bytes=0 fail_count=0
    local tmp_out rc

    if [ "${REFLINK_ENABLE}" = "true" ]; then
        log_info "[$JOBNAME] reflink 开启：先冻结容器做快照，再尽快解冻让其恢复服务"
        # 冻结
        [ "$need_docker" = "1" ] && docker_pause_all "$PAUSE_LIST"
        # 快照（此期间容器冻结，业务相对静止；快照瞬间完成）
        if ! STAGE="$(make_reflink_stage "$SRC" "$JOBNAME" "$rules")"; then
            [ "$need_docker" = "1" ] && docker_unpause_all "$PAUSE_LIST"
            # STAGE 为空则按错误处理（strict 不支持 reflink 时返回非 0）
            log_error "[$JOBNAME] reflink 快照失败"
            return 1
        fi
        # 立即解冻，恢复业务容器（长上传不占用冻结时间）
        [ "$need_docker" = "1" ] && docker_unpause_all "$PAUSE_LIST"
        PAUSE_LIST=""   # 已解冻，重置避免 trap 重复
        rclone_src="$STAGE"
    else
        log_info "[$JOBNAME] reflink 关闭：冻结容器 → 全程上传 → 解冻"
        [ "$need_docker" = "1" ] && docker_pause_all "$PAUSE_LIST"
        rclone_src="$SRC"
    fi

    # ---- 执行 rclone 上传 ----
    local logdir="/var/lib/oh-my-rclone"
    mkdir -p "$logdir" 2>/dev/null || logdir="${STATS_DIR:-/tmp}"
    tmp_out="$logdir/${JOBNAME}.$(date +%s).log"
    local args=( sync "$rclone_src" "$DEST" -v --stats-one-line --stats 5s )
    # reflink 关闭时，无需 --dry-run（正式执行）。
    # 若传入 FORCE_DRY_RUN=1 则 dry-run（测试/预检用）。
    if [ "${FORCE_DRY_RUN:=0}" = "1" ]; then
        args+=( --dry-run )
    fi
    # 应用排除规则到 rclone
    local exc
    while IFS= read -r exc; do
        [ -n "$exc" ] && args+=( --exclude "$exc" )
    done < <(build_rclone_excludes "$rules")

    log_info "[$JOBNAME] 执行 rclone ${args[*]:0:8} ..."
    rclone "${args[@]}" >"$tmp_out" 2>&1
    rc=$?

    # ---- 统计解析 ----
    # 汇总 bytes。rclone -v 统计行形如 "26 B / 26 B, 100%, 0 B/s, ETA -"。
    # 先匹配 "n B / n B"（传输累计），再取行首字节数，避免误取 "0 B/s" 速率。
    uploaded_bytes="$(grep -oE '[0-9.]+ ?[KMGTP]?i?B / [0-9.]+ ?[KMGTP]?i?B' "$tmp_out" \
        | tail -1 | grep -oE '^[0-9.]+ ?[KMGTP]?i?B' | head -1 || echo "0 B")"

    # 收集失败文件清单（名字 + 大小），供 webhook 报告。
    # 失败文件大小 = 本地对应源文件大小合计（stat 取自 stage 或源相应路径）。
    local failed_files=""
    local fsize_bytes=0 fpath fstat
    # 过滤诊断行：只保留真正针对文件的 ERROR 行。
    # rclone 诊断行（Local file system at / Attempt N/3 / not deleting / Failed）应被忽略。
    local error_lines
    error_lines="$(grep -iE 'ERROR\s*:' "$tmp_out" 2>/dev/null \
        | grep -viE 'Local file system at|Attempt [0-9]+/[0-9]+ failed|not deleting|Failed to (sync|copy)|failed to (read|write|create)|error reading|error writing' || true)"
    local fail_count
    fail_count="$(printf '%s\n' "$error_lines" | grep -cE 'ERROR\s*:' 2>/dev/null || true)"
    if [ "$fail_count" -gt 0 ]; then
        # 行形如：... ERROR : /relative/path/foo: error message
        local got=0
        while IFS= read -r fpath; do
            fpath="${fpath#/}"
            fpath="${fpath#data/}"     # 对齐 stage 相对路径
            failed_files="${failed_files}${failed_files:+; }${fpath}"
            # 大小统计：优先 stat stage 下的对应文件，其次源文件
            if [ -n "$STAGE" ] && [ -f "$STAGE/$fpath" ]; then
                fstat="$(stat -c%s "$STAGE/$fpath" 2>/dev/null || echo 0)"
            elif [ -f "$SRC/$fpath" ]; then
                fstat="$(stat -c%s "$SRC/$fpath" 2>/dev/null || echo 0)"
            else
                fstat=0
            fi
            fsize_bytes=$(( fsize_bytes + ${fstat:-0} ))
            got=$((got+1))
            [ "$got" -ge "$FAIL_LIST_MAX" ] && { failed_files+="（及更多，共 ${fail_count} 个）"; break; }
        done < <(printf '%s\n' "$error_lines" | sed -E 's/^.*ERROR\s*:\s*(.*)$/\1/' | cut -d: -f1)
    fi

    JOB_BYTES="$uploaded_bytes"
    JOB_FAILED_COUNT="$fail_count"

    # 写入 STATS_FILE 供 run-backup 汇总（存在则写）
    if [ -n "${STATS_FILE:-}" ]; then
        {
            echo "bytes=$uploaded_bytes"
            echo "fail_count=$fail_count"
            echo "fails=${failed_files}"
            echo "fail_bytes=$fsize_bytes"
        } > "$STATS_FILE"
    fi

    if [ "$rc" -eq 0 ]; then
        log_info "[$JOBNAME] 同步成功 (bytes transferred ≈ $uploaded_bytes)"
        RESULT=0
    else
        log_error "[$JOBNAME] 同步失败 rc=$rc，失败文件数=$fail_count；详见 $tmp_out"
        [ "$fail_count" -gt 0 ] && log_error "[$JOBNAME] 失败文件: ${failed_files}"
        RESULT=1
    fi

    # reflink 关闭场景的解冻此时进行
    if [ "${REFLINK_ENABLE}" != "true" ] && [ -n "$PAUSE_LIST" ]; then
        docker_unpause_all "$PAUSE_LIST"
        PAUSE_LIST=""
    fi

    log_info "[$JOBNAME] ===== 任务结束 exit=$RESULT ====="
    return "$RESULT"
}

run_one_job
exit $?