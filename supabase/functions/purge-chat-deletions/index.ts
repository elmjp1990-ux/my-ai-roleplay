import { withSupabase } from "npm:@supabase/server@1";
import { processStorageDeletionJobs } from "../_shared/chat-deletion-worker.ts";

type Job = {
  job_id: string;
  resource_type?: string;
  resource_id?: string;
  owner_id?: string;
  bucket_id?: string;
  object_path?: string;
};

const MAX_CHAT_BATCH = 10;
const MAX_STORAGE_BATCH = 50;
const ALLOWED_BUCKET = "personax-memory-photos";

function safeErrorCode(value: unknown, fallback: string): string {
  const raw = typeof value === "string" ? value : fallback;
  const cleaned = raw.replace(/[^a-zA-Z0-9:_-]/g, "").slice(0, 100);
  return cleaned || fallback;
}

export default {
  fetch: withSupabase({ auth: "secret:default" }, async (request, ctx) => {
    if (request.method !== "POST") {
      return Response.json({ error: "method_not_allowed" }, { status: 405 });
    }

    // Supabase validates the named Secret Key before this handler runs.
    // This service-only worker intentionally uses the admin client for its
    // restricted queue RPCs and the chat-memory Storage bucket.
    const supabase = ctx.supabaseAdmin;
    if (!supabase) {
      return Response.json({ error: "worker_admin_context_missing" }, { status: 500 });
    }

    const summary = {
      chat_claimed: 0,
      chat_purged: 0,
      chat_failed: 0,
      storage_claimed: 0,
      storage_deleted: 0,
      storage_failed: 0,
    };

    const { data: chatJobs, error: chatClaimError } = await supabase.rpc(
      "claim_chat_deletion_jobs",
      { p_limit: MAX_CHAT_BATCH },
    );

    if (chatClaimError) {
      return Response.json({
        error: "chat_job_claim_failed",
        code: safeErrorCode(chatClaimError.code, "claim_failed"),
        summary,
      }, { status: 500 });
    }

    for (const job of (chatJobs ?? []) as Job[]) {
      summary.chat_claimed += 1;
      const { data: purged, error } = await supabase.rpc("purge_chat_deletion_job", {
        p_job_id: job.job_id,
      });

      if (error || purged !== true) {
        summary.chat_failed += 1;
        await supabase.rpc("mark_chat_deletion_job_failed", {
          p_job_id: job.job_id,
          p_error_code: safeErrorCode(error?.code, purged === false ? "purge_not_completed" : "purge_failed"),
        });
      } else {
        summary.chat_purged += 1;
      }
    }

    const { data: storageJobs, error: storageClaimError } = await supabase.rpc(
      "claim_chat_storage_deletion_jobs",
      { p_limit: MAX_STORAGE_BATCH },
    );

    if (storageClaimError) {
      return Response.json({
        error: "storage_job_claim_failed",
        code: safeErrorCode(storageClaimError.code, "claim_failed"),
        summary,
      }, { status: 500 });
    }

    const storageSummary = await processStorageDeletionJobs(
      (storageJobs ?? []) as Job[],
      {
        removeObject: async (bucketId, objectPath) => {
          const { error } = await supabase.storage.from(bucketId).remove([objectPath]);
          return { error };
        },
        markJob: async (jobId, success, errorCode) => {
          const { data, error } = await supabase.rpc(
            "mark_chat_storage_deletion_job",
            {
              p_job_id: jobId,
              p_success: success,
              p_error_code: errorCode,
            },
          );
          return { data, error };
        },
      },
    );
    summary.storage_claimed = storageSummary.storage_claimed;
    summary.storage_deleted = storageSummary.storage_deleted;
    summary.storage_failed = storageSummary.storage_failed;

    return Response.json({ ok: true, summary });
  }),
};
