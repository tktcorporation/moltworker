/**
 * Configuration constants for Moltbot Sandbox
 */

/** Port that the Moltbot gateway listens on inside the container */
export const MOLTBOT_PORT = 18789;

/**
 * Maximum time to wait for Moltbot to start (3 minutes).
 *
 * この値は以下のバランスで決定:
 * - 通常起動: R2 からの復元 + onboard + config パッチ + gateway 起動で 60-90 秒
 * - 余裕を持って 180 秒に設定
 * - quick-crash detection (process.ts) により、config エラーでの即座クラッシュ時は
 *   このタイムアウトを待たずに GatewayStartupError が throw される
 */
export const STARTUP_TIMEOUT_MS = 180_000;

/**
 * R2 bucket name for persistent storage.
 * Can be overridden via R2_BUCKET_NAME env var for test isolation.
 */
export function getR2BucketName(env?: { R2_BUCKET_NAME?: string }): string {
  return env?.R2_BUCKET_NAME || 'moltbot-data';
}
