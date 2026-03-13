# --- Stage 1: GLIBC donor ---
# WHY: ZeroClaw v0.1.7 は GLIBC 2.39 を要求するが、cloudflare/sandbox:0.7.0 は
# Ubuntu 22.04 (GLIBC 2.35) ベース。Ubuntu 24.04 から GLIBC 2.39 のライブラリを
# コピーして /opt/glibc/ に配置し、ラッパースクリプトで動的リンカを指定する。
FROM ubuntu:24.04 AS glibc-donor

# --- Stage 2: Main image ---
FROM docker.io/cloudflare/sandbox:0.7.0

# --- GLIBC 2.39 (from Ubuntu 24.04) ---
# ZeroClaw のダイナミックリンクに必要な共有ライブラリをコピー。
# /opt/glibc/ に隔離し、既存のシステムライブラリを壊さない。
# NOTE: libpthread.so.0 と libdl.so.2 は GLIBC 2.34+ で libc.so.6 に統合済みのため不要。
COPY --from=glibc-donor /lib/x86_64-linux-gnu/libc.so.6 /opt/glibc/
COPY --from=glibc-donor /lib/x86_64-linux-gnu/libm.so.6 /opt/glibc/
COPY --from=glibc-donor /lib/x86_64-linux-gnu/libgcc_s.so.1 /opt/glibc/
COPY --from=glibc-donor /lib64/ld-linux-x86-64.so.2 /opt/glibc/ld-linux-x86-64.so.2

# --- rclone: R2 同期用 ---
# rclone 公式イメージからバイナリをコピー。apt 版より新しく、レイヤーキャッシュも効く。
COPY --from=rclone/rclone:latest /usr/local/bin/rclone /usr/local/bin/rclone

# --- sqlite3 + ca-certificates ---
# sqlite3: R2 バックアップ時の DB スナップショット用 (start-zeroclaw.sh の sync_to_r2)
# ca-certificates: HTTPS 接続用
# xz-utils: Node.js の .tar.xz 展開に必要
RUN apt-get update \
    && apt-get install -y --no-install-recommends sqlite3 ca-certificates xz-utils \
    && rm -rf /var/lib/apt/lists/*

# --- Node.js (Phase A で維持) ---
# gogcli と既存スキル (web-search, cloudflare-browser) が Node.js を使用。
# Phase B で不要になれば削除可能。
ENV NODE_VERSION=22.13.1
RUN ARCH="$(dpkg --print-architecture)" \
    && case "${ARCH}" in \
         amd64) NODE_ARCH="x64" ;; \
         arm64) NODE_ARCH="arm64" ;; \
         *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;; \
       esac \
    && curl -fsSLk https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz -o /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && node --version
RUN npm install -g pnpm

# --- gogcli (Google Suite CLI for Tasks, Calendar, etc.) ---
# start-openclaw.sh 由来。Phase B で不要になれば削除可能。
# GitHub API でタグを取得してダウンロード URL を組み立てる
# (/latest/download/ はバージョン番号入りファイル名に対応しないため)。
RUN ARCH="$(dpkg --print-architecture)" \
    && GOG_VERSION="$(curl -fsSL https://api.github.com/repos/steipete/gogcli/releases/latest | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')" \
    && curl -fsSL "https://github.com/steipete/gogcli/releases/download/v${GOG_VERSION}/gogcli_${GOG_VERSION}_linux_${ARCH}.tar.gz" \
       -o /tmp/gogcli.tar.gz \
    && tar -xzf /tmp/gogcli.tar.gz -C /usr/local/bin/ gog \
    && chmod +x /usr/local/bin/gog \
    && rm /tmp/gogcli.tar.gz \
    && gog --version

# --- ZeroClaw バイナリ ---
# Rust 製の軽量 AI エージェントランタイム。OpenClaw (~420MB npm) の代替。
# tar.gz アーカイブから展開。バイナリは /opt/zeroclaw/bin/ に配置し、
# /usr/local/bin/zeroclaw はラッパースクリプトにする（GLIBC 2.39 対応）。
ARG ZEROCLAW_VERSION=0.1.7
RUN mkdir -p /opt/zeroclaw/bin \
    && curl -fsSL "https://github.com/zeroclaw-labs/zeroclaw/releases/download/v${ZEROCLAW_VERSION}/zeroclaw-x86_64-unknown-linux-gnu.tar.gz" \
       -o /tmp/zeroclaw.tar.gz \
    && tar -xzf /tmp/zeroclaw.tar.gz -C /opt/zeroclaw/bin/ \
    && chmod +x /opt/zeroclaw/bin/zeroclaw \
    && rm /tmp/zeroclaw.tar.gz

# --- zeroclaw ラッパー ---
# ZeroClaw は GLIBC 2.39 を必要とするが、sandbox は 2.35。
# /opt/glibc/ のカスタムリンカとライブラリを使って起動する。
# ラッパーを /usr/local/bin/zeroclaw として配置することで、
# import-cron-jobs.sh や他のスクリプトが `zeroclaw` で直接呼べる。
RUN printf '#!/bin/sh\nexec /opt/glibc/ld-linux-x86-64.so.2 --library-path /opt/glibc /opt/zeroclaw/bin/zeroclaw "$@"\n' \
    > /usr/local/bin/zeroclaw \
    && chmod +x /usr/local/bin/zeroclaw \
    && zeroclaw --version

# --- ディレクトリ構造 ---
# /root/.zeroclaw: ZeroClaw 設定ディレクトリ (config.toml 等)
# /root/workspace/skills: スキルファイル配置先
RUN mkdir -p /root/.zeroclaw /root/workspace/skills

# --- 初期設定（Git 管理のベース設定）---
# R2 から復元されなかった場合のフォールバック。
# config.toml (ZeroClaw 設定) + import-cron-jobs.sh (cron ジョブインポート) が含まれる。
COPY r2-state/zeroclaw/ /root/.zeroclaw/

# --- スキル ---
# Git 管理スキル（moltworker/skills/）: 初期スキルセット。
# r2-state/skills/: R2 から同期されたランタイムスキル（上書きされる可能性あり）。
# 後勝ちで r2-state/skills/ の内容が優先される。
COPY skills/ /root/workspace/skills/
COPY r2-state/skills/ /root/workspace/skills/

# --- 起動スクリプト ---
COPY start-zeroclaw.sh /usr/local/bin/start-zeroclaw.sh
RUN chmod +x /usr/local/bin/start-zeroclaw.sh

WORKDIR /root/workspace
EXPOSE 18789
