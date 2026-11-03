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

function thrownErrorCode(error: unknown, fallback: string): string {
  if (error && typeof error === "object" && "name" in error) {
    return safeErrorCode((error as { name?: unknown }).name, fallback);
  }
  return fallback;
}

/**
 * Processes only chat-memory photo jobs. Every job is isolated: a thrown
 * Storage/network or queue-RPC error must not abort the remaining batch.
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
      try {
        await deps.markJob(job.job_id, false, "storage_path_not_allowed");
      } catch {
        // The lease will expire and the queue can retry if failure reporting is unavailable.
      }
      summary.storage_failed += 1;
      continue;
    }

    let storageError: StorageError = null;
    try {
      const result = await deps.removeObject(ALLOWED_BUCKET, job.object_path);
      storageError = result.error ?? null;
    } catch (error) {
      storageError = { name: thrownErrorCode(error, "storage_delete_failed") };
    }

    let marked = false;
    let markError: unknown | null = null;
    const errorCode = storageError
      ? safeErrorCode(storageError.name || "storage_delete_failed", "storage_delete_failed")
      : null;
    try {
      const result = await deps.markJob(job.job_id, !storageError, errorCode);
      marked = result.data === true && !result.error;
      markError = result.error;
    } catch (error) {
      markError = error;
    }

    if (storageError || markError || !marked) {
      summary.storage_failed += 1;
    } else {
      summary.storage_deleted += 1;
    }
  }

  return summary;
}
