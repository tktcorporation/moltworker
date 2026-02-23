FROM docker.io/cloudflare/sandbox:0.7.0

# Install Node.js 22 (required by OpenClaw) and rclone (for R2 persistence)
# The base image has Node 20, we need to replace it with Node 22
# Using direct binary download for reliability
ENV NODE_VERSION=22.13.1
RUN ARCH="$(dpkg --print-architecture)" \
    && case "${ARCH}" in \
         amd64) NODE_ARCH="x64" ;; \
         arm64) NODE_ARCH="arm64" ;; \
         *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;; \
       esac \
    && apt-get update && apt-get install -y xz-utils ca-certificates rclone \
    && curl -fsSLk https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz -o /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && node --version \
    && npm --version

# Install pnpm globally
RUN npm install -g pnpm

# Install OpenClaw (formerly clawdbot/moltbot)
# Pin to specific version for reproducible builds
RUN npm install -g openclaw@2026.2.3 \
    && openclaw --version

# Install gogcli (Google Suite CLI for Tasks, Calendar, etc.)
# start-openclaw.sh でも fallback インストールするが、ビルド時に入れておくことで
# 起動時の GitHub ダウンロード失敗リスクを排除し、起動を高速化する
# リリースアセットは gogcli_<ver>_linux_<arch>.tar.gz 形式（tarball、バイナリ名は gog）
# /latest/download/ はバージョン番号入りファイル名に対応しないため、
# GitHub API でタグを取得してダウンロード URL を組み立てる
RUN ARCH="$(dpkg --print-architecture)" \
    && GOG_VERSION="$(curl -fsSL https://api.github.com/repos/steipete/gogcli/releases/latest | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')" \
    && curl -fsSL "https://github.com/steipete/gogcli/releases/download/v${GOG_VERSION}/gogcli_${GOG_VERSION}_linux_${ARCH}.tar.gz" \
       -o /tmp/gogcli.tar.gz \
    && tar -xzf /tmp/gogcli.tar.gz -C /usr/local/bin/ gog \
    && chmod +x /usr/local/bin/gog \
    && rm /tmp/gogcli.tar.gz \
    && gog --version

# Create OpenClaw directories
# Legacy .clawdbot paths are kept for R2 backup migration
RUN mkdir -p /root/.openclaw \
    && mkdir -p /root/clawd \
    && mkdir -p /root/clawd/skills

# Copy startup script
# Build cache bust: 2026-02-23-v31-gogcli-fix
COPY start-openclaw.sh /usr/local/bin/start-openclaw.sh
RUN chmod +x /usr/local/bin/start-openclaw.sh

# Copy git-managed base state (openclaw config, cron jobs, skills, workspace files)
# R2 ↔ Git 双方向同期の一部: GitHub Actions が R2 から取得したデータを r2-state/ に配置し、
# ここでコンテナイメージに焼き込む。start-openclaw.sh の reconcile セクションが
# この base state と R2 から復元された runtime state をマージする。
# 構造: r2-state/openclaw/ (設定), r2-state/skills/, r2-state/workspace/
COPY r2-state/ /usr/local/etc/openclaw-base/

# Copy hand-crafted skills (初期スキル、Git で直接管理)
# runtime で追加されたスキルは r2-state/skills/ 経由で reconcile される（後勝ち）
COPY skills/ /root/clawd/skills/

# Set working directory
WORKDIR /root/clawd

# Expose the gateway port
EXPOSE 18789
