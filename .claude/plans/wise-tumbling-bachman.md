# R2 ↔ Git 双方向同期 実装計画

## Context

moltworker は Cloudflare Sandbox 内で OpenClaw を動かすプロジェクト。コンテナ内の設定（cronジョブ、ワークスペースファイル等）は R2 に同期されるが、git 管理されていない。このため：
- 変更の追跡・レビューができない
- cronジョブの `wakeMode` 設定ミスが発生した（`next-heartbeat` → `now` に変更が必要だった）
- コンテナ再作成時に R2 依存で復元されるが、R2 が壊れると全て失われる

**目的**: R2 のデータを git に同期し、git を source of truth とする IaC 的管理を実現する。

## 実装ステップ

### Step 1: `r2-state/` ディレクトリ作成

`moltworker/r2-state/` を作成。初期状態は `.gitkeep` のみ。
GitHub Actions が R2 からデータを取得してここに配置する。

- 作成: `moltworker/r2-state/.gitkeep`

### Step 2: GitHub Actions ワークフロー作成

`.github/workflows/r2-sync.yml` を作成。

- トリガー: `schedule: '0 * * * *'` (毎時) + `workflow_dispatch` (手動)
- 処理:
  1. rclone インストール・設定
  2. R2 から `openclaw/cron/jobs.json` → `moltworker/r2-state/cron-jobs.json`
  3. R2 から `workspace/` → `moltworker/r2-state/workspace/` (除外: `.git/`, `node_modules/`)
  4. `peter-evans/create-pull-request` で差分があれば PR 作成
- Secrets 必要: `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `CF_ACCOUNT_ID`
- permissions: `contents: write`, `pull-requests: write`

### Step 3: Dockerfile 修正

`moltworker/Dockerfile` に追加 (行 40, skills COPY の前):

```dockerfile
# Copy git-managed R2 state (cron jobs, workspace base files)
COPY r2-state/ /usr/local/etc/openclaw-base/
```

- 修正: `moltworker/Dockerfile` (行 40 付近)

### Step 4: start-openclaw.sh に reconcile スクリプト追加

行 181 と 182 の間（onboard 完了後、config patch 前）に挿入。

```bash
# ============================================================
# RECONCILE GIT-MANAGED FILES
# ============================================================
```

Node スクリプトで:
1. **Cron jobs reconcile**: `/usr/local/etc/openclaw-base/cron-jobs.json` と `/root/.openclaw/cron/jobs.json` を `name` でマッチングしてマージ
   - 同名: git の設定 (schedule, wakeMode, payload, delivery) + R2 の state (lastRunAtMs, nextRunAtMs, id)
   - git のみ: 新規追加 (id は crypto.randomUUID() で生成)
   - R2 のみ: そのまま保持
2. **Workspace files**: `/usr/local/etc/openclaw-base/workspace/` のファイルを `/root/clawd/` に上書きコピー

- 修正: `moltworker/start-openclaw.sh` (行 181-182 間に挿入)

### Step 5: テスト追加

reconcile ロジックのユニットテストを追加。
Node スクリプトのロジック部分を抽出して `src/gateway/reconcile.ts` に配置し、テスト可能にする。

- 作成: `moltworker/src/gateway/reconcile.ts`
- 作成: `moltworker/src/gateway/reconcile.test.ts`

テストケース:
- git のみのジョブが追加される
- R2 のみのジョブが保持される
- 同名ジョブで git の設定が優先、R2 の state が保持される
- git ジョブの wakeMode が常に適用される

### Step 6: r2-investigator が作った R2_DATA_STRUCTURE.md を削除

調査用の一時ファイルなので削除。

- 削除: `moltworker/R2_DATA_STRUCTURE.md`

## 対象ファイル一覧

| ファイル | 操作 |
|---------|------|
| `moltworker/r2-state/.gitkeep` | 作成 |
| `.github/workflows/r2-sync.yml` | 作成 |
| `moltworker/Dockerfile` | 修正 (COPY r2-state/ 追加) |
| `moltworker/start-openclaw.sh` | 修正 (reconcile スクリプト追加) |
| `moltworker/src/gateway/reconcile.ts` | 作成 |
| `moltworker/src/gateway/reconcile.test.ts` | 作成 |
| `moltworker/R2_DATA_STRUCTURE.md` | 削除 |

## 検証方法

1. `cd moltworker && npm test` — 全テスト通過
2. `cd moltworker && npm run typecheck` — 型チェック通過
3. `cd moltworker && npm run lint` — lint 通過
4. GitHub Actions ワークフローの手動実行 (`workflow_dispatch`) で R2 → Git 同期を確認
5. デプロイ後、`/debug/cli?cmd=openclaw cron list --json` で reconcile されたジョブを確認
