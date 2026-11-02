export type AccountDeletionWorkItem = {
  target_user_id: string;
  batch_id: string | null;
  scheduled_for: string;
  work_status: string;
};

type RpcResult<T> = { data: T | null; error: unknown | null };
type ArchiveRow = { batch_id: string; target_user_id: string; batch_status: string };
type PreparedRow = { batch_id: string; target_user_id: string; batch_status: string };

export type AccountDeletionWorkerDeps = {
  archive: (userId: string) => Promise<RpcResult<ArchiveRow[]>>;
  prepare: (userId: string) => Promise<RpcResult<PreparedRow[]>>;
  deleteAuthUser: (userId: string) => Promise<{ error: unknown | null }>;
  isAuthUserAbsent: (userId: string) => Promise<boolean>;
  finalize: (batchId: string) => Promise<RpcResult<boolean>>;
  markFailure: (batchId: string, code: string) => Promise<RpcResult<boolean>>;
};

export type AccountDeletionWorkerSummary = {
  claimed: number;
  completed: number;
  failed: number;
  skipped: number;
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

export async function processAccountDeletionWorkItems(
  items: AccountDeletionWorkItem[],
  deps: AccountDeletionWorkerDeps,
): Promise<AccountDeletionWorkerSummary> {
  const summary: AccountDeletionWorkerSummary = {
    claimed: 0,
    completed: 0,
    failed: 0,
    skipped: 0,
  };

  for (const item of items) {
    summary.claimed += 1;
    let batchId = item.batch_id;

    try {
      if (!item.target_user_id || !item.scheduled_for) {
        summary.skipped += 1;
        summary.failed += 1;
        continue;
      }

      const archived = await deps.archive(item.target_user_id);
      if (archived.error || !archived.data?.[0]?.batch_id) {
        throw archived.error ?? new Error("archive_batch_missing");
      }
      batchId = archived.data[0].batch_id;
      const archiveStatus = archived.data[0].batch_status;
      if (!["archived", "deleting", "completed"].includes(archiveStatus)) {
        throw new Error("archive_status_not_ready");
      }

      if (archiveStatus === "completed") {
        summary.skipped += 1;
        continue;
      }

      const prepared = await deps.prepare(item.target_user_id);
      if (prepared.error || !prepared.data?.[0]?.batch_id) {
        throw prepared.error ?? new Error("prepared_batch_missing");
      }
      batchId = prepared.data[0].batch_id;
      if (prepared.data[0].batch_status !== "deleting") {
        throw new Error("batch_not_in_deleting_state");
      }

      const deletion = await deps.deleteAuthUser(item.target_user_id);
      if (deletion.error) {
        // A retry may arrive after Auth deletion succeeded but before finalize committed.
        // Treat only a positively verified missing Auth user as idempotent success.
        const absent = await deps.isAuthUserAbsent(item.target_user_id);
        if (!absent) throw deletion.error;
      }

      const finalized = await deps.finalize(batchId);
      if (finalized.error || finalized.data !== true) {
        throw finalized.error ?? new Error("finalize_not_confirmed");
      }
      summary.completed += 1;
    } catch (error) {
      summary.failed += 1;
      if (batchId) {
        await deps.markFailure(batchId, safeCode(error, "account_deletion_worker_failed"));
      }
    }
  }

  return summary;
}
