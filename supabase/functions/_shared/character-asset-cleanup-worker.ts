export type CharacterAssetCleanupJob = {
  id: string;
  bucket_id: string;
  object_path: string;
  owner_id: string;
  character_id: string;
};

export type CharacterAssetCleanupStatus = "completed" | "skipped" | "failed";

type Result = { error: unknown | null };
type ReferenceResult = { referenced: boolean; error: unknown | null };

export type CharacterAssetCleanupDeps = {
  isReferenced: (bucketId: string, objectPath: string) => Promise<ReferenceResult>;
  removeObject: (bucketId: string, objectPath: string) => Promise<Result>;
  markJob: (
    jobId: string,
    status: CharacterAssetCleanupStatus,
    errorCode?: string,
  ) => Promise<Result>;
};

export type CharacterAssetCleanupSummary = {
  claimed: number;
  deleted: number;
  skipped: number;
  failed: number;
  report_failed: number;
};

const ALLOWED_BUCKETS = new Set([
  "character-illustrations",
  "character-avatar-videos",
]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isSafeCharacterAssetJob(job: CharacterAssetCleanupJob): boolean {
  if (!ALLOWED_BUCKETS.has(job.bucket_id)) return false;
  if (!UUID.test(job.owner_id) || !UUID.test(job.character_id)) return false;
  const prefix = `${job.owner_id}/${job.character_id}/`;
  if (!job.object_path.startsWith(prefix)) return false;
  const filename = job.object_path.slice(prefix.length);
  return filename.length > 0 && !filename.includes("/") &&
    filename !== "." && filename !== "..";
}

function safeErrorCode(error: unknown): string {
  const raw = error && typeof error === "object" && "code" in error
    ? String((error as { code?: unknown }).code ?? "cleanup_failed")
    : error instanceof Error ? error.name : "cleanup_failed";
  return raw.replace(/[^a-zA-Z0-9:_-]/g, "").slice(0, 100) || "cleanup_failed";
}

export async function processCharacterAssetCleanupJobs(
  jobs: CharacterAssetCleanupJob[],
  deps: CharacterAssetCleanupDeps,
): Promise<CharacterAssetCleanupSummary> {
  const summary: CharacterAssetCleanupSummary = {
    claimed: 0,
    deleted: 0,
    skipped: 0,
    failed: 0,
    report_failed: 0,
  };

  for (const job of jobs) {
    summary.claimed += 1;
    try {
      if (!isSafeCharacterAssetJob(job)) {
        const marked = await deps.markJob(job.id, "skipped", "unsafe_asset_path");
        if (marked.error) summary.report_failed += 1;
        summary.skipped += 1;
        continue;
      }

      const reference = await deps.isReferenced(job.bucket_id, job.object_path);
      if (reference.error) throw reference.error;
      if (reference.referenced) {
        const marked = await deps.markJob(job.id, "skipped", "asset_still_referenced");
        if (marked.error) summary.report_failed += 1;
        summary.skipped += 1;
        continue;
      }

      const removed = await deps.removeObject(job.bucket_id, job.object_path);
      if (removed.error) throw removed.error;

      const marked = await deps.markJob(job.id, "completed");
      if (marked.error) {
        // Storage removal is idempotent; the job can safely retry and confirm
        // the object is already absent on the next pass.
        summary.failed += 1;
        summary.report_failed += 1;
        continue;
      }
      summary.deleted += 1;
    } catch (error) {
      summary.failed += 1;
      try {
        const marked = await deps.markJob(job.id, "failed", safeErrorCode(error));
        if (marked.error) summary.report_failed += 1;
      } catch {
        summary.report_failed += 1;
      }
    }
  }
  return summary;
}
