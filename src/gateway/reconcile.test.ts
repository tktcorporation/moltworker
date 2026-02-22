import { describe, it, expect, vi, beforeEach } from 'vitest';
import { reconcileCronJobs } from './reconcile';
import type { CronJob, GitCronJob } from './reconcile';

// Mock crypto.randomUUID for deterministic tests
vi.mock('node:crypto', () => ({
  randomUUID: () => 'test-uuid-1234',
}));

function makeRuntimeJob(overrides: Partial<CronJob> = {}): CronJob {
  return {
    id: 'existing-id',
    agentId: 'main',
    name: 'test-job',
    enabled: true,
    createdAtMs: 1000,
    updatedAtMs: 2000,
    schedule: { kind: 'cron', expr: '0 * * * *' },
    sessionTarget: 'isolated',
    wakeMode: 'next-heartbeat',
    payload: { kind: 'agentTurn', message: 'old message' },
    delivery: { channel: 'discord', mode: 'announce' },
    state: { nextRunAtMs: 9999, lastRunAtMs: 5000 },
    ...overrides,
  };
}

function makeGitJob(overrides: Partial<GitCronJob> = {}): GitCronJob {
  return {
    name: 'test-job',
    schedule: { kind: 'cron', expr: '0 * * * *' },
    sessionTarget: 'isolated',
    wakeMode: 'now',
    payload: { kind: 'agentTurn', message: 'new message' },
    delivery: { channel: 'discord', mode: 'announce' },
    ...overrides,
  };
}

describe('reconcileCronJobs', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-02-22T08:00:00Z'));
  });

  it('keeps R2-only jobs as-is', () => {
    const runtimeJobs = [makeRuntimeJob({ name: 'user-created-job' })];
    const gitJobs: GitCronJob[] = [];

    const result = reconcileCronJobs(gitJobs, runtimeJobs);

    expect(result).toHaveLength(1);
    expect(result[0].name).toBe('user-created-job');
    expect(result[0].wakeMode).toBe('next-heartbeat');
    expect(result[0].id).toBe('existing-id');
  });

  it('adds git-only jobs as new', () => {
    const runtimeJobs: CronJob[] = [];
    const gitJobs = [makeGitJob({ name: 'new-git-job' })];

    const result = reconcileCronJobs(gitJobs, runtimeJobs);

    expect(result).toHaveLength(1);
    expect(result[0].name).toBe('new-git-job');
    expect(result[0].wakeMode).toBe('now');
    expect(result[0].id).toBe('test-uuid-1234');
    expect(result[0].agentId).toBe('main');
    expect(result[0].enabled).toBe(true);
  });

  it('merges same-name jobs: git settings win, R2 state preserved', () => {
    const runtimeJobs = [
      makeRuntimeJob({
        name: 'hourly-check',
        wakeMode: 'next-heartbeat',
        payload: { kind: 'agentTurn', message: 'old' },
        state: { nextRunAtMs: 9999, lastRunAtMs: 5000 },
      }),
    ];
    const gitJobs = [
      makeGitJob({
        name: 'hourly-check',
        wakeMode: 'now',
        payload: { kind: 'agentTurn', message: 'updated' },
      }),
    ];

    const result = reconcileCronJobs(gitJobs, runtimeJobs);

    expect(result).toHaveLength(1);
    // Git settings win
    expect(result[0].wakeMode).toBe('now');
    expect(result[0].payload).toEqual({ kind: 'agentTurn', message: 'updated' });
    // R2 state preserved
    expect(result[0].state).toEqual({ nextRunAtMs: 9999, lastRunAtMs: 5000 });
    expect(result[0].id).toBe('existing-id');
    expect(result[0].createdAtMs).toBe(1000);
  });

  it('handles mix of git-only, R2-only, and matching jobs', () => {
    const runtimeJobs = [
      makeRuntimeJob({ name: 'shared-job', wakeMode: 'next-heartbeat' }),
      makeRuntimeJob({ name: 'user-job', id: 'user-id' }),
    ];
    const gitJobs = [
      makeGitJob({ name: 'shared-job', wakeMode: 'now' }),
      makeGitJob({ name: 'new-job' }),
    ];

    const result = reconcileCronJobs(gitJobs, runtimeJobs);

    expect(result).toHaveLength(3);

    const shared = result.find((j) => j.name === 'shared-job');
    expect(shared?.wakeMode).toBe('now');
    expect(shared?.id).toBe('existing-id');

    const user = result.find((j) => j.name === 'user-job');
    expect(user?.wakeMode).toBe('next-heartbeat');
    expect(user?.id).toBe('user-id');

    const newJob = result.find((j) => j.name === 'new-job');
    expect(newJob?.wakeMode).toBe('now');
    expect(newJob?.id).toBe('test-uuid-1234');
  });

  it('git wakeMode always overrides R2 wakeMode', () => {
    const runtimeJobs = [makeRuntimeJob({ name: 'job', wakeMode: 'next-heartbeat' })];
    const gitJobs = [makeGitJob({ name: 'job', wakeMode: 'now' })];

    const result = reconcileCronJobs(gitJobs, runtimeJobs);

    expect(result[0].wakeMode).toBe('now');
  });

  it('preserves git schedule over R2 schedule', () => {
    const runtimeJobs = [makeRuntimeJob({ name: 'job', schedule: { kind: 'cron', expr: '0 * * * *' } })];
    const gitJobs = [makeGitJob({ name: 'job', schedule: { kind: 'cron', expr: '*/30 * * * *' } })];

    const result = reconcileCronJobs(gitJobs, runtimeJobs);

    expect(result[0].schedule.expr).toBe('*/30 * * * *');
  });

  it('defaults agentId to main for git-only jobs', () => {
    const result = reconcileCronJobs([makeGitJob()], []);

    expect(result[0].agentId).toBe('main');
  });

  it('allows git to override agentId', () => {
    const runtimeJobs = [makeRuntimeJob({ name: 'job', agentId: 'main' })];
    const gitJobs = [makeGitJob({ name: 'job', agentId: 'secondary' })];

    const result = reconcileCronJobs(gitJobs, runtimeJobs);

    expect(result[0].agentId).toBe('secondary');
  });
});
