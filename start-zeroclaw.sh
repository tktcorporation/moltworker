#!/usr/bin/env bash
# start-zeroclaw.sh — ZeroClaw daemon の起動スクリプト
#
# 背景: OpenClaw の start-openclaw.sh (764行) を ZeroClaw 用に書き直し。
# ZeroClaw は Rust 製の軽量 AI エージェントランタイムで、OpenClaw (Node.js) を置き換える。
# Node.js インラインスクリプトが不要になり大幅に簡素化。
#
# 5つの責務:
#   1. rclone 設定 (R2 接続)
#   2. R2 からの状態復元
#   3. OpenClaw → ZeroClaw 初回移行
#   4. R2 バックアップループ (30秒ごと)
#   5. ZeroClaw daemon の watchdog + circuit breaker
#
# 呼び出し元: Dockerfile CMD → sandbox.startProcess() (Worker の process.ts)
set -euo pipefail

# ============================================================
# 定数
# ============================================================

CONFIG_DIR="/root/.zeroclaw"
WORKSPACE_DIR="/root/workspace"
GATEWAY_PORT=18789
RCLONE_CONF="/root/.config/rclone/rclone.conf"
R2_BUCKET="${R2_BUCKET_NAME:-moltbot-data}"
# rclone に渡す共通フラグ。配列で定義して word splitting の問題を回避。
RCLONE_FLAGS=(--transfers=16 --fast-list --s3-no-check-bucket)

# Circuit breaker: 短時間クラッシュの連続を検出してループを止める
# 2026-02 に OpenClaw で発生した「config エラー → 即クラッシュ → watchdog 再起動 → 無限ループ」
# の障害を防ぐ。Worker 側は ERROR_FILE を読んでユーザーに表示する。
QUICK_CRASH_THRESHOLD=30  # この秒数未満で終了したら「クイッククラッシュ」と判定
MAX_QUICK_CRASHES=3
MAX_TOTAL_CRASHES=10
ERROR_FILE="/tmp/gateway-startup-error"
STDERR_LOG="/tmp/gateway-stderr.log"

SYNC_INTERVAL=30
# 移行済みフラグ: このファイルが存在すれば OpenClaw → ZeroClaw 移行をスキップ
MIGRATION_FLAG="${CONFIG_DIR}/.migrated"

# ============================================================
# GOGCLI SETUP
# ============================================================
# gogcli の keyring は file backend を使用する。
# export することで daemon → agent → gog コマンドの全プロセスチェーンで参照可能にする。
# これがないと ZeroClaw agent が skill 経由で gog を呼んだ際に keyring にアクセスできない。

if [ -n "${GOG_KEYRING_PASSWORD:-}" ]; then
    export GOG_KEYRING_BACKEND=file
    export GOG_KEYRING_PASSWORD
fi

# ============================================================
# 1. rclone 設定
# ============================================================
# R2 (Cloudflare S3) バケットへの接続設定。冪等（既に設定済みならスキップ）。
# credentials は Worker の env.ts → buildEnvVars() 経由で環境変数として渡される。

setup_rclone() {
    if [ -z "${R2_ACCESS_KEY_ID:-}" ] || [ -z "${R2_SECRET_ACCESS_KEY:-}" ] || [ -z "${CF_ACCOUNT_ID:-}" ]; then
        echo "[rclone] R2 credentials なし、ローカル開発モード"
        return 0
    fi

    if [ -f "$RCLONE_CONF" ]; then
        echo "[rclone] 設定済み、スキップ"
        return 0
    fi

    mkdir -p "$(dirname "$RCLONE_CONF")"
    cat > "$RCLONE_CONF" <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = https://${CF_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
    echo "[rclone] R2 設定完了 (bucket: ${R2_BUCKET})"
}

# ============================================================
# 2. R2 からの状態復元
# ============================================================
# コンテナ再作成時に R2 から最新の設定・ワークスペースを復元する。
# Dockerfile の COPY で焼き込んだ初期値は、R2 にデータがあれば上書きされる。
# 初回移行時は OpenClaw のデータも取得する（migrate_if_needed で使用）。

restore_from_r2() {
    local remote="r2:${R2_BUCKET}"

    if [ -z "${R2_ACCESS_KEY_ID:-}" ]; then
        echo "[restore] R2 credentials なし、スキップ"
        return 0
    fi

    # 初回移行用: OpenClaw データも復元
    # .migrated フラグがなければ、まだ移行が済んでいないので OpenClaw のデータを取得
    if [ ! -f "$MIGRATION_FLAG" ]; then
        if rclone lsf "${remote}/openclaw/" --max-depth 1 "${RCLONE_FLAGS[@]}" 2>/dev/null | grep -q .; then
            echo "[restore] 初回移行のため OpenClaw データを復元中..."
            rclone copy "${remote}/openclaw/" /root/.openclaw/ \
                "${RCLONE_FLAGS[@]}" \
                --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' \
                -v 2>&1 || echo "WARNING: OpenClaw config restore failed"
        fi
        # OpenClaw のワークスペースも復元（移行後は workspace/ として統合される）
        if rclone lsf "${remote}/workspace/" --max-depth 1 "${RCLONE_FLAGS[@]}" 2>/dev/null | grep -q .; then
            echo "[restore] OpenClaw ワークスペースを復元中..."
            mkdir -p "$WORKSPACE_DIR"
            rclone copy "${remote}/workspace/" "$WORKSPACE_DIR/" \
                "${RCLONE_FLAGS[@]}" \
                --exclude='.git/**' --exclude='node_modules/**' \
                -v 2>&1 || echo "WARNING: workspace restore failed"
        fi
    fi

    # ZeroClaw データの復元
    # SQLite の WAL/SHM ファイルは一貫性を壊すため除外
    if rclone lsf "${remote}/zeroclaw/" --max-depth 1 "${RCLONE_FLAGS[@]}" 2>/dev/null | grep -q .; then
        echo "[restore] R2 から ZeroClaw データを復元中..."
        mkdir -p "$CONFIG_DIR"
        rclone copy "${remote}/zeroclaw/" "$CONFIG_DIR/" \
            "${RCLONE_FLAGS[@]}" \
            --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' \
            --exclude='*-wal' --exclude='*-shm' \
            -v 2>&1 || echo "WARNING: ZeroClaw config restore failed"
    else
        echo "[restore] R2 に ZeroClaw データなし、Dockerfile の初期値を使用"
    fi

    # ワークスペースとスキルの復元（移行済みの場合のみ最新データを同期）
    if [ -f "$MIGRATION_FLAG" ]; then
        rclone copy "${remote}/workspace/" "$WORKSPACE_DIR/" \
            "${RCLONE_FLAGS[@]}" \
            --exclude='.git/**' --exclude='node_modules/**' \
            -v 2>/dev/null || true

        rclone copy "${remote}/skills/" "$WORKSPACE_DIR/skills/" \
            "${RCLONE_FLAGS[@]}" \
            -v 2>/dev/null || true
    fi

    echo "[restore] R2 復元完了"
}

# ============================================================
# 3. 初回移行 (OpenClaw → ZeroClaw)
# ============================================================
# OpenClaw のデータが存在する場合、ZeroClaw 形式に変換する。
# .migrated フラグで二重実行を防止。
#
# 移行後は常に実行される設定:
#   - API キーの onboard（OPENROUTER_API_KEY が設定されている場合）
#   - Discord チャンネルの登録（DISCORD_BOT_TOKEN が設定されている場合）
# これらはコンテナ再作成時に毎回必要（暗号化キーや状態がリセットされるため）。

migrate_if_needed() {
    if [ ! -f "$MIGRATION_FLAG" ]; then
        if [ -d /root/.openclaw ] && [ -f /root/.openclaw/openclaw.json ]; then
            echo "[migrate] OpenClaw → ZeroClaw 移行を実行"

            # zeroclaw migrate openclaw で設定・メモリを変換
            if zeroclaw migrate openclaw --source /root/.openclaw 2>&1; then
                echo "[migrate] migrate openclaw 成功"
            else
                echo "[migrate] WARNING: migrate openclaw が失敗、config.toml の初期値を使用"
            fi

            # cron ジョブの移行: import-cron-jobs.sh が存在すれば実行
            # このスクリプトは scripts/convert-cron-jobs.ts で生成され、
            # Dockerfile 経由で /root/.zeroclaw/ にコピーされている
            if [ -f "${CONFIG_DIR}/import-cron-jobs.sh" ]; then
                echo "[migrate] cron ジョブをインポート中..."
                bash "${CONFIG_DIR}/import-cron-jobs.sh" 2>&1 || echo "WARNING: cron import failed"
            fi
        else
            echo "[migrate] OpenClaw データなし、クリーンスタート"
        fi

        touch "$MIGRATION_FLAG"
        echo "[migrate] 移行フラグを設定"
    fi

    # --- 毎回実行する設定（コンテナ再作成時に状態がリセットされるため） ---

    # API キーの登録
    # zeroclaw onboard --force で既存の config を上書きせずに API キーのみ設定する。
    # 暗号化キー (.secret_key) はコンテナごとに異なるため、毎回再登録が必要。
    if [ -n "${OPENROUTER_API_KEY:-}" ]; then
        echo "[setup] API キーを登録中 (provider: openrouter)"
        zeroclaw onboard --force \
            --api-key "$OPENROUTER_API_KEY" \
            --provider openrouter 2>&1 || echo "WARNING: onboard failed"
    fi

    # Discord チャンネルの登録
    # daemon モードで channels を統合起動するため、事前に channel add が必要。
    # 既に登録済みでもエラーにはならない（冪等）。
    if [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
        echo "[setup] Discord チャンネルを登録中"
        zeroclaw channel add discord \
            "{\"bot_token\":\"${DISCORD_BOT_TOKEN}\",\"name\":\"discord\"}" 2>&1 || echo "WARNING: Discord channel add failed"
    fi
}

# ============================================================
# 4. R2 バックアップループ
# ============================================================
# 30秒ごとに変更を検知し R2 に同期する。
# SQLite DB は `sqlite3 .backup` で一貫性のあるスナップショットを作成してから同期。
# WAL モードの DB を直接 rclone すると破損する可能性があるため。

sync_to_r2() {
    local remote="r2:${R2_BUCKET}"
    local marker="/tmp/.last-sync"
    local logfile="/tmp/r2-sync.log"

    if [ -z "${R2_ACCESS_KEY_ID:-}" ]; then
        echo "[sync] R2 credentials なし、バックアップ無効"
        return 0
    fi

    echo "[sync] R2 バックアップループ開始 (interval: ${SYNC_INTERVAL}s)"

    while true; do
        sleep "$SYNC_INTERVAL"

        # 変更検知: marker ファイルより新しいファイルがあるか確認
        if [ -f "$marker" ]; then
            local changed
            changed=$(find "$CONFIG_DIR/" "$WORKSPACE_DIR/" \
                -newer "$marker" -type f \
                -not -name '*.lock' -not -name '*.log' \
                -not -name '*-wal' -not -name '*-shm' \
                -not -path '*/node_modules/*' -not -path '*/.git/*' \
                2>/dev/null | head -1)
            if [ -z "$changed" ]; then
                continue  # 変更なし
            fi
        fi

        echo "[sync] 変更を検知、R2 に同期中... ($(date))" >> "$logfile"

        # SQLite DB の安全なバックアップ
        # zeroclaw.db は WAL モードで使用されるため、直接コピーすると
        # 不整合が起きる。sqlite3 .backup でアトミックなスナップショットを作成。
        local db="${CONFIG_DIR}/zeroclaw.db"
        local db_backup="${CONFIG_DIR}/zeroclaw.db.backup"
        if [ -f "$db" ] && command -v sqlite3 >/dev/null 2>&1; then
            sqlite3 "$db" ".backup '${db_backup}'" 2>/dev/null || true
        fi

        # ZeroClaw 設定の同期
        # SQLite 本体と WAL/SHM は除外し、.backup で作成したスナップショットを使用
        rclone sync "$CONFIG_DIR/" "${remote}/zeroclaw/" \
            "${RCLONE_FLAGS[@]}" \
            --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' \
            --exclude='*-wal' --exclude='*-shm' \
            --exclude='zeroclaw.db' \
            2>> "$logfile" || true

        # SQLite バックアップを本体のファイル名で R2 にアップロード
        if [ -f "$db_backup" ]; then
            rclone copyto "$db_backup" "${remote}/zeroclaw/zeroclaw.db" \
                --s3-no-check-bucket 2>> "$logfile" || true
            rm -f "$db_backup"
        fi

        # ワークスペースの同期（skills は別パスで管理）
        if [ -d "$WORKSPACE_DIR" ]; then
            rclone sync "$WORKSPACE_DIR/" "${remote}/workspace/" \
                "${RCLONE_FLAGS[@]}" \
                --exclude='skills/**' --exclude='.git/**' --exclude='node_modules/**' \
                2>> "$logfile" || true
        fi

        # スキルの同期
        if [ -d "$WORKSPACE_DIR/skills" ]; then
            rclone sync "$WORKSPACE_DIR/skills/" "${remote}/skills/" \
                "${RCLONE_FLAGS[@]}" \
                2>> "$logfile" || true
        fi

        touch "$marker"
        echo "[sync] 同期完了 ($(date))" >> "$logfile"
    done
}

# ============================================================
# 5. Watchdog + Circuit Breaker
# ============================================================
# ZeroClaw daemon プロセスの監視と自動再起動。
#
# 2つの Circuit breaker モード:
#   Quick crash: QUICK_CRASH_THRESHOLD 秒以内に MAX_QUICK_CRASHES 回
#     → config エラー等の即座に直せない問題と判断して停止
#   Total crash: 累計 MAX_TOTAL_CRASHES 回
#     → 長時間稼働後のクラッシュでも無限ループを防ぐ
#
# Worker 側は ERROR_FILE を読んでユーザーに表示する (gateway/process.ts)。

watchdog() {
    local quick_crashes=0
    local total_crashes=0
    local first_crash_time=0
    local gateway_pid=""

    # SIGTERM/SIGINT → daemon を停止してクリーンに終了
    # Container shutdown 時に無限再起動ループに入らないようにするため
    trap 'echo "[watchdog] シャットダウンシグナル受信"; [ -n "$gateway_pid" ] && kill "$gateway_pid" 2>/dev/null; wait "$gateway_pid" 2>/dev/null; exit 0' TERM INT

    rm -f "$ERROR_FILE" 2>/dev/null || true
    rm -f "$STDERR_LOG" 2>/dev/null || true

    echo "[watchdog] ZeroClaw daemon を起動 (port=${GATEWAY_PORT})"
    echo "[watchdog] Dev mode: ${ZEROCLAW_DEV_MODE:-${OPENCLAW_DEV_MODE:-false}}"

    while true; do
        local start_time
        start_time=$(date +%s)

        # zeroclaw コマンドは Dockerfile のラッパー経由で実行される
        # (GLIBC 2.39 が必要だが sandbox は 2.35 のため、カスタム linker を使用)
        zeroclaw daemon --port "$GATEWAY_PORT" --host 0.0.0.0 2>> "$STDERR_LOG" &
        gateway_pid=$!

        wait "$gateway_pid" || true
        local exit_code=$?
        local end_time
        end_time=$(date +%s)
        local uptime=$((end_time - start_time))

        # trap による正常終了の場合はここに到達しない（trap 内で exit するため）

        total_crashes=$((total_crashes + 1))
        echo "[watchdog] Daemon 終了 (code=${exit_code}, uptime=${uptime}s, total crashes=${total_crashes})"

        # --- Total circuit breaker ---
        if [ "$total_crashes" -ge "$MAX_TOTAL_CRASHES" ]; then
            local last_stderr
            last_stderr=$(tail -50 "$STDERR_LOG" 2>/dev/null || echo "(no stderr captured)")
            local escaped_stderr
            escaped_stderr=$(echo "$last_stderr" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '"(stderr unavailable)"')

            cat > "$ERROR_FILE" <<EOFERR
{"error":"total_circuit_breaker","message":"Daemon crashed ${total_crashes} times total (limit: ${MAX_TOTAL_CRASHES}). Stopping watchdog.","exitCode":${exit_code},"totalCrashes":${total_crashes},"stderr":${escaped_stderr},"timestamp":"$(date -Iseconds)"}
EOFERR
            echo "[watchdog] CIRCUIT BREAKER: 累計クラッシュ上限 (${total_crashes}/${MAX_TOTAL_CRASHES})"
            break
        fi

        # --- Quick circuit breaker ---
        if [ "$uptime" -ge "$QUICK_CRASH_THRESHOLD" ]; then
            # 長時間稼働後のクラッシュ → OOM 等の一時的な問題。quick カウンターをリセット
            quick_crashes=0
            first_crash_time=0
        else
            local now
            now=$(date +%s)
            if [ "$quick_crashes" -eq 0 ]; then
                first_crash_time=$now
            fi

            # ウィンドウ外の古いクラッシュはリセット
            local elapsed=$((now - first_crash_time))
            if [ "$elapsed" -ge "$QUICK_CRASH_THRESHOLD" ]; then
                quick_crashes=1
                first_crash_time=$now
            else
                quick_crashes=$((quick_crashes + 1))
            fi

            echo "[watchdog] クイッククラッシュ検出 (${quick_crashes}/${MAX_QUICK_CRASHES}, uptime=${uptime}s, window=${elapsed:-0}s)"

            if [ "$quick_crashes" -ge "$MAX_QUICK_CRASHES" ]; then
                local last_stderr
                last_stderr=$(tail -50 "$STDERR_LOG" 2>/dev/null || echo "(no stderr captured)")
                local escaped_stderr
                escaped_stderr=$(echo "$last_stderr" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '"(stderr unavailable)"')

                cat > "$ERROR_FILE" <<EOFERR
{"error":"circuit_breaker_open","message":"Daemon crashed ${quick_crashes} times within ${QUICK_CRASH_THRESHOLD}s. Likely a configuration error.","exitCode":${exit_code},"crashCount":${quick_crashes},"stderr":${escaped_stderr},"timestamp":"$(date -Iseconds)"}
EOFERR
                echo "[watchdog] CIRCUIT BREAKER: クイッククラッシュ上限 (${quick_crashes}/${MAX_QUICK_CRASHES})"
                echo "[watchdog] config エラーの可能性。stderr ログ: ${STDERR_LOG}"
                break
            fi
        fi

        echo "[watchdog] 5秒後に再起動..."
        sleep 5
    done
}

# ============================================================
# メインエントリポイント
# ============================================================

main() {
    echo "========================================"
    echo "[start-zeroclaw] 起動開始 ($(date -Iseconds))"
    echo "========================================"

    mkdir -p "$CONFIG_DIR" "$WORKSPACE_DIR"

    setup_rclone
    restore_from_r2
    migrate_if_needed

    # バックアップループをバックグラウンドで開始
    sync_to_r2 &
    local sync_pid=$!
    echo "[main] R2 バックアップループ開始 (PID: ${sync_pid})"

    # Watchdog（フォアグラウンド、ここでブロック）
    watchdog

    # watchdog が circuit breaker で終了した場合、sync も停止
    kill "$sync_pid" 2>/dev/null || true
}

main "$@"
