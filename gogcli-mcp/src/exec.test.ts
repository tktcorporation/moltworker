import { describe, it, expect, vi, beforeEach } from 'vitest';
import { execGog, execGogJson } from './exec.js';

vi.mock('node:child_process', () => ({
  execFile: vi.fn(),
}));

import { execFile } from 'node:child_process';

const mockExecFile = vi.mocked(execFile);

beforeEach(() => {
  vi.clearAllMocks();
});

describe('execGog', () => {
  it('calls gog with --json and --no-input flags', async () => {
    mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
      (callback as Function)(null, '', '');
      return undefined as any;
    });

    await execGog(['gmail', 'search', 'test']);

    expect(mockExecFile).toHaveBeenCalledWith(
      'gog',
      ['--json', '--no-input', 'gmail', 'search', 'test'],
      expect.objectContaining({ timeout: 30_000, maxBuffer: 10 * 1024 * 1024 }),
      expect.any(Function),
    );
  });

  it('returns stdout, stderr, exitCode on success', async () => {
    mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
      (callback as Function)(null, '{"result": "ok"}', 'some warning');
      return undefined as any;
    });

    const result = await execGog(['gmail', 'search', 'test']);

    expect(result).toEqual({
      stdout: '{"result": "ok"}',
      stderr: 'some warning',
      exitCode: 0,
    });
  });

  it('returns non-zero exitCode on error', async () => {
    const error = Object.assign(new Error('Command failed'), { code: 2 });
    mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
      (callback as Function)(error, '', 'error output');
      return undefined as any;
    });

    const result = await execGog(['gmail', 'search', 'test']);

    expect(result).toEqual({
      stdout: '',
      stderr: 'error output',
      exitCode: 2,
    });
  });
});

describe('execGogJson', () => {
  it('parses JSON output on success', async () => {
    mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
      (callback as Function)(null, '{"messages": [{"id": "1"}]}', '');
      return undefined as any;
    });

    const result = await execGogJson(['gmail', 'search', 'test']);

    expect(result).toEqual({ messages: [{ id: '1' }] });
  });

  it('throws on non-zero exit code', async () => {
    const error = Object.assign(new Error('Command failed'), { code: 1 });
    mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
      (callback as Function)(error, '', 'auth failed');
      return undefined as any;
    });

    await expect(execGogJson(['gmail', 'search', 'test'])).rejects.toThrow(
      'gogcli failed (exit 1): auth failed',
    );
  });

  it('throws on invalid JSON', async () => {
    mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
      (callback as Function)(null, 'not valid json', '');
      return undefined as any;
    });

    await expect(execGogJson(['gmail', 'search', 'test'])).rejects.toThrow(
      'Failed to parse gogcli JSON output',
    );
  });
});
