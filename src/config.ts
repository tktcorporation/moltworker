/**
 * Configuration constants for Moltbot Sandbox
 */

/** Port that the Moltbot gateway listens on inside the container */
export const MOLTBOT_PORT = 18789;

/**
 * Maximum time to wait for gateway to start (60 seconds).
 *
 * ZeroClaw は起動が高速 (<10秒) だが、R2 復元 (10-20秒) を考慮し余裕を持たせる。
 * quick-crash detection (process.ts) により config エラーでの即座クラッシュ時は
 * このタイムアウトを待たずに GatewayStartupError が throw される。
 */
export const STARTUP_TIMEOUT_MS = 60_000;

/**
 * R2 bucket name for persistent storage.
 * Can be overridden via R2_BUCKET_NAME env var for test isolation.
 */
export function getR2BucketName(env?: { R2_BUCKET_NAME?: string }): string {
  return env?.R2_BUCKET_NAME || 'moltbot-data';
}
