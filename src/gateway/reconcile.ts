/**
 * Cron job reconciliation logic for the R2 ↔ Git bidirectional sync system.
 *
 * 背景: moltworker のコンテナ再起動時、R2 から復元された cron ジョブ設定と
 * git で管理された設定をマージする必要がある。これにより:
 * - git で管理した設定変更（wakeMode: "now" への修正等）が確実にコンテナに反映される
 * - R2 に保存されたランタイム状態（lastRunAtMs, nextRunAtMs）は失われない
 * - ユーザーがチャットで追加したジョブ（R2のみに存在）も保持される
 *
 * このモジュールは start-openclaw.sh の reconcile セクションで inline Node script として
 * 同等のロジックが実行される。テスト可能にするために TypeScript モジュールとして抽出した。
 */

import { randomUUID } from 'node:crypto';

/**
 * Cron job definition as stored in OpenClaw's jobs.json.
 * Only the fields relevant to reconciliation are typed here.
 */
export interface CronJob {
  id: string;
  agentId: string;
  name: string;
  enabled: boolean;
  createdAtMs: number;
  updatedAtMs: number;
  schedule: { kind: string; expr?: string; everyMs?: number };
  sessionTarget: string;
  wakeMode: string;
  payload: Record<string, unknown>;
  delivery?: Record<string, unknown>;
  state?: Record<string, unknown>;
}

/**
 * Git-managed cron job definition (simplified format for human editing).
 */
export interface GitCronJob {
  name: string;
  agentId?: string;
  enabled?: boolean;
  schedule: { kind: string; expr?: string; everyMs?: number };
  sessionTarget: string;
  wakeMode: string;
  payload: Record<string, unknown>;
  delivery?: Record<string, unknown>;
}

/**
 * Reconcile git-managed cron jobs with runtime (R2-restored) cron jobs.
 *
 * Merge strategy:
 * - Same name: git settings (schedule, wakeMode, payload, delivery) win,
 *   but R2 state (lastRunAtMs, nextRunAtMs) and id are preserved.
 * - Git only: added as new job with generated id.
 * - R2 only: kept as-is (user-created at runtime).
 */
export function reconcileCronJobs(gitJobs: GitCronJob[], runtimeJobs: CronJob[]): CronJob[] {
  const gitByName = new Map(gitJobs.map((j) => [j.name, j]));
  const merged: CronJob[] = [];
  const seen = new Set<string>();

  // Process runtime jobs first: update matching ones, keep unmanaged ones
  for (const rj of runtimeJobs) {
    const gj = gitByName.get(rj.name);
    if (gj) {
      merged.push({
        ...rj,
        // Git-managed fields override
        agentId: gj.agentId ?? rj.agentId,
        enabled: gj.enabled ?? rj.enabled,
        schedule: gj.schedule,
        sessionTarget: gj.sessionTarget,
        wakeMode: gj.wakeMode,
        payload: gj.payload,
        delivery: gj.delivery ?? rj.delivery,
        updatedAtMs: Date.now(),
        // Preserve runtime state (id, createdAtMs, state)
      });
      seen.add(rj.name);
    } else {
      // R2 only: keep as-is
      merged.push(rj);
    }
  }

  // Add git-only jobs (not in R2)
  for (const [name, gj] of gitByName) {
    if (!seen.has(name)) {
      const now = Date.now();
      merged.push({
        id: randomUUID(),
        agentId: gj.agentId ?? 'main',
        name: gj.name,
        enabled: gj.enabled ?? true,
        createdAtMs: now,
        updatedAtMs: now,
        schedule: gj.schedule,
        sessionTarget: gj.sessionTarget,
        wakeMode: gj.wakeMode,
        payload: gj.payload,
        delivery: gj.delivery,
        state: {},
      });
    }
  }

  return merged;
}
