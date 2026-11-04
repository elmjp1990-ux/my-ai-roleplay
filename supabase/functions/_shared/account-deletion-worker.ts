export type AccountDeletionWorkItem = {
  target_user_id: string;
  batch_id: string | null;
  scheduled_for: string;
  work_status: string;
  lease_token: string;
  lease_generation: number;
  lease_expires_at: string;
};

type RpcResult<T> = { data: T | null; error: unknown | null };
type PreparedRow = { batch_id: string; target_user_id: string; batch_status: string };

export type AccountDeletionWorkerDeps = {
  prepare: (userId: string, token: string, generation: number) => Promise<RpcResult<PreparedRow[]>>;
  renew: (userId: string, token: string, generation: number) => Promise<RpcResult<boolean>>;
  deleteAuthUser: (userId: string) => Promise<{ error: unknown | null }>;
  isAuthUserAbsent: (userId: string) => Promise<boolean>;
  finalize: (userId: string, batchId: string, token: string, generation: number) => Promise<RpcResult<boolean>>;
  markFailure: (
    userId: string,
    batchId: string | null,
    token: string,
    generation: number,
    code: string,
  ) => Promise<RpcResult<boolean>>;
};

export type AccountDeletionWorkerSummary = {
  claimed: number;
  completed: number;
  failed: number;
  skipped: number;
  failureReportFailed: number;
};

function safeCode(value: unknown, fallback: string): string {
  if (typeof value === "string") {
    const cleaned = value.replace(/[^a-zA-Z0-9:_-]/g, "").slice(0, 100);
    return cleaned || fallback;
  }
  if (value && typeof value === "object" && "code" in value) {
    return safeCode((value as { code?: unknown }).code, fallback);
  }
  if (value && typeof value === "object" && "name" in value) {
    return safeCode((value as { name?: unknown }).name, fallback);
  }
  return fallback;
}

async function renewOrThrow(
  userId: string,
  token: string,
  generation: number,
  deps: AccountDeletionWorkerDeps,
): Promise<void> {
  const result = await deps.renew(userId, token, generation);
  if (result.error || result.data !== true) {
    throw result.error ?? new Error("account_deletion_lease_lost");
  }
}

export async function processAccountDeletionWorkItems(
  items: AccountDeletionWorkItem[],
  deps: AccountDeletionWorkerDeps,
): Promise<AccountDeletionWorkerSummary> {
  const summary: AccountDeletionWorkerSummary = {
    claimed: 0,
    completed: 0,
    failed: 0,
    skipped: 0,
    failureReportFailed: 0,
  };

  for (const item of items) {
    summary.claimed += 1;
    let batchId = item.batch_id;

    try {
      if (
        !item.target_user_id || !item.scheduled_for || !item.lease_token ||
        !Number.isSafeInteger(item.lease_generation) || item.lease_generation < 1
      ) {
        summary.skipped += 1;
        summary.failed += 1;
        continue;
      }

      // The fenced prepare RPC either performs the complete verified archive +
      // relational preparation, or resumes an already-deleting batch whose
      // request row has been cascaded away. It validates token + generation in
      // the same database transaction as the state mutation.
      const prepared = await deps.prepare(
        item.target_user_id,
        item.lease_token,
        item.lease_generation,
      );
      if (prepared.error || !prepared.data?.[0]?.batch_id) {
        throw prepared.error ?? new Error("prepared_batch_missing");
      }
      batchId = prepared.data[0].batch_id;
      if (prepared.data[0].batch_status !== "deleting") {
        if (prepared.data[0].batch_status === "completed") {
          await renewOrThrow(item.target_user_id, item.lease_token, item.lease_generation, deps);
          const completed = await deps.finalize(
            item.target_user_id,
            batchId,
            item.lease_token,
            item.lease_generation,
          );
          if (completed.error || completed.data !== true) {
            throw completed.error ?? new Error("completed_batch_finalize_not_confirmed");
          }
          summary.completed += 1;
          continue;
        }
        throw new Error("batch_not_in_deleting_state");
      }

      // Renew after the potentially long SQL preparation and immediately before
      // external Auth Admin work. A stale invocation cannot proceed after reclaim.
      await renewOrThrow(item.target_user_id, item.lease_token, item.lease_generation, deps);
      const authUserAbsent = await deps.isAuthUserAbsent(item.target_user_id);
      if (!authUserAbsent) {
        // Renew again after the lookup, immediately before the external side effect.
        await renewOrThrow(item.target_user_id, item.lease_token, item.lease_generation, deps);
        const deletion = await deps.deleteAuthUser(item.target_user_id);
        if (deletion.error) {
          const absentAfterError = await deps.isAuthUserAbsent(item.target_user_id);
          if (!absentAfterError) throw deletion.error;
        }
      }

      // If the Auth call outlived the lease, this renewal fails. A later owner
      // will reconcile Auth absence and finalize; this invocation cannot write.
      await renewOrThrow(item.target_user_id, item.lease_token, item.lease_generation, deps);
      const finalized = await deps.finalize(
        item.target_user_id,
        batchId,
        item.lease_token,
        item.lease_generation,
      );
      if (finalized.error || finalized.data !== true) {
        throw finalized.error ?? new Error("finalize_not_confirmed");
      }
      summary.completed += 1;
    } catch (error) {
      summary.failed += 1;
      try {
        const report = await deps.markFailure(
          item.target_user_id,
          batchId,
          item.lease_token,
          item.lease_generation,
          safeCode(error, "account_deletion_worker_failed"),
        );
        if (report.error || report.data !== true) {
          summary.failureReportFailed += 1;
        }
      } catch {
        summary.failureReportFailed += 1;
      }
    }
  }

  return summary;
}
