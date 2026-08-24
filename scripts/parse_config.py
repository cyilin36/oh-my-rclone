#!/usr/bin/env python3
# parse_config.py - 合并 .env 默认(环境变量) 与 conf/config.toml，输出供 bash 使用的配置。
#
# 优先级：任务块 > config.toml 顶部(可选) > .env 环境变量默认
#
# 输出（bash 可解析）：
#   --global  全局有效配置（key=value 行），供 entrypoint 生成 rclone.conf / cron / 开关
#   --jobs    每个任务的合并配置，任务之间以空行分隔，键为 KEY=value（含单引号转义）
#
# 用法：
#   parse_config.py --global
#   parse_config.py --jobs <config.toml路径>
import os
import sys
import tomllib

# ----------------------------------------------------------- 配置字段
# .env 环境变量 -> (config.toml 键, 是否布尔, 默认值)
ENV_MAP = {
    "REMOTE_HOST":       ("remote_host", False, ""),
    "REMOTE_USER":       ("remote_user", False, "root"),
    "REMOTE_PASS":       ("remote_pass", False, ""),
    "REMOTE_PORT":       ("remote_port", False, "22"),
    "REMOTE_KEY_FILE":   ("remote_key_file", False, ""),
    "REFLINK_ENABLE":    ("reflink", True, "true"),
    "REFLINK_STRICT":    ("reflink_strict", True, "false"),
    "DOCKER_ADAPT_ENABLE": ("docker_adapt", True, "false"),
    "DOCKER_MODE":       ("docker_mode", False, "whitelist"),
    "DOCKER_CONTAINERS": ("docker_containers", False, ""),
    "WEBHOOK_ENABLE":    ("webhook", True, "false"),
    "WEBHOOK_SUCCESS_ONLY": ("webhook_success_only", True, "false"),
    "ASTROBOT_PUSH_URL": ("astrobot_push_url", False, ""),
    "ASTROBOT_PUSH_TOKEN": ("astrobot_push_token", False, ""),
    "ASTROBOT_PUSH_UMO": ("astrobot_push_umo", False, ""),
    "FAIL_LIST_MAX":     ("fail_list_max", False, "50"),
    "CRON_SCHEDULE":     ("schedule", False, "0 3 * * *"),
    "EXCLUDE_GLOBAL":    ("exclude", False, ""),   # 分号分隔的全局排除
}

# config.toml 顶部可覆盖的全局键
TOP_KEYS = {
    "remote_host", "remote_user", "remote_pass", "remote_port", "remote_key_file",
    "reflink", "reflink_strict", "docker_adapt", "docker_mode", "docker_containers",
    "webhook", "webhook_success_only", "astrobot_push_url", "astrobot_push_token",
    "astrobot_push_umo",
    "fail_list_max", "schedule", "exclude",
}

# 布尔键集合（归一化 true/false/1/0/yes/no）
BOOL_KEYS = {"reflink", "reflink_strict", "docker_adapt", "webhook", "webhook_success_only"}

# 每个任务允许的键
# 注意：docker 适配相关（docker_adapt/docker_mode/docker_containers）为【全局配置】，
# 只在 .env 中设置，不做任务级覆盖，避免多个任务配置冲突。
JOB_KEYS = {
    "name", "src", "dest", "remote", "remote_host", "remote_user", "remote_pass",
    "remote_port", "remote_key_file", "exclude", "enabled", "reflink", "reflink_strict",
    "webhook", "webhook_success_only",
    "astrobot_push_url", "astrobot_push_token", "astrobot_push_umo",
}


def norm_bool(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    s = str(v).strip().lower()
    return "true" if s in ("true", "1", "yes", "on") else "false"


def env_val(key):
    """读环境变量（.env 已由 compose env_file 注入），返回字符串或 None。"""
    v = os.environ.get(key)
    if v is None:
        return None
    return v.strip()


def build_global_from_env():
    """从环境变量构建全局默认配置（字符串字典）。"""
    g = {}
    for env_key, (toml_key, is_bool, default) in ENV_MAP.items():
        v = env_val(env_key)
        if v is None or v == "":
            v = default
        g[toml_key] = norm_bool(v) if is_bool else str(v)
    return g


def toml_scalar(v):
    """把 TOML 标量/列表转成字符串。列表 -> 分号分隔字符串。"""
    if isinstance(v, list):
        return ";".join(str(x) for x in v)
    return str(v)


def apply_top_override(g, top):
    """config.toml 顶部覆盖全局（优先级高于 .env）。"""
    for k in TOP_KEYS:
        if k in top and top[k] is not None:
            g[k] = norm_bool(top[k]) if k in BOOL_KEYS else toml_scalar(top[k])
    return g


def merge_job(g, job):
    """任务块覆盖全局，得到该任务的完整配置字典。"""
    j = dict(g)
    for k in JOB_KEYS:
        if k in job and job[k] is not None:
            j[k] = norm_bool(job[k]) if k in BOOL_KEYS else toml_scalar(job[k])
    return j


def exclude_join(global_exclude, job_exclude):
    """合并全局排除与任务排除（分号分隔），去重。
    支持 str（分号/逗号分隔）或 list（TOML 数组）。"""
    parts = []
    for src in (global_exclude, job_exclude):
        if not src:
            continue
        s = toml_scalar(src) if isinstance(src, list) else str(src)
        for x in s.replace(",", ";").split(";"):
            x = x.strip()
            if x and x not in parts:
                parts.append(x)
    return ";".join(parts)


def load_toml(path):
    if not os.path.isfile(path):
        return {}
    with open(path, "rb") as f:
        return tomllib.load(f)


def emit_global(g):
    """输出全局有效配置（key=value 行）。"""
    for k, v in g.items():
        print(f"{k}={v}")
    # docker_containers 列表用逗号拼接（兼容 DOCKER_CONTAINERS 逗号格式）
    print(f"docker_containers={g.get('docker_containers','')}")


def emit_remotes(g, data, path):
    """输出所有需要生成的 sftp 远端（供 entrypoint 写 rclone.conf）。
    每个远端一段（空行分隔）：
      REMOTE=default
      REMOTE_HOST=...
      REMOTE_USER=...
      REMOTE_PASS=...
      REMOTE_PORT=...
      REMOTE_KEY_FILE=...
    包括全局 default 远端，以及每个写了 remote_host 的任务的专属远端 job-<name>。
    """
    jobs = data.get("job", []) if isinstance(data, dict) else []

    # 全局 default 远端（若配置了 host）
    if g.get("remote_host"):
        print(f"REMOTE='default'")
        print(f"REMOTE_HOST='{g['remote_host']}'")
        print(f"REMOTE_USER='{g.get('remote_user','root')}'")
        print(f"REMOTE_PASS='{g.get('remote_pass','')}'")
        print(f"REMOTE_PORT='{g.get('remote_port','22')}'")
        print(f"REMOTE_KEY_FILE='{g.get('remote_key_file','')}'")
        print()

    # 每任务的专属远端
    for job in jobs:
        if job.get("enabled") is False:
            continue
        name = str(job.get("name", "")).strip()
        if not name or not job.get("remote_host"):
            continue
        rname = f"job-{name}"
        print(f"REMOTE='{rname}'")
        print(f"REMOTE_HOST='{job['remote_host']}'")
        print(f"REMOTE_USER='{job.get('remote_user', g.get('remote_user','root'))}'")
        print(f"REMOTE_PASS='{job.get('remote_pass', '')}'")
        print(f"REMOTE_PORT='{job.get('remote_port', g.get('remote_port','22'))}'")
        print(f"REMOTE_KEY_FILE='{job.get('remote_key_file', '')}'")
        print()


def emit_jobs(g, data, path):
    """输出每任务合并配置（空行分隔）。"""
    jobs = data.get("job", [])
    if not jobs:
        # 无 [[job]] 定义时提示（不静默）
        sys.stderr.write(f"[parse_config] 警告: {path} 未定义任何 [[job]] 任务块\n")
    for job in jobs:
        if job.get("enabled") is False:
            continue
        name = str(job.get("name", "")).strip()
        if not name:
            sys.stderr.write("[parse_config] 警告: 存在无 name 的任务块，已跳过\n")
            continue
        src = str(job.get("src", "")).strip()
        dest = str(job.get("dest", "")).strip()
        if not src or not dest:
            sys.stderr.write(f"[parse_config] 警告: 任务 [{name}] 缺少 src 或 dest，已跳过\n")
            continue
        # 远端名：任务【显式】写了 remote_host → 专属远端；写了 remote → 指定远端名；
        # 否则用默认远端 default。仅看原始 job dict，避免被全局值误判。
        if job.get("remote_host"):
            remote = f"job-{name}"
        elif job.get("remote"):
            remote = str(job["remote"])
        else:
            remote = "default"
        # 排除合并：全局默认（EXCLUDE_GLOBAL 或 config.toml 顶部）+ 任务原始 exclude
        excl = exclude_join(g.get("exclude", ""), job.get("exclude"))
        print(f"JOBNAME='{name}'")
        print(f"SRC='{src}'")
        print(f"DEST='{dest}'")
        print(f"REMOTE='{remote}'")
        print(f"EXCLUDE='{excl}'")
        print(f"ENABLED='true'")
        # 任务级开关（合并全局 + 任务覆盖）
        m = merge_job(g, job)
        print(f"REFLINK_ENABLE='{m.get('reflink','true')}'")
        # docker 适配为全局配置（仅 .env），任务不覆盖，避免冲突
        print(f"DOCKER_ADAPT_ENABLE='{g.get('docker_adapt','false')}'")
        print(f"DOCKER_MODE='{g.get('docker_mode','whitelist')}'")
        print(f"DOCKER_CONTAINERS='{g.get('docker_containers','')}'")
        # webhook（任务级）
        print(f"WEBHOOK_ENABLE='{m.get('webhook','false')}'")
        print(f"WEBHOOK_SUCCESS_ONLY='{m.get('webhook_success_only','false')}'")
        print(f"ASTROBOT_PUSH_URL='{m.get('astrobot_push_url','')}'")
        print(f"ASTROBOT_PUSH_TOKEN='{m.get('astrobot_push_token','')}'")
        print(f"ASTROBOT_PUSH_UMO='{m.get('astrobot_push_umo','')}'")
        print()


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--global"
    path = sys.argv[2] if len(sys.argv) > 2 else "/etc/oh-my-rclone/conf/config.toml"

    g = build_global_from_env()
    data = load_toml(path)
    top = data.get("global", {}) if isinstance(data, dict) else {}
    g = apply_top_override(g, top)

    if mode == "--global":
        emit_global(g)
    elif mode == "--jobs":
        emit_jobs(g, data, path)
    elif mode == "--remotes":
        emit_remotes(g, data, path)
    else:
        sys.stderr.write(f"未知模式: {mode}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
