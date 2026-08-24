# oh-my-rclone
# 基于 rclone 的单向同步备份工具
# 传输使用 sftp（SSH 密码为主，可选密钥），基于 cron 定时执行。
#
# 说明：
#  - 通过 docker.sock 访问宿主 Docker，实现对业务容器的 pause/unpause 配合（可选功能）。
#  - /tmp 用于 reflink 副本暂存（可选功能），建议在同步排除项中排除该目录。
FROM alpine:3.20

RUN set -eux; \
    apk add --no-cache \
        rclone \
        openssh-client \
        sshpass \
        curl \
        bash \
        dcron \
        ca-certificates \
        tzdata; \
    mkdir -p /etc/oh-my-rclone/conf /var/lib/oh-my-rclone /tmp/oh-my-rclone /scripts

WORKDIR /scripts

COPY scripts/ /scripts/
COPY conf/    /etc/oh-my-rclone/conf/

RUN chmod +x /scripts/*.sh

# 让 crond 与 rclone 二进制都可见
ENV PATH="/scripts:/usr/bin:/bin:/usr/sbin:/sbin"

VOLUME ["/tmp", "/data", "/etc/oh-my-rclone/conf"]

ENTRYPOINT ["/scripts/entrypoint.sh"]