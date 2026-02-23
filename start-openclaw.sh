#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox
# This script:
# 1. Restores config/workspace/skills from R2 via rclone (if configured)
# 2. Runs openclaw onboard --non-interactive to configure from env vars
# 3. Patches config for features onboard doesn't cover (channels, gateway auth)
# 4. Starts a background sync loop (rclone, watches for file changes)
# 5. Starts the gateway

set -e

if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
WORKSPACE_DIR="/root/clawd"
SKILLS_DIR="/root/clawd/skills"
RCLONE_CONF="/root/.config/rclone/rclone.conf"
LAST_SYNC_FILE="/tmp/.last-sync"

echo "Config directory: $CONFIG_DIR"

mkdir -p "$CONFIG_DIR"

# ============================================================
# GOGCLI SETUP
# ============================================================
# gogcli の keyring は file backend を使用する。
# export することで gateway → agent → gog コマンドの全プロセスチェーンで参照可能にする。
# これがないと OpenClaw agent が skill 経由で gog を呼んだ際に keyring にアクセスできない。

GOG_CONFIG_DIR="/root/.config/gogcli"

if [ -n "$GOG_KEYRING_PASSWORD" ]; then
    export GOG_KEYRING_BACKEND=file
    export GOG_KEYRING_PASSWORD
fi

install_gogcli() {
    if command -v gog &>/dev/null; then
        echo "gogcli already installed: $(gog --version 2>/dev/null || echo 'unknown')"
        return
    fi

    echo "Installing gogcli..."
    local ARCH
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
    esac

    local OS
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')

    local DOWNLOAD_URL="https://github.com/steipete/gogcli/releases/latest/download/gog_${OS}_${ARCH}"
    echo "Downloading gogcli from: $DOWNLOAD_URL"

    if curl -fsSL "$DOWNLOAD_URL" -o /usr/local/bin/gog; then
        chmod +x /usr/local/bin/gog
        echo "gogcli installed: $(gog --version 2>/dev/null || echo 'installed')"
    else
        echo "WARNING: Failed to download gogcli, Google services will not be available"
    fi
}

install_gogcli
mkdir -p "$GOG_CONFIG_DIR"

# ============================================================
# RCLONE SETUP
# ============================================================

r2_configured() {
    [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$CF_ACCOUNT_ID" ]
}

R2_BUCKET="${R2_BUCKET_NAME:-moltbot-data}"

setup_rclone() {
    mkdir -p "$(dirname "$RCLONE_CONF")"
    cat > "$RCLONE_CONF" << EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = https://${CF_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
    touch /tmp/.rclone-configured
    echo "Rclone configured for bucket: $R2_BUCKET"
}

RCLONE_FLAGS="--transfers=16 --fast-list --s3-no-check-bucket"

# ============================================================
# RESTORE FROM R2
# ============================================================

if r2_configured; then
    setup_rclone

    echo "Checking R2 for existing backup..."
    # Check if R2 has an openclaw config backup
    if rclone ls "r2:${R2_BUCKET}/openclaw/openclaw.json" $RCLONE_FLAGS 2>/dev/null | grep -q openclaw.json; then
        echo "Restoring config from R2..."
        rclone copy "r2:${R2_BUCKET}/openclaw/" "$CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: config restore failed with exit code $?"
        echo "Config restored"
    elif rclone ls "r2:${R2_BUCKET}/clawdbot/clawdbot.json" $RCLONE_FLAGS 2>/dev/null | grep -q clawdbot.json; then
        echo "Restoring from legacy R2 backup..."
        rclone copy "r2:${R2_BUCKET}/clawdbot/" "$CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: legacy config restore failed with exit code $?"
        if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
            mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        fi
        echo "Legacy config restored and migrated"
    else
        echo "No backup found in R2, starting fresh"
    fi

    # Restore workspace
    REMOTE_WS_COUNT=$(rclone ls "r2:${R2_BUCKET}/workspace/" $RCLONE_FLAGS 2>/dev/null | wc -l)
    if [ "$REMOTE_WS_COUNT" -gt 0 ]; then
        echo "Restoring workspace from R2 ($REMOTE_WS_COUNT files)..."
        mkdir -p "$WORKSPACE_DIR"
        rclone copy "r2:${R2_BUCKET}/workspace/" "$WORKSPACE_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: workspace restore failed with exit code $?"
        echo "Workspace restored"
    fi

    # Restore skills
    REMOTE_SK_COUNT=$(rclone ls "r2:${R2_BUCKET}/skills/" $RCLONE_FLAGS 2>/dev/null | wc -l)
    if [ "$REMOTE_SK_COUNT" -gt 0 ]; then
        echo "Restoring skills from R2 ($REMOTE_SK_COUNT files)..."
        mkdir -p "$SKILLS_DIR"
        rclone copy "r2:${R2_BUCKET}/skills/" "$SKILLS_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: skills restore failed with exit code $?"
        echo "Skills restored"
    fi

    # Restore gogcli config (OAuth client + keyring)
    # GOG_AUTH_TOKENS が設定されている場合は R2 keyring の restore をスキップする。
    # 理由: R2 に保存された keyring データは Mac keychain で暗号化されている可能性があり、
    # container の file backend では復号できない。GOG_AUTH_TOKENS import で正しいデータを
    # 書き込むため、古いデータの restore は不要（かつ有害）。
    # ただし config.json（OAuth client 設定）は常に restore する。
    if [ -n "$GOG_AUTH_TOKENS" ]; then
        echo "GOG_AUTH_TOKENS is set, skipping R2 keyring restore (will import fresh tokens later)"
        # OAuth client credentials のみ restore（keyring は除外）
        if rclone ls "r2:${R2_BUCKET}/gogcli/credentials.json" $RCLONE_FLAGS 2>/dev/null | grep -q credentials.json; then
            mkdir -p "$GOG_CONFIG_DIR"
            rclone copy "r2:${R2_BUCKET}/gogcli/credentials.json" "$GOG_CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: gogcli credentials.json restore failed"
        fi
    else
        REMOTE_GOG_COUNT=$(rclone ls "r2:${R2_BUCKET}/gogcli/" $RCLONE_FLAGS 2>/dev/null | wc -l)
        if [ "$REMOTE_GOG_COUNT" -gt 0 ]; then
            echo "Restoring gogcli config from R2 ($REMOTE_GOG_COUNT files)..."
            mkdir -p "$GOG_CONFIG_DIR/keyring"
            rclone copy "r2:${R2_BUCKET}/gogcli/" "$GOG_CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: gogcli config restore failed with exit code $?"
            chmod -R 700 "$GOG_CONFIG_DIR"
            echo "gogcli config restored. Files:"
            ls -laR "$GOG_CONFIG_DIR/" 2>&1
            if [ -n "$GOG_KEYRING_PASSWORD" ] && command -v gog &>/dev/null; then
                echo "Verifying gogcli auth..."
                gog auth list 2>&1 || echo "WARNING: gogcli auth verification failed (keyring may be from a different backend)"
            fi
        else
            echo "No gogcli config found in R2"
        fi
    fi
else
    echo "R2 not configured, starting fresh"
fi

# ============================================================
# ONBOARD (only if no config exists yet)
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, running openclaw onboard..."

    AUTH_ARGS=""
    if [ -n "$CLOUDFLARE_AI_GATEWAY_API_KEY" ] && [ -n "$CF_AI_GATEWAY_ACCOUNT_ID" ] && [ -n "$CF_AI_GATEWAY_GATEWAY_ID" ]; then
        AUTH_ARGS="--auth-choice cloudflare-ai-gateway-api-key \
            --cloudflare-ai-gateway-account-id $CF_AI_GATEWAY_ACCOUNT_ID \
            --cloudflare-ai-gateway-gateway-id $CF_AI_GATEWAY_GATEWAY_ID \
            --cloudflare-ai-gateway-api-key $CLOUDFLARE_AI_GATEWAY_API_KEY"
    elif [ -n "$ANTHROPIC_API_KEY" ]; then
        AUTH_ARGS="--auth-choice apiKey --anthropic-api-key $ANTHROPIC_API_KEY"
    elif [ -n "$OPENAI_API_KEY" ]; then
        AUTH_ARGS="--auth-choice openai-api-key --openai-api-key $OPENAI_API_KEY"
    elif [ -n "$OPENROUTER_API_KEY" ]; then
        # OpenRouter is OpenAI-compatible; use it as an OpenAI provider
        AUTH_ARGS="--auth-choice openai-api-key --openai-api-key $OPENROUTER_API_KEY"
    fi

    openclaw onboard --non-interactive --accept-risk \
        --mode local \
        $AUTH_ARGS \
        --gateway-port 18789 \
        --gateway-bind lan \
        --skip-channels \
        --skip-skills \
        --skip-health

    echo "Onboard completed"
else
    echo "Using existing config"
fi

# ============================================================
# RECONCILE GIT-MANAGED FILES
# ============================================================
# R2 ↔ Git 双方向同期の「Git → コンテナ」方向の処理。
#
# 背景: cronジョブの wakeMode が "next-heartbeat" のままだと Sandbox 環境では
# 実行されない問題があった。git で wakeMode を "now" に修正しても、R2 から復元された
# 古い設定で上書きされてしまう。このreconcileにより git の設定が確実に反映される。
#
# マージ戦略:
# - 同名ジョブ: git の設定 (schedule, wakeMode, payload) が優先、R2 の state (lastRun, nextRun) は保持
# - git のみ: 新規ジョブとして追加
# - R2 のみ: ユーザーがチャットで作成したジョブなので、そのまま保持

GIT_BASE="/usr/local/etc/openclaw-base"
CRON_DIR="$CONFIG_DIR/cron"

if [ -d "$GIT_BASE" ]; then
    # Reconcile cron jobs
    # r2-state/ のディレクトリ構造が openclaw/cron/jobs.json になったのでパスを合わせる
    GIT_JOBS_FILE="$GIT_BASE/openclaw/cron/jobs.json"
    # 旧構造 (r2-state/jobs.json) にもフォールバック
    if [ ! -f "$GIT_JOBS_FILE" ] && [ -f "$GIT_BASE/jobs.json" ]; then
        GIT_JOBS_FILE="$GIT_BASE/jobs.json"
    fi
    if [ -f "$GIT_JOBS_FILE" ]; then
        echo "Reconciling git-managed cron jobs from $GIT_JOBS_FILE..."
        mkdir -p "$CRON_DIR"
        export GIT_JOBS_FILE
        node << 'EOFRECONCILE'
const fs = require('fs');
const crypto = require('crypto');

// GIT_JOBS_FILE 環境変数でパスを受け取る（シェル側でフォールバック済み）
const GIT_JOBS_PATH = process.env.GIT_JOBS_FILE || '/usr/local/etc/openclaw-base/openclaw/cron/jobs.json';
const RUNTIME_JOBS_PATH = '/root/.openclaw/cron/jobs.json';

const gitJobs = JSON.parse(fs.readFileSync(GIT_JOBS_PATH, 'utf8'));
let runtimeJobs = [];
if (fs.existsSync(RUNTIME_JOBS_PATH)) {
    try {
        runtimeJobs = JSON.parse(fs.readFileSync(RUNTIME_JOBS_PATH, 'utf8'));
        // Handle both array and {jobs: [...]} formats
        if (runtimeJobs.jobs) runtimeJobs = runtimeJobs.jobs;
    } catch (e) {
        console.log('Could not parse existing jobs.json, starting fresh');
    }
}

const gitByName = new Map(gitJobs.map(j => [j.name, j]));
const merged = [];
const seen = new Set();

for (const rj of runtimeJobs) {
    const gj = gitByName.get(rj.name);
    if (gj) {
        merged.push({
            ...rj,
            agentId: gj.agentId || rj.agentId,
            enabled: gj.enabled !== undefined ? gj.enabled : rj.enabled,
            schedule: gj.schedule,
            sessionTarget: gj.sessionTarget,
            wakeMode: gj.wakeMode,
            payload: gj.payload,
            delivery: gj.delivery || rj.delivery,
            updatedAtMs: Date.now(),
        });
        seen.add(rj.name);
    } else {
        merged.push(rj);
    }
}

for (const [name, gj] of gitByName) {
    if (!seen.has(name)) {
        const now = Date.now();
        merged.push({
            id: crypto.randomUUID(),
            agentId: gj.agentId || 'main',
            name: gj.name,
            enabled: gj.enabled !== undefined ? gj.enabled : true,
            createdAtMs: now,
            updatedAtMs: now,
            schedule: gj.schedule,
            sessionTarget: gj.sessionTarget,
            wakeMode: gj.wakeMode,
            payload: gj.payload,
            delivery: gj.delivery,
            state: {},
        });
    }
}

fs.mkdirSync('/root/.openclaw/cron', { recursive: true });
fs.writeFileSync(RUNTIME_JOBS_PATH, JSON.stringify(merged, null, 2));
console.log('Cron reconcile: ' + merged.length + ' jobs (' + seen.size + ' updated, ' + (merged.length - runtimeJobs.length) + ' new)');
EOFRECONCILE
    fi

    # Apply git-managed workspace files
    # 新構造: r2-state/workspace/ → /usr/local/etc/openclaw-base/workspace/
    GIT_WS_DIR="$GIT_BASE/workspace"
    if [ -d "$GIT_WS_DIR" ] && [ "$(ls -A "$GIT_WS_DIR" 2>/dev/null)" ]; then
        echo "Applying git-managed workspace files..."
        mkdir -p "$WORKSPACE_DIR"
        cp -rv "$GIT_WS_DIR/"* "$WORKSPACE_DIR/" 2>/dev/null || true
    fi

    # Apply git-managed skills
    # r2-state/skills/ が存在すれば、コンテナの skills ディレクトリにコピー
    GIT_SKILLS_DIR="$GIT_BASE/skills"
    if [ -d "$GIT_SKILLS_DIR" ] && [ "$(ls -A "$GIT_SKILLS_DIR" 2>/dev/null)" ]; then
        echo "Applying git-managed skills..."
        mkdir -p "$SKILLS_DIR"
        cp -rv "$GIT_SKILLS_DIR/"* "$SKILLS_DIR/" 2>/dev/null || true
    fi
fi

# ============================================================
# PATCH CONFIG (channels, gateway auth, trusted proxies)
# ============================================================
# openclaw onboard handles provider/model config, but we need to patch in:
# - Channel config (Telegram, Discord, Slack)
# - Gateway token auth
# - Trusted proxies for sandbox networking
# - Base URL override for legacy AI Gateway path
node << 'EOFPATCH'
const fs = require('fs');

const configPath = '/root/.openclaw/openclaw.json';
console.log('Patching config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

if (process.env.OPENCLAW_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN;
}

if (process.env.OPENCLAW_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Legacy AI Gateway base URL override:
// ANTHROPIC_BASE_URL is picked up natively by the Anthropic SDK,
// so we don't need to patch the provider config. Writing a provider
// entry without a models array breaks OpenClaw's config validation.

// AI Gateway model override (CF_AI_GATEWAY_MODEL=provider/model-id)
// Adds a provider entry for any AI Gateway provider and sets it as default model.
// Examples:
//   workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast
//   openai/gpt-4o
//   anthropic/claude-sonnet-4-5
if (process.env.CF_AI_GATEWAY_MODEL) {
    const raw = process.env.CF_AI_GATEWAY_MODEL;
    const slashIdx = raw.indexOf('/');
    const gwProvider = raw.substring(0, slashIdx);
    const modelId = raw.substring(slashIdx + 1);

    const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID;
    const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
    const apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY
        || (gwProvider === 'openrouter' ? process.env.OPENROUTER_API_KEY : undefined);

    let baseUrl;
    if (gwProvider === 'openrouter') {
        // OpenRouter is not a native CF AI Gateway provider; use its API directly
        baseUrl = 'https://openrouter.ai/api/v1';
    } else if (accountId && gatewayId) {
        baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + accountId + '/' + gatewayId + '/' + gwProvider;
        if (gwProvider === 'workers-ai') baseUrl += '/v1';
    } else if (gwProvider === 'workers-ai' && process.env.CF_ACCOUNT_ID) {
        baseUrl = 'https://api.cloudflare.com/client/v4/accounts/' + process.env.CF_ACCOUNT_ID + '/ai/v1';
    }

    if (baseUrl && apiKey) {
        const api = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
        const providerName = 'cf-ai-gw-' + gwProvider;

        config.models = config.models || {};
        config.models.providers = config.models.providers || {};
        config.models.providers[providerName] = {
            baseUrl: baseUrl,
            apiKey: apiKey,
            api: api,
            models: [{ id: modelId, name: modelId, contextWindow: 131072, maxTokens: 8192 }],
        };
        config.agents = config.agents || {};
        config.agents.defaults = config.agents.defaults || {};
        config.agents.defaults.model = { primary: providerName + '/' + modelId };
        console.log('AI Gateway model override: provider=' + providerName + ' model=' + modelId + ' via ' + baseUrl);
    } else {
        console.warn('CF_AI_GATEWAY_MODEL set but missing required config (account ID, gateway ID, or API key)');
    }
}

// Telegram configuration
// Overwrite entire channel object to drop stale keys from old R2 backups
// that would fail OpenClaw's strict config validation (see #47)
if (process.env.TELEGRAM_BOT_TOKEN) {
    const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram = {
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        enabled: true,
        dmPolicy: dmPolicy,
    };
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (dmPolicy === 'open') {
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
// Discord uses a nested dm object: dm.policy, dm.allowFrom (per DiscordDmConfig)
if (process.env.DISCORD_BOT_TOKEN) {
    const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    const dm = { policy: dmPolicy };
    if (dmPolicy === 'open') {
        dm.allowFrom = ['*'];
    }
    config.channels.discord = {
        token: process.env.DISCORD_BOT_TOKEN,
        enabled: true,
        dm: dm,
    };
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = {
        botToken: process.env.SLACK_BOT_TOKEN,
        appToken: process.env.SLACK_APP_TOKEN,
        enabled: true,
    };
}

// Clean up unsupported keys that may exist in configs restored from R2.
// OpenClaw v2026.2.3 strictly validates the config and rejects unknown keys,
// preventing gateway startup entirely. gogcli-mcp server code was removed but
// old R2 snapshots may still contain "mcp" keys in agent config.
if (config.agents && Array.isArray(config.agents.list)) {
    for (const agent of config.agents.list) {
        if (agent.mcp) {
            console.log('Removing unsupported "mcp" key from agent: ' + (agent.name || 'unknown'));
            delete agent.mcp;
        }
    }
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration patched successfully');
EOFPATCH

# ── Config validation ──────────────────────────────────────
# パッチ後の JSON が壊れていないか検証する。
# R2 から復元された config に不正なキーが残っていた場合、
# OpenClaw がバリデーションエラーで即座にクラッシュし、watchdog が
# 無限ループする障害が 2026-02 に発生した。ここで早期に検知することで
# ゲートウェイ起動前に問題を報告できる。
echo "Validating patched config..."
if ! node -e "JSON.parse(require('fs').readFileSync('$CONFIG_FILE','utf8'))"; then
    echo "FATAL: Patched config is not valid JSON"
    cat > /tmp/gateway-startup-error << EOFERR
{"error":"config_invalid_json","message":"Patched openclaw.json is not valid JSON. The config file may have been corrupted during patching.","timestamp":"$(date -Iseconds)"}
EOFERR
    exit 1
fi
echo "Config validation passed"

# ============================================================
# GOGCLI AUTH SETUP
# ============================================================
# gogcli の認証は2段階:
#   1. OAuth クライアント認証情報 (client_secret.json) → GOG_OAUTH_CREDENTIALS env var
#   2. ユーザーの認証トークン (refresh token) → GOG_AUTH_TOKENS env var
#
# 背景:
# Mac では `keychain` バックエンド (macOS Keychain) でトークンを暗号化するが、
# container では `file` バックエンド (GOG_KEYRING_PASSWORD で暗号化) を使う。
# R2 経由で同期されたトークンファイルは Mac の keychain キーで暗号化されているため
# container 側では復号できない。この問題を解決するため、Mac で
# `gog auth tokens export` した平文 JSON を GOG_AUTH_TOKENS env var に設定し、
# container 起動時に file keyring にインポートする。
#
# セットアップ手順 (Mac 側):
#   gog auth tokens export -o /tmp/gog-tokens.json
#   cat /tmp/gog-tokens.json | npx wrangler secret put GOG_AUTH_TOKENS
#   rm /tmp/gog-tokens.json
#
# 認証スコープ:
# Google Tasks の読み書きには `tasks` スコープが必要 (`tasks.readonly` では書き込み不可)。
# `gog auth add email --services tasks --force-consent` で full access を取得すること。

# Step 1: OAuth client credentials
# credentials.json がなければ毎回セットアップする（コンテナ再作成時に消えるため）
# `gog auth credentials set` で $GOG_CONFIG_DIR/credentials.json に保存される
if [ -n "$GOG_OAUTH_CREDENTIALS" ] && [ ! -f "$GOG_CONFIG_DIR/credentials.json" ]; then
    echo "Setting up gogcli OAuth credentials from env..."
    CREDS_FILE="/tmp/gog-credentials.json"
    echo "$GOG_OAUTH_CREDENTIALS" > "$CREDS_FILE"
    if gog auth credentials set "$CREDS_FILE" 2>&1; then
        echo "gogcli credentials configured"
    else
        echo "ERROR: gogcli credentials setup failed. Google services will not work."
    fi
    rm -f "$CREDS_FILE"
fi

# Step 2: User tokens import (env var → container file keyring)
# 毎回インポートする（wrangler secret でトークンが更新された場合に反映するため）
# GOG_KEYRING_BACKEND / GOG_KEYRING_PASSWORD はスクリプト冒頭で export 済み
if [ -n "$GOG_AUTH_TOKENS" ] && [ -n "$GOG_KEYRING_PASSWORD" ]; then
    echo "Importing gogcli auth tokens from env..."
    TOKENS_FILE="/tmp/gog-tokens-import.json"
    echo "$GOG_AUTH_TOKENS" > "$TOKENS_FILE"

    if gog auth tokens import "$TOKENS_FILE" 2>&1; then
        echo "gogcli token import succeeded"
    else
        echo "ERROR: gogcli token import failed. Google services will not be available."
        echo "Re-export tokens: GOG_KEYRING_PASSWORD=... gog auth tokens export email --out=tokens.json"
    fi
    rm -f "$TOKENS_FILE"

    # インポート結果を検証（gog auth list は認証済みアカウント一覧を表示する）
    echo "Verifying imported tokens..."
    if gog auth list 2>&1; then
        echo "gogcli auth verified"
    else
        echo "WARNING: gogcli auth verification failed after import"
    fi
fi

# ============================================================
# BACKGROUND SYNC LOOP
# ============================================================
if r2_configured; then
    echo "Starting background R2 sync loop..."
    (
        MARKER=/tmp/.last-sync-marker
        LOGFILE=/tmp/r2-sync.log
        touch "$MARKER"

        while true; do
            sleep 30

            CHANGED=/tmp/.changed-files
            {
                find "$CONFIG_DIR" -newer "$MARKER" -type f -printf '%P\n' 2>/dev/null
                find "$WORKSPACE_DIR" -newer "$MARKER" \
                    -not -path '*/node_modules/*' \
                    -not -path '*/.git/*' \
                    -type f -printf '%P\n' 2>/dev/null
                find "$GOG_CONFIG_DIR" -newer "$MARKER" -type f -printf '%P\n' 2>/dev/null
            } > "$CHANGED"

            COUNT=$(wc -l < "$CHANGED" 2>/dev/null || echo 0)

            if [ "$COUNT" -gt 0 ]; then
                echo "[sync] Uploading changes ($COUNT files) at $(date)" >> "$LOGFILE"
                rclone sync "$CONFIG_DIR/" "r2:${R2_BUCKET}/openclaw/" \
                    $RCLONE_FLAGS --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' --exclude='.git/**' 2>> "$LOGFILE"
                if [ -d "$WORKSPACE_DIR" ]; then
                    rclone sync "$WORKSPACE_DIR/" "r2:${R2_BUCKET}/workspace/" \
                        $RCLONE_FLAGS --exclude='skills/**' --exclude='.git/**' --exclude='node_modules/**' 2>> "$LOGFILE"
                fi
                if [ -d "$SKILLS_DIR" ]; then
                    rclone sync "$SKILLS_DIR/" "r2:${R2_BUCKET}/skills/" \
                        $RCLONE_FLAGS 2>> "$LOGFILE"
                fi
                if [ -d "$GOG_CONFIG_DIR" ]; then
                    rclone sync "$GOG_CONFIG_DIR/" "r2:${R2_BUCKET}/gogcli/" \
                        $RCLONE_FLAGS 2>> "$LOGFILE"
                fi
                date -Iseconds > "$LAST_SYNC_FILE"
                touch "$MARKER"
                echo "[sync] Complete at $(date)" >> "$LOGFILE"
            fi
        done
    ) &
    echo "Background sync loop started (PID: $!)"
fi

# ============================================================
# START GATEWAY (with watchdog + circuit breaker)
# ============================================================
# ウォッチドッグループで gateway を起動し、クラッシュ時に自動再起動する。
# 以前は exec で直接起動していたため、gateway が OOM やクラッシュで死ぬと
# 次のリクエストが来るまで（最大1時間）復旧しなかった。
# SIGTERM を受けたらクリーンに終了し、無限再起動を防ぐ。
#
# Circuit breaker (2026-02 障害対応):
# R2 から復元された config に OpenClaw が認識しないキーが含まれると、
# ゲートウェイが即座にクラッシュ → watchdog が再起動 → 再クラッシュ の
# 無限ループに陥る。Worker 側は 180秒タイムアウトを繰り返し、ユーザーには
# "waiting for gateway" が永遠に表示された。
# 対策: CIRCUIT_BREAKER_WINDOW 秒以内に CIRCUIT_BREAKER_MAX_CRASHES 回
# クラッシュしたら config エラーと判断し、エラー情報を JSON ファイルに
# 書き出してループを停止する。
echo "Starting OpenClaw Gateway (with watchdog)..."
echo "Gateway will be available on port 18789"

rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true
rm -f /tmp/gateway-startup-error 2>/dev/null || true

echo "Dev mode: ${OPENCLAW_DEV_MODE:-false}"

GATEWAY_CMD="openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan"
if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    GATEWAY_CMD="$GATEWAY_CMD --token $OPENCLAW_GATEWAY_TOKEN"
    echo "Gateway auth: token"
else
    echo "Gateway auth: device pairing (no token)"
fi

# SIGTERM/SIGINT → ウォッチドッグを停止してクリーンに終了
# Container shutdown 時に無限再起動ループに入らないようにするため
WATCHDOG_RUNNING=true
cleanup() {
    echo "[watchdog] Received shutdown signal, stopping..."
    WATCHDOG_RUNNING=false
    # gateway プロセスがまだ動いていれば SIGTERM を転送
    if [ -n "$GW_PID" ] && kill -0 "$GW_PID" 2>/dev/null; then
        kill "$GW_PID" 2>/dev/null
        wait "$GW_PID" 2>/dev/null
    fi
    exit 0
}
trap cleanup SIGTERM SIGINT

RESTART_DELAY=5

# Circuit breaker の設定
# WINDOW 秒以内に MAX_CRASHES 回クラッシュ → config エラーと判断
CIRCUIT_BREAKER_MAX_CRASHES=3
CIRCUIT_BREAKER_WINDOW=30
CRASH_COUNT=0
FIRST_CRASH_TIME=0
STDERR_LOG="/tmp/gateway-stderr.log"

while $WATCHDOG_RUNNING; do
    echo "[watchdog] Starting gateway..."
    $GATEWAY_CMD 2>> "$STDERR_LOG" &
    GW_PID=$!
    GW_START_TIME=$(date +%s)
    wait "$GW_PID"
    EXIT_CODE=$?
    GW_END_TIME=$(date +%s)
    GW_UPTIME=$((GW_END_TIME - GW_START_TIME))

    if ! $WATCHDOG_RUNNING; then
        echo "[watchdog] Shutdown requested, not restarting"
        break
    fi

    echo "[watchdog] Gateway exited (code=$EXIT_CODE, uptime=${GW_UPTIME}s), restarting in ${RESTART_DELAY}s..."

    # Circuit breaker: 長時間稼働後のクラッシュはカウンターをリセット
    # （OOM 等の一時的な問題であり、config エラーではない）
    if [ "$GW_UPTIME" -ge "$CIRCUIT_BREAKER_WINDOW" ]; then
        CRASH_COUNT=0
        FIRST_CRASH_TIME=0
    else
        # 短時間クラッシュ → カウンターを加算
        NOW=$(date +%s)
        if [ "$CRASH_COUNT" -eq 0 ]; then
            FIRST_CRASH_TIME=$NOW
        fi

        # ウィンドウを超えた古いクラッシュはリセット
        ELAPSED=$((NOW - FIRST_CRASH_TIME))
        if [ "$ELAPSED" -ge "$CIRCUIT_BREAKER_WINDOW" ]; then
            CRASH_COUNT=1
            FIRST_CRASH_TIME=$NOW
        else
            CRASH_COUNT=$((CRASH_COUNT + 1))
        fi

        echo "[watchdog] Quick crash detected (${GW_UPTIME}s uptime, crash $CRASH_COUNT/$CIRCUIT_BREAKER_MAX_CRASHES in ${ELAPSED:-0}s window)"

        if [ "$CRASH_COUNT" -ge "$CIRCUIT_BREAKER_MAX_CRASHES" ]; then
            echo "[watchdog] CIRCUIT BREAKER OPEN: Gateway crashed $CRASH_COUNT times within ${CIRCUIT_BREAKER_WINDOW}s"
            echo "[watchdog] This likely indicates a configuration error. Check stderr log: $STDERR_LOG"

            # 最新の stderr を取得してエラーファイルに書き出し
            LAST_STDERR=$(tail -50 "$STDERR_LOG" 2>/dev/null || echo "(no stderr captured)")
            # JSON エスケープ（改行・引用符）
            ESCAPED_STDERR=$(echo "$LAST_STDERR" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '"(stderr unavailable)"')

            cat > /tmp/gateway-startup-error << EOFERR
{"error":"circuit_breaker_open","message":"Gateway crashed $CRASH_COUNT times within ${CIRCUIT_BREAKER_WINDOW}s. Likely a configuration error.","exitCode":$EXIT_CODE,"crashCount":$CRASH_COUNT,"stderr":$ESCAPED_STDERR,"timestamp":"$(date -Iseconds)"}
EOFERR
            echo "[watchdog] Error details written to /tmp/gateway-startup-error"
            # ループを停止（Worker 側が /tmp/gateway-startup-error を読んでユーザーに表示する）
            break
        fi
    fi

    # ロックファイルが残るとプロセス再起動に失敗するため掃除
    rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
    rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

    sleep "$RESTART_DELAY"
done
