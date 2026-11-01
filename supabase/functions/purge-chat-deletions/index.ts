import { withSupabase } from "npm:@supabase/server@1";

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
      const { error } = await supabase.rpc("purge_chat_deletion_job", {
        p_job_id: job.job_id,
      });

      if (error) {
        summary.chat_failed += 1;
        await supabase.rpc("mark_chat_deletion_job_failed", {
          p_job_id: job.job_id,
          p_error_code: safeErrorCode(error.code, "purge_failed"),
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

    for (const job of (storageJobs ?? []) as Job[]) {
      summary.storage_claimed += 1;

      if (job.bucket_id !== ALLOWED_BUCKET || !job.object_path) {
        summary.storage_failed += 1;
        await supabase.rpc("mark_chat_storage_deletion_job", {
          p_job_id: job.job_id,
          p_success: false,
          p_error_code: "storage_path_not_allowed",
        });
        continue;
      }

      const { error } = await supabase.storage
        .from(ALLOWED_BUCKET)
        .remove([job.object_path]);

      const { error: markError } = await supabase.rpc(
        "mark_chat_storage_deletion_job",
        {
          p_job_id: job.job_id,
          p_success: !error,
          p_error_code: error
            ? safeErrorCode(error.name || "storage_delete_failed", "storage_delete_failed")
            : null,
        },
      );

      if (error || markError) {
        summary.storage_failed += 1;
      } else {
        summary.storage_deleted += 1;
      }
    }

    return Response.json({ ok: true, summary });
  }),
};
