import { withSupabase } from "npm:@supabase/server@1";
import {
  processAccountDeletionWorkItems,
  type AccountDeletionWorkItem,
} from "../_shared/account-deletion-worker.ts";

const MAX_BATCH = 10;

function errorCode(error: unknown, fallback: string): string {
  if (error && typeof error === "object" && "code" in error) {
    const code = (error as { code?: unknown }).code;
    if (typeof code === "string" && code.length > 0) {
      return code.replace(/[^a-zA-Z0-9:_-]/g, "").slice(0, 100) || fallback;
    }
  }
  if (error && typeof error === "object" && "name" in error) {
    const name = (error as { name?: unknown }).name;
    if (typeof name === "string" && name.length > 0) {
      return name.replace(/[^a-zA-Z0-9:_-]/g, "").slice(0, 100) || fallback;
    }
  }
  return fallback;
}

export default {
  fetch: withSupabase({ auth: "secret:default" }, async (request, ctx) => {
    if (request.method !== "POST") {
      return Response.json({ error: "method_not_allowed" }, { status: 405 });
    }

    // The named Supabase Secret Key is validated by @supabase/server before
    // this handler executes. Never accept a target user ID from request input.
    const supabase = ctx.supabaseAdmin;
    if (!supabase) {
      return Response.json({ error: "worker_admin_context_missing" }, { status: 500 });
    }

    const { data, error } = await supabase.rpc("get_account_deletion_work_items");
    if (error) {
      return Response.json({
        error: "account_deletion_work_items_failed",
        code: errorCode(error, "work_items_failed"),
      }, { status: 500 });
    }

    const items = ((data ?? []) as AccountDeletionWorkItem[]).slice(0, MAX_BATCH);
    const summary = await processAccountDeletionWorkItems(items, {
      archive: async (userId) => {
        const result = await supabase.rpc("archive_account_deletion_data", {
          p_user_id: userId,
        });
        return { data: result.data, error: result.error };
      },
      prepare: async (userId) => {
        const result = await supabase.rpc("prepare_account_deletion", {
          p_user_id: userId,
        });
        return { data: result.data, error: result.error };
      },
      deleteAuthUser: async (userId) => {
        const { error: deleteError } = await supabase.auth.admin.deleteUser(userId);
        return { error: deleteError };
      },
      isAuthUserAbsent: async (userId) => {
        const { data: userData, error: lookupError } = await supabase.auth.admin.getUserById(userId);
        if (!lookupError) return userData.user === null;
        const status = "status" in lookupError
          ? (lookupError as { status?: unknown }).status
          : undefined;
        const code = "code" in lookupError
          ? (lookupError as { code?: unknown }).code
          : undefined;
        return status === 404 || code === "user_not_found";
      },
      finalize: async (batchId) => {
        const result = await supabase.rpc("finalize_account_deletion", {
          p_batch_id: batchId,
        });
        return { data: result.data, error: result.error };
      },
      markFailure: async (batchId, code) => {
        const result = await supabase.rpc("record_account_deletion_failure", {
          p_batch_id: batchId,
          p_error_code: code,
        });
        return { data: result.data, error: result.error };
      },
    });

    return Response.json({
      ok: summary.failed === 0,
      summary,
    }, { status: summary.failed === 0 ? 200 : 207 });
  }),
};
