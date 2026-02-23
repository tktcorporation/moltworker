import { execFile } from 'node:child_process';

export interface GogResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

const GOG_BINARY = process.env.GOG_BINARY || 'gog';
const GOG_TIMEOUT_MS = 30_000;

/**
 * Execute a gogcli command with --json flag and return parsed output.
 */
export function execGog(args: string[]): Promise<GogResult> {
  return new Promise((resolve) => {
    execFile(
      GOG_BINARY,
      ['--json', '--no-input', ...args],
      {
        timeout: GOG_TIMEOUT_MS,
        maxBuffer: 10 * 1024 * 1024,
        env: { ...process.env, GOG_KEYRING_BACKEND: 'file' },
      },
      (error, stdout, stderr) => {
        resolve({
          stdout: stdout ?? '',
          stderr: stderr ?? '',
          exitCode: error?.code && typeof error.code === 'number' ? error.code : (error ? 1 : 0),
        });
      },
    );
  });
}

/**
 * Execute gogcli and parse JSON output.
 */
export async function execGogJson<T = unknown>(args: string[]): Promise<T> {
  const result = await execGog(args);
  if (result.exitCode !== 0) {
    throw new Error(`gogcli failed (exit ${result.exitCode}): ${result.stderr || result.stdout}`);
  }
  try {
    return JSON.parse(result.stdout) as T;
  } catch {
    throw new Error(`Failed to parse gogcli JSON output: ${result.stdout.slice(0, 500)}`);
  }
}
