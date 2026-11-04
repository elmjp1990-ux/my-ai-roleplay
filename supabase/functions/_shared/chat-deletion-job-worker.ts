export type ChatDeletionJob = {
  job_id: string;
};

export type ChatDeletionSummary = {
  chat_claimed: number;
  chat_purged: number;
  chat_failed: number;
};

export type ChatDeletionWorkerDependencies = {
  purgeJob: (
    jobId: string,
  ) => Promise<{ data: boolean | null; error: unknown | null }>;
  markFailed: (
    jobId: string,
    errorCode: string,
  ) => Promise<{ data: boolean | null; error: unknown | null }>;
};

function safeErrorCode(value: unknown, fallback: string): string {
  const raw = typeof value === "string" ? value : fallback;
  const cleaned = raw.replace(/[^a-zA-Z0-9:_-]/g, "").slice(0, 100);
  return cleaned || fallback;
}

function failureCode(error: unknown, fallback: string): string {
  if (error && typeof error === "object") {
    if ("code" in error) {
      return safeErrorCode((error as { code?: unknown }).code, fallback);
    }
    if ("name" in error) {
      return safeErrorCode((error as { name?: unknown }).name, fallback);
    }
  }
  return fallback;
}

/**
 * Processes each claimed relational chat deletion independently.
 * A thrown purge or failure-reporting RPC must not abort later jobs.
 * If failure reporting is unavailable, the queue lease expires and retries.
 */
export async function processChatDeletionJobs(
  jobs: ChatDeletionJob[],
  deps: ChatDeletionWorkerDependencies,
): Promise<ChatDeletionSummary> {
  const summary: ChatDeletionSummary = {
    chat_claimed: 0,
    chat_purged: 0,
    chat_failed: 0,
  };

  for (const job of jobs) {
    summary.chat_claimed += 1;

    let purged: boolean | null = null;
    let purgeError: unknown | null = null;
    try {
      const result = await deps.purgeJob(job.job_id);
      purged = result.data;
      purgeError = result.error;
    } catch (error) {
      purgeError = error;
    }

    if (purgeError || purged !== true) {
      summary.chat_failed += 1;
      const code = failureCode(
        purgeError,
        purged === false ? "purge_not_completed" : "purge_failed",
      );
      try {
        await deps.markFailed(job.job_id, code);
      } catch {
        // Leave the lease to expire; the queue claim RPC will retry this job.
      }
      continue;
    }

    summary.chat_purged += 1;
  }

  return summary;
}
