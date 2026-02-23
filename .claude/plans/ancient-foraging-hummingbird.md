# Plan: ゲートウェイ起動失敗の fail-fast 化とドキュメント追加

## Context

2026年2月の本番障害で、R2 から復元された openclaw.json に OpenClaw v2026.2.3 が認識しない mcp キーが含まれていたため、ゲートウェイが即座にクラッシュ。しかし watchdog が無限再起動し、Worker は 180秒タイムアウトを繰り返し、ユーザーには waiting for gateway が永遠に表示された。エラーメッセージは stderr にあったが、誰にも表示されなかった。

この計画は「サイレントな無限ループ」を防ぐ改善を実装する。

## 変更一覧

### 1. Watchdog circuit breaker (start-openclaw.sh)
目的: config エラーによる即座クラッシュの無限ループを検知・停止

- watchdog ループに crash counter を追加
- 30秒以内に3回クラッシュで config エラーと判断しループ停止
- エラー詳細を /tmp/gateway-startup-error (JSON) に書き出し
- stderr を /tmp/gateway-stderr.log にリダイレクトして保存
- 長時間稼働後のクラッシュはカウンターをリセット（通常の再起動）

### 2. Quick-crash detection (src/gateway/process.ts)
目的: プロセスが即座に終了した場合、180秒待たずにエラーを検出

- Promise.race([waitForPort(), waitForExit()]) パターンを使用
- waitForExit() が先に resolve ならプロセスがクラッシュ、即座にエラー throw
- waitForPort() が先に resolve なら正常起動
- 既存プロセスの待機ロジックにも同じパターンを適用
- GatewayStartupError クラスを追加（exit code を保持）
- circuit breaker エラーファイルも読み取って詳細をエラーメッセージに含める

### 3. /api/status にエラー情報追加 (src/routes/public.ts)
目的: Loading ページがエラー内容を取得できるようにする

- not_running / not_responding 時に /tmp/gateway-startup-error を読み取り
- 新ステータス startup_failed を追加（error フィールド付き）

### 4. Loading ページにエラー表示 (src/assets/loading.html)
目的: ユーザーに起動失敗の理由を表示

- status === startup_failed のハンドリング追加
- スピナーを停止してエラーメッセージ表示
- stderr 内容と再起動方法のヒントを表示
- ポーリングを停止

### 5. Config validation (start-openclaw.sh)
目的: パッチ後の JSON が壊れていないか検証

- config パッチ後に node -e で JSON 妥当性チェック
- 失敗時はエラーファイルを書き出して即座に exit

### 6. ドキュメント追加（各ファイル）
- process.ts: ensureMoltbotGateway に障害パターンの JSDoc
- start-openclaw.sh: circuit breaker セクションに背景コメント
- loading.html: polling 間隔の理由コメント
- public.ts: /api/status レスポンス形式の JSDoc
- config.ts: STARTUP_TIMEOUT_MS の補足コメント

## 対象ファイル

1. start-openclaw.sh - circuit breaker + config validation
2. src/gateway/process.ts - quick-crash detection
3. src/routes/public.ts - richer status endpoint
4. src/assets/loading.html - error display
5. src/gateway/process.test.ts - テスト追加
6. src/test-utils.ts - waitForExit mock 追加
7. src/config.ts - ドキュメント追加

## 実装順序

1. start-openclaw.sh (circuit breaker + config validation)
2. src/test-utils.ts + src/gateway/process.ts + テスト
3. src/routes/public.ts
4. src/assets/loading.html
5. 各ファイルのドキュメント追加

## 検証

- npm test で全テスト通過
- npm run typecheck で型チェック通過
- デプロイ後に正常起動を確認
