export type StorageDeletionJob = {
  job_id: string;
  bucket_id?: string;
  object_path?: string;
};

export type StorageWorkerSummary = {
  storage_claimed: number;
  storage_deleted: number;
  storage_failed: number;
};

type StorageError = { name?: string } | null | undefined;

export type StorageWorkerDependencies = {
  removeObject: (
    bucketId: string,
    objectPath: string,
  ) => Promise<{ error?: StorageError }>;
  markJob: (
    jobId: string,
    success: boolean,
    errorCode: string | null,
  ) => Promise<{ data: boolean | null; error: unknown | null }>;
};

const ALLOWED_BUCKET = "personax-memory-photos";

function safeErrorCode(value: unknown, fallback: string): string {
  const raw = typeof value === "string" ? value : fallback;
  const cleaned = raw.replace(/[^a-zA-Z0-9:_-]/g, "").slice(0, 100);
  return cleaned || fallback;
}

/**
 * Processes only chat-memory photo jobs. The injected adapters make failure
 * handling deterministic in tests without changing Supabase-managed Storage.
 */
export async function processStorageDeletionJobs(
  jobs: StorageDeletionJob[],
  deps: StorageWorkerDependencies,
): Promise<StorageWorkerSummary> {
  const summary: StorageWorkerSummary = {
    storage_claimed: 0,
    storage_deleted: 0,
    storage_failed: 0,
  };

  for (const job of jobs) {
    summary.storage_claimed += 1;

    if (job.bucket_id !== ALLOWED_BUCKET || !job.object_path) {
      summary.storage_failed += 1;
      await deps.markJob(job.job_id, false, "storage_path_not_allowed");
      continue;
    }

    const { error } = await deps.removeObject(ALLOWED_BUCKET, job.object_path);
    const { data: marked, error: markError } = await deps.markJob(
      job.job_id,
      !error,
      error
        ? safeErrorCode(error.name || "storage_delete_failed", "storage_delete_failed")
        : null,
    );

    if (error || markError || marked !== true) {
      summary.storage_failed += 1;
    } else {
      summary.storage_deleted += 1;
    }
  }

  return summary;
}
