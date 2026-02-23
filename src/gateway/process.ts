import type { Sandbox, Process } from '@cloudflare/sandbox';
import type { MoltbotEnv } from '../types';
import { MOLTBOT_PORT, STARTUP_TIMEOUT_MS } from '../config';
import { buildEnvVars } from './env';
import { ensureRcloneConfig } from './r2';

/**
 * Gateway の起動失敗を表すエラー。
 *
 * 通常の Error と区別することで、呼び出し元（ルートハンドラ等）が
 * 起動失敗時に適切なレスポンスを返せるようにする。
 */
export class GatewayStartupError extends Error {
  /** プロセスの終了コード（取得できた場合） */
  readonly exitCode?: number;
  /** circuit breaker が書き出したエラー詳細（JSON） */
  readonly startupErrorDetails?: string;

  constructor(
    message: string,
    options?: { exitCode?: number; startupErrorDetails?: string; cause?: unknown },
  ) {
    super(message, { cause: options?.cause });
    this.name = 'GatewayStartupError';
    this.exitCode = options?.exitCode;
    this.startupErrorDetails = options?.startupErrorDetails;
  }
}

/** circuit breaker が書き出すエラーファイルのパス */
const STARTUP_ERROR_FILE = '/tmp/gateway-startup-error';

/**
 * コンテナ内の circuit breaker エラーファイルを読み取る。
 * ファイルが存在しない場合は null を返す。
 */
export async function readStartupError(sandbox: Sandbox): Promise<string | null> {
  try {
    const result = await sandbox.readFile(STARTUP_ERROR_FILE);
    return result.success ? result.content : null;
  } catch {
    return null;
  }
}

/**
 * Find an existing OpenClaw gateway process
 *
 * @param sandbox - The sandbox instance
 * @returns The process if found and running/starting, null otherwise
 */
export async function findExistingMoltbotProcess(sandbox: Sandbox): Promise<Process | null> {
  try {
    const processes = await sandbox.listProcesses();
    for (const proc of processes) {
      // Match the startup script (which wraps gateway in a watchdog loop).
      // The script spawns `openclaw gateway` as a child process, but we track
      // the wrapper because killing it also stops the watchdog and child.
      // Don't match individual CLI commands like "openclaw devices list".
      const isStartupScript =
        proc.command.includes('start-openclaw.sh') ||
        proc.command.includes('start-moltbot.sh');
      // Match the actual gateway process (child of startup script, or standalone)
      const isGatewayBinary =
        proc.command.includes('openclaw gateway') ||
        proc.command.includes('clawdbot gateway');
      const isCliCommand =
        proc.command.includes('openclaw devices') ||
        proc.command.includes('openclaw --version') ||
        proc.command.includes('openclaw onboard') ||
        proc.command.includes('clawdbot devices') ||
        proc.command.includes('clawdbot --version');
      // Prefer the startup script (watchdog wrapper) over the bare gateway binary.
      // Both are "gateway-related", but the startup script is the parent process.
      const isGatewayProcess = isStartupScript || (isGatewayBinary && !isCliCommand);

      if (isGatewayProcess) {
        if (proc.status === 'starting' || proc.status === 'running') {
          return proc;
        }
      }
    }
  } catch (e) {
    console.log('Could not list processes:', e);
  }
  return null;
}

/**
 * Ensure the OpenClaw gateway is running
 *
 * This will:
 * 1. Mount R2 storage if configured
 * 2. Check for an existing gateway process
 * 3. Wait for it to be ready, or start a new one
 *
 * 障害パターンと対策:
 * - **Config エラーによる即座クラッシュ** (2026-02 障害): R2 から復元された config に
 *   OpenClaw が認識しないキーがあると gateway が即座にクラッシュ。start-openclaw.sh の
 *   circuit breaker が 30 秒以内に 3 回クラッシュを検知してループを停止し、
 *   /tmp/gateway-startup-error にエラー詳細を書き出す。この関数は waitForExit() で
 *   プロセスの早期終了を検出し、180 秒のタイムアウトを待たずに GatewayStartupError を throw する。
 * - **OOM / 一時的クラッシュ**: watchdog が自動再起動。uptime が長いのでカウンターはリセットされる。
 * - **ポートが開かない**: STARTUP_TIMEOUT_MS (180s) 後にタイムアウト。
 *
 * @param sandbox - The sandbox instance
 * @param env - Worker environment bindings
 * @returns The running gateway process
 * @throws {GatewayStartupError} Gateway の起動に失敗した場合
 */
export async function ensureMoltbotGateway(sandbox: Sandbox, env: MoltbotEnv): Promise<Process> {
  // Configure rclone for R2 persistence (non-blocking if not configured).
  // The startup script uses rclone to restore data from R2 on boot.
  await ensureRcloneConfig(sandbox, env);

  // Check if gateway is already running or starting
  const existingProcess = await findExistingMoltbotProcess(sandbox);
  if (existingProcess) {
    console.log(
      'Found existing gateway process:',
      existingProcess.id,
      'status:',
      existingProcess.status,
    );

    // Promise.race で「ポートが開く」か「プロセスが終了する」の早い方を待つ。
    // config エラーで即座クラッシュする場合、waitForPort だけだと 180 秒待ち続けてしまう。
    try {
      console.log('Waiting for gateway on port', MOLTBOT_PORT, 'timeout:', STARTUP_TIMEOUT_MS);
      const portReady = existingProcess
        .waitForPort(MOLTBOT_PORT, { mode: 'tcp', timeout: STARTUP_TIMEOUT_MS })
        .then(() => ({ type: 'port_ready' as const }));
      const processExited = existingProcess
        .waitForExit(STARTUP_TIMEOUT_MS)
        .then((result) => ({ type: 'process_exited' as const, exitCode: result.exitCode }));

      const result = await Promise.race([portReady, processExited]);

      if (result.type === 'port_ready') {
        console.log('Gateway is reachable');
        return existingProcess;
      }

      // プロセスが先に終了 → circuit breaker のエラーファイルを確認
      const errorDetails = await readStartupError(sandbox);
      const msg = `Existing gateway process exited with code ${result.exitCode}`;
      console.log(msg);
      throw new GatewayStartupError(msg, {
        exitCode: result.exitCode,
        startupErrorDetails: errorDetails ?? undefined,
      });
      // eslint-disable-next-line no-unused-vars
    } catch (e) {
      if (e instanceof GatewayStartupError) throw e;
      // Timeout waiting for port - process is likely dead or stuck, kill and restart
      console.log('Existing process not reachable after full timeout, killing and restarting...');
      try {
        await existingProcess.kill();
      } catch (killError) {
        console.log('Failed to kill process:', killError);
      }
    }
  }

  // Start a new OpenClaw gateway
  console.log('Starting new OpenClaw gateway...');
  const envVars = buildEnvVars(env);
  const command = '/usr/local/bin/start-openclaw.sh';

  console.log('Starting process with command:', command);
  console.log('Environment vars being passed:', Object.keys(envVars));

  let process: Process;
  try {
    process = await sandbox.startProcess(command, {
      env: Object.keys(envVars).length > 0 ? envVars : undefined,
    });
    console.log('Process started with id:', process.id, 'status:', process.status);
  } catch (startErr) {
    console.error('Failed to start process:', startErr);
    throw startErr;
  }

  // Wait for the gateway to be ready.
  // Promise.race で「ポートが開く」か「プロセスが終了する」の早い方を待つ。
  // config エラーで即座クラッシュする場合、waitForPort だけだと 180 秒待ち続ける問題を解消。
  try {
    console.log('[Gateway] Waiting for OpenClaw gateway to be ready on port', MOLTBOT_PORT);

    const portReady = process
      .waitForPort(MOLTBOT_PORT, { mode: 'tcp', timeout: STARTUP_TIMEOUT_MS })
      .then(() => ({ type: 'port_ready' as const }));
    const processExited = process
      .waitForExit(STARTUP_TIMEOUT_MS)
      .then((result) => ({ type: 'process_exited' as const, exitCode: result.exitCode }));

    const raceResult = await Promise.race([portReady, processExited]);

    if (raceResult.type === 'port_ready') {
      console.log('[Gateway] OpenClaw gateway is ready!');
      const logs = await process.getLogs();
      if (logs.stdout) console.log('[Gateway] stdout:', logs.stdout);
      if (logs.stderr) console.log('[Gateway] stderr:', logs.stderr);
    } else {
      // プロセスがポートを開く前に終了 → 起動失敗
      console.error('[Gateway] Process exited before port was ready, exitCode:', raceResult.exitCode);
      const errorDetails = await readStartupError(sandbox);
      let stderrContent = '';
      try {
        const logs = await process.getLogs();
        stderrContent = logs.stderr || '';
        if (logs.stderr) console.error('[Gateway] stderr:', logs.stderr);
        if (logs.stdout) console.error('[Gateway] stdout:', logs.stdout);
      } catch (logErr) {
        console.error('[Gateway] Failed to get logs:', logErr);
      }

      throw new GatewayStartupError(
        `OpenClaw gateway process exited with code ${raceResult.exitCode}. Stderr: ${stderrContent || '(empty)'}`,
        {
          exitCode: raceResult.exitCode,
          startupErrorDetails: errorDetails ?? undefined,
        },
      );
    }
  } catch (e) {
    if (e instanceof GatewayStartupError) throw e;
    console.error('[Gateway] waitForPort failed:', e);
    try {
      const logs = await process.getLogs();
      console.error('[Gateway] startup failed. Stderr:', logs.stderr);
      console.error('[Gateway] startup failed. Stdout:', logs.stdout);
      throw new GatewayStartupError(
        `OpenClaw gateway failed to start. Stderr: ${logs.stderr || '(empty)'}`,
        { cause: e },
      );
    } catch (logErr) {
      if (logErr instanceof GatewayStartupError) throw logErr;
      console.error('[Gateway] Failed to get logs:', logErr);
      throw e;
    }
  }

  // Verify gateway is actually responding
  console.log('[Gateway] Verifying gateway health...');

  return process;
}
