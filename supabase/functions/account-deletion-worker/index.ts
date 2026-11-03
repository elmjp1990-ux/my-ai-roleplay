import { createAuthAdminTimeoutFetch } from "../_shared/account-deletion-auth-fetch.ts";
import { withSupabase } from "npm:@supabase/server@1";
import {
  processAccountDeletionWorkItems,
  type AccountDeletionWorkItem,
} from "../_shared/account-deletion-worker.ts";

// Keep one account per invocation while the lease protocol is being measured.
const MAX_BATCH = 1;

// Fail-closed release gate: account deletion must not execute until the complete
// storage sweep, migration rollout, and hosted synthetic acceptance are approved.
const ACCOUNT_DELETION_EXECUTION_ENABLED = false;

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
  fetch: withSupabase({
    auth: "secret:default",
    // supabase-js routes Auth Admin through this fetch implementation.
    // Only /auth/v1/admin/users/* requests receive the 60-second abort bound;
    // database RPC requests keep the normal transport behavior.
    supabaseOptions: {
      global: {
        fetch: createAuthAdminTimeoutFetch(fetch, 60_000),
      },
    },
  }, async (request, ctx) => {
    if (request.method !== "POST") {
      return Response.json({ error: "method_not_allowed" }, { status: 405 });
    }

    // This endpoint is inert until all release gates are explicitly accepted.
    if (!ACCOUNT_DELETION_EXECUTION_ENABLED) {
      return Response.json({
        error: "account_deletion_worker_disabled",
        reason: "retention_and_authorization_release_gates_pending",
      }, { status: 503 });
    }

    const supabase = ctx.supabaseAdmin;
    if (!supabase) {
      return Response.json({ error: "worker_admin_context_missing" }, { status: 500 });
    }

    // The database performs the atomic claim and returns a fresh fencing token.
    // An invocation that receives no row does not record a failure for that work.
    const { data, error } = await supabase.rpc("claim_account_deletion_work_items", {
      p_limit: MAX_BATCH,
    });
    if (error) {
      return Response.json({
        error: "account_deletion_claim_failed",
        code: errorCode(error, "claim_failed"),
      }, { status: 500 });
    }

    const items = ((data ?? []) as AccountDeletionWorkItem[]).slice(0, MAX_BATCH);
    const summary = await processAccountDeletionWorkItems(items, {
      prepare: async (userId, token, generation) => {
        const result = await supabase.rpc("prepare_account_deletion_leased", {
          p_user_id: userId,
          p_lease_token: token,
          p_lease_generation: generation,
        });
        return { data: result.data, error: result.error };
      },
      renew: async (userId, token, generation) => {
        const result = await supabase.rpc("renew_account_deletion_lease", {
          p_user_id: userId,
          p_lease_token: token,
          p_lease_generation: generation,
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
        if (status === 404 || code === "user_not_found") return true;
        // An unavailable Auth lookup is not proof that the user is absent.
        throw lookupError;
      },
      finalize: async (userId, batchId, token, generation) => {
        const result = await supabase.rpc("finalize_account_deletion_leased", {
          p_user_id: userId,
          p_batch_id: batchId,
          p_lease_token: token,
          p_lease_generation: generation,
        });
        return { data: result.data, error: result.error };
      },
      markFailure: async (userId, batchId, token, generation, code) => {
        const result = await supabase.rpc("record_account_deletion_failure_leased", {
          p_user_id: userId,
          p_batch_id: batchId,
          p_lease_token: token,
          p_lease_generation: generation,
          p_error_code: code,
        });
        return { data: result.data, error: result.error };
      },
    });

    if (summary.failureReportFailed > 0) {
      // Do not log user IDs, batch IDs, lease tokens, or raw provider errors.
      console.error("account_deletion_worker_failure_reporting_incomplete", {
        failureReportFailed: summary.failureReportFailed,
        failed: summary.failed,
      });
    }

    return Response.json({
      ok: summary.failed === 0 && summary.failureReportFailed === 0,
      summary,
    }, { status: summary.failed === 0 && summary.failureReportFailed === 0 ? 200 : 207 });
  }),
};
