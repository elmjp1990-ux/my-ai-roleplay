import { withSupabase } from "npm:@supabase/server@1";
import {
  processCharacterAssetCleanupJobs,
  type CharacterAssetCleanupJob,
} from "../_shared/character-asset-cleanup-worker.ts";

const BATCH_SIZE = 50;

export default {
  fetch: withSupabase({ auth: "secret:default" }, async (request, ctx) => {
    if (request.method !== "POST") {
      return Response.json({ error: "method_not_allowed" }, { status: 405 });
    }
    const supabase = ctx.supabaseAdmin;
    if (!supabase) {
      return Response.json({ error: "worker_admin_context_missing" }, { status: 500 });
    }

    const { data, error } = await supabase.rpc("claim_character_asset_cleanup_jobs", {
      p_limit: BATCH_SIZE,
    });
    if (error) {
      return Response.json({ error: "character_asset_claim_failed", code: error.code ?? "claim_failed" }, { status: 500 });
    }

    const summary = await processCharacterAssetCleanupJobs(
      (data ?? []) as CharacterAssetCleanupJob[],
      {
        isReferenced: async (bucketId, objectPath) => {
          if (bucketId === "character-avatar-videos") {
            const { data: rows, error: queryError } = await supabase
              .from("characters")
              .select("id")
              .eq("avatar_video_path", objectPath)
              .limit(1);
            return { referenced: (rows?.length ?? 0) > 0, error: queryError };
          }
          if (bucketId === "character-illustrations") {
            const { data: rows, error: queryError } = await supabase
              .from("character_illustrations")
              .select("id")
              .eq("storage_path", objectPath)
              .limit(1);
            return { referenced: (rows?.length ?? 0) > 0, error: queryError };
          }
          return { referenced: true, error: new Error("unsupported_bucket") };
        },
        removeObject: async (bucketId, objectPath) => {
          const { error: removeError } = await supabase.storage.from(bucketId).remove([objectPath]);
          return { error: removeError };
        },
        markJob: async (jobId, status, errorCode) => {
          const { error: markError } = await supabase.rpc("finish_character_asset_cleanup_job", {
            p_job_id: jobId,
            p_status: status,
            p_error: errorCode ?? null,
          });
          return { error: markError };
        },
      },
    );
    return Response.json({ ok: true, summary });
  }),
};
