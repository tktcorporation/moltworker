import { Hono } from 'hono';
import type { AppEnv } from '../types';
import { MOLTBOT_PORT } from '../config';
import { findExistingMoltbotProcess, readStartupError } from '../gateway';

/**
 * Public routes - NO Cloudflare Access authentication required
 *
 * These routes are mounted BEFORE the auth middleware is applied.
 * Includes: health checks, static assets, and public API endpoints.
 */
const publicRoutes = new Hono<AppEnv>();

// GET /sandbox-health - Health check endpoint
publicRoutes.get('/sandbox-health', (c) => {
  return c.json({
    status: 'ok',
    service: 'moltbot-sandbox',
    gateway_port: MOLTBOT_PORT,
  });
});

// GET /logo.png - Serve logo from ASSETS binding
publicRoutes.get('/logo.png', (c) => {
  return c.env.ASSETS.fetch(c.req.raw);
});

// GET /logo-small.png - Serve small logo from ASSETS binding
publicRoutes.get('/logo-small.png', (c) => {
  return c.env.ASSETS.fetch(c.req.raw);
});

/**
 * GET /api/status - Public health check for gateway status (no auth required)
 *
 * Loading ページがポーリングで呼び出し、ゲートウェイの状態を表示する。
 *
 * レスポンス形式:
 * - `{ ok: true, status: "running", processId }` - ゲートウェイ稼働中
 * - `{ ok: false, status: "not_running" }` - プロセスが存在しない（起動前）
 * - `{ ok: false, status: "not_responding", processId }` - プロセスはあるがポートが応答しない
 * - `{ ok: false, status: "startup_failed", error, processId? }` - circuit breaker が起動失敗を検知
 * - `{ ok: false, status: "error", error }` - 予期しないエラー
 */
publicRoutes.get('/api/status', async (c) => {
  const sandbox = c.get('sandbox');

  try {
    // circuit breaker がエラーファイルを書き出している場合、起動失敗として報告
    const startupError = await readStartupError(sandbox);
    if (startupError) {
      let errorData: Record<string, unknown> = {};
      try {
        errorData = JSON.parse(startupError);
      } catch {
        errorData = { message: startupError };
      }
      return c.json({
        ok: false,
        status: 'startup_failed',
        error: errorData,
      });
    }

    const process = await findExistingMoltbotProcess(sandbox);
    if (!process) {
      return c.json({ ok: false, status: 'not_running' });
    }

    // Process exists, check if it's actually responding
    // Try to reach the gateway with a short timeout
    try {
      await process.waitForPort(18789, { mode: 'tcp', timeout: 5000 });
      return c.json({ ok: true, status: 'running', processId: process.id });
    } catch {
      return c.json({ ok: false, status: 'not_responding', processId: process.id });
    }
  } catch (err) {
    return c.json({
      ok: false,
      status: 'error',
      error: err instanceof Error ? err.message : 'Unknown error',
    });
  }
});

// GET /_admin/assets/* - Admin UI static assets (CSS, JS need to load for login redirect)
// Assets are built to dist/client with base "/_admin/"
publicRoutes.get('/_admin/assets/*', async (c) => {
  const url = new URL(c.req.url);
  // Rewrite /_admin/assets/* to /assets/* for the ASSETS binding
  const assetPath = url.pathname.replace('/_admin/assets/', '/assets/');
  const assetUrl = new URL(assetPath, url.origin);
  return c.env.ASSETS.fetch(new Request(assetUrl.toString(), c.req.raw));
});

export { publicRoutes };
