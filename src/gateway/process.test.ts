import { describe, it, expect, vi, beforeEach } from 'vitest';
import { findExistingMoltbotProcess, ensureMoltbotGateway, GatewayStartupError } from './process';
import type { Sandbox, Process } from '@cloudflare/sandbox';
import { createMockSandbox, createMockEnv, suppressConsole } from '../test-utils';

function createFullMockProcess(overrides: Partial<Process> = {}): Process {
  return {
    id: 'test-id',
    command: 'openclaw gateway',
    status: 'running',
    startTime: new Date(),
    endTime: undefined,
    exitCode: undefined,
    waitForPort: vi.fn(),
    waitForExit: vi.fn().mockImplementation(() => new Promise(() => {})),
    kill: vi.fn(),
    getLogs: vi.fn().mockResolvedValue({ stdout: '', stderr: '' }),
    ...overrides,
  } as Process;
}

describe('findExistingMoltbotProcess', () => {
  it('returns null when no processes exist', async () => {
    const { sandbox } = createMockSandbox({ processes: [] });
    const result = await findExistingMoltbotProcess(sandbox);
    expect(result).toBeNull();
  });

  it('returns null when only CLI commands are running', async () => {
    const processes = [
      createFullMockProcess({ command: 'openclaw devices list --json', status: 'running' }),
      createFullMockProcess({ command: 'openclaw --version', status: 'completed' }),
    ];
    const { sandbox, listProcessesMock } = createMockSandbox();
    listProcessesMock.mockResolvedValue(processes);

    const result = await findExistingMoltbotProcess(sandbox);
    expect(result).toBeNull();
  });

  it('returns gateway process when running (openclaw)', async () => {
    const gatewayProcess = createFullMockProcess({
      id: 'gateway-1',
      command: 'openclaw gateway --port 18789',
      status: 'running',
    });
    const processes = [
      createFullMockProcess({ command: 'openclaw devices list', status: 'completed' }),
      gatewayProcess,
    ];
    const { sandbox, listProcessesMock } = createMockSandbox();
    listProcessesMock.mockResolvedValue(processes);

    const result = await findExistingMoltbotProcess(sandbox);
    expect(result).toBe(gatewayProcess);
  });

  it('returns gateway process when starting via startup script', async () => {
    const gatewayProcess = createFullMockProcess({
      id: 'gateway-1',
      command: '/usr/local/bin/start-openclaw.sh',
      status: 'starting',
    });
    const { sandbox, listProcessesMock } = createMockSandbox();
    listProcessesMock.mockResolvedValue([gatewayProcess]);

    const result = await findExistingMoltbotProcess(sandbox);
    expect(result).toBe(gatewayProcess);
  });

  it('matches legacy clawdbot gateway command (transition compat)', async () => {
    const gatewayProcess = createFullMockProcess({
      id: 'gateway-1',
      command: 'clawdbot gateway --port 18789',
      status: 'running',
    });
    const { sandbox, listProcessesMock } = createMockSandbox();
    listProcessesMock.mockResolvedValue([gatewayProcess]);

    const result = await findExistingMoltbotProcess(sandbox);
    expect(result).toBe(gatewayProcess);
  });

  it('matches legacy start-moltbot.sh command (transition compat)', async () => {
    const gatewayProcess = createFullMockProcess({
      id: 'gateway-1',
      command: '/usr/local/bin/start-moltbot.sh',
      status: 'running',
    });
    const { sandbox, listProcessesMock } = createMockSandbox();
    listProcessesMock.mockResolvedValue([gatewayProcess]);

    const result = await findExistingMoltbotProcess(sandbox);
    expect(result).toBe(gatewayProcess);
  });

  it('ignores completed gateway processes', async () => {
    const processes = [
      createFullMockProcess({ command: 'openclaw gateway', status: 'completed' }),
      createFullMockProcess({ command: 'start-openclaw.sh', status: 'failed' }),
    ];
    const { sandbox, listProcessesMock } = createMockSandbox();
    listProcessesMock.mockResolvedValue(processes);

    const result = await findExistingMoltbotProcess(sandbox);
    expect(result).toBeNull();
  });

  it('handles listProcesses errors gracefully', async () => {
    const sandbox = {
      listProcesses: vi.fn().mockRejectedValue(new Error('Network error')),
    } as unknown as Sandbox;

    const result = await findExistingMoltbotProcess(sandbox);
    expect(result).toBeNull();
  });

  it('returns first matching gateway process', async () => {
    const firstGateway = createFullMockProcess({
      id: 'gateway-1',
      command: 'openclaw gateway',
      status: 'running',
    });
    const secondGateway = createFullMockProcess({
      id: 'gateway-2',
      command: 'start-openclaw.sh',
      status: 'starting',
    });
    const { sandbox, listProcessesMock } = createMockSandbox();
    listProcessesMock.mockResolvedValue([firstGateway, secondGateway]);

    const result = await findExistingMoltbotProcess(sandbox);
    expect(result?.id).toBe('gateway-1');
  });

  it('does not match openclaw onboard as a gateway process', async () => {
    const processes = [
      createFullMockProcess({ command: 'openclaw onboard --non-interactive', status: 'running' }),
    ];
    const { sandbox, listProcessesMock } = createMockSandbox();
    listProcessesMock.mockResolvedValue(processes);

    const result = await findExistingMoltbotProcess(sandbox);
    expect(result).toBeNull();
  });
});

describe('GatewayStartupError', () => {
  it('includes exitCode and startupErrorDetails', () => {
    const err = new GatewayStartupError('test', {
      exitCode: 1,
      startupErrorDetails: '{"error":"circuit_breaker_open"}',
    });
    expect(err.name).toBe('GatewayStartupError');
    expect(err.exitCode).toBe(1);
    expect(err.startupErrorDetails).toBe('{"error":"circuit_breaker_open"}');
    expect(err.message).toBe('test');
  });

  it('works without optional fields', () => {
    const err = new GatewayStartupError('simple error');
    expect(err.exitCode).toBeUndefined();
    expect(err.startupErrorDetails).toBeUndefined();
  });
});

describe('ensureMoltbotGateway', () => {
  beforeEach(() => {
    suppressConsole();
  });

  it('throws GatewayStartupError when new process exits immediately', async () => {
    const mockProcess = createFullMockProcess({
      id: 'gw-1',
      command: '/usr/local/bin/start-openclaw.sh',
      status: 'running',
    });

    // waitForPort never resolves; waitForExit resolves immediately (crash)
    mockProcess.waitForPort = vi.fn().mockImplementation(() => new Promise(() => {}));
    mockProcess.waitForExit = vi.fn().mockResolvedValue({ exitCode: 1 });

    const { sandbox, startProcessMock, listProcessesMock, readFileMock } = createMockSandbox();
    listProcessesMock.mockResolvedValue([]);
    startProcessMock.mockResolvedValue(mockProcess);
    // circuit breaker error file exists
    readFileMock.mockResolvedValue({
      success: true,
      path: '/tmp/gateway-startup-error',
      content: '{"error":"circuit_breaker_open","message":"Gateway crashed 3 times"}',
    });

    const env = createMockEnv();

    await expect(ensureMoltbotGateway(sandbox, env)).rejects.toThrow(GatewayStartupError);

    try {
      await ensureMoltbotGateway(sandbox, env);
    } catch (e) {
      expect(e).toBeInstanceOf(GatewayStartupError);
      const err = e as GatewayStartupError;
      expect(err.exitCode).toBe(1);
      expect(err.startupErrorDetails).toContain('circuit_breaker_open');
    }
  });

  it('succeeds when port becomes ready before process exits', async () => {
    const mockProcess = createFullMockProcess({
      id: 'gw-1',
      command: '/usr/local/bin/start-openclaw.sh',
      status: 'running',
    });

    // waitForPort resolves immediately (success); waitForExit never resolves
    mockProcess.waitForPort = vi.fn().mockResolvedValue(undefined);
    mockProcess.waitForExit = vi.fn().mockImplementation(() => new Promise(() => {}));

    const { sandbox, startProcessMock, listProcessesMock } = createMockSandbox();
    listProcessesMock.mockResolvedValue([]);
    startProcessMock.mockResolvedValue(mockProcess);

    const env = createMockEnv();
    const result = await ensureMoltbotGateway(sandbox, env);
    expect(result.id).toBe('gw-1');
  });

  it('throws GatewayStartupError when existing process exits before port is ready', async () => {
    const existingProcess = createFullMockProcess({
      id: 'existing-1',
      command: '/usr/local/bin/start-openclaw.sh',
      status: 'running',
    });

    // waitForPort never resolves; waitForExit resolves (crash)
    existingProcess.waitForPort = vi.fn().mockImplementation(() => new Promise(() => {}));
    existingProcess.waitForExit = vi.fn().mockResolvedValue({ exitCode: 2 });

    const { sandbox, listProcessesMock, readFileMock } = createMockSandbox();
    listProcessesMock.mockResolvedValue([existingProcess]);
    readFileMock.mockResolvedValue({ success: false, path: '', content: '' });

    const env = createMockEnv();

    await expect(ensureMoltbotGateway(sandbox, env)).rejects.toThrow(GatewayStartupError);
  });
});
