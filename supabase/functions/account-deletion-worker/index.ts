// Internal account-deletion worker.
// Invoke only with the Supabase service-role credential. Do not expose this endpoint to clients.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

const isNotFound = (error: { status?: number; message?: string } | null) =>
  Boolean(error && (
    error.status === 404 ||
    /user.*not found|not found.*user|user does not exist/i.test(error.message || "")
  ));

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ error: "server_not_configured" }, 503);
  }

  // Gateway JWT validation is enabled by default; this additional exact-key check
  // prevents an ordinary authenticated user from invoking the privileged worker.
  if (request.headers.get("Authorization") !== `Bearer ${serviceRoleKey}`) {
    return json({ error: "unauthorized" }, 401);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: workItems, error: workError } = await admin.rpc("get_account_deletion_work_items");
  if (workError) return json({ error: "work_queue_unavailable" }, 503);

  const summary = { inspected: 0, completed: 0, retried: 0, failed: 0 };
  const items = Array.isArray(workItems) ? workItems : [];

  for (const item of items) {
    summary.inspected += 1;
    const userId = item?.target_user_id;
    const existingBatchId = item?.batch_id;
    if (typeof userId !== "string") {
      summary.failed += 1;
      continue;
    }

    let batchId: string | null = typeof existingBatchId === "string" ? existingBatchId : null;
    try {
      // A previous run may have deleted Auth successfully but crashed before finalizing.
      const { data: userData, error: userLookupError } = await admin.auth.admin.getUserById(userId);
      if (userLookupError && !isNotFound(userLookupError)) {
        throw new Error("auth_lookup_failed");
      }

      if (userLookupError && isNotFound(userLookupError)) {
        if (!batchId || item?.work_status !== "deleting") {
          // Missing Auth without a committed deleting batch is inconsistent; never guess.
          throw new Error("auth_user_missing_before_deleting_state");
        }
        const { error: finalizeMissingError } = await admin.rpc("finalize_account_deletion", {
          p_batch_id: batchId,
        });
        if (finalizeMissingError) throw new Error("finalize_after_auth_delete_failed");
        summary.completed += 1;
        continue;
      }

      if (!userData?.user) throw new Error("auth_lookup_empty");

      if (item?.work_status === "deleting") {
        // A committed deleting batch means the SQL cleanup transaction already finished.
        // This also recovers if its request row was removed before the worker retried.
        if (!batchId) throw new Error("deleting_batch_id_missing");
      } else {
        // This transaction verifies/reuses the archive, marks the batch deleting,
        // and removes non-cascading references. It does not delete auth.users.
        const { data: prepared, error: prepareError } = await admin.rpc("prepare_account_deletion", {
          p_user_id: userId,
        });
        if (prepareError) throw new Error("prepare_deletion_failed");
        const preparedRow = Array.isArray(prepared) ? prepared[0] : prepared;
        if (!preparedRow?.batch_id || preparedRow?.batch_status !== "deleting") {
          throw new Error("deletion_state_not_confirmed");
        }
        batchId = preparedRow.batch_id;
      }

      const { error: deleteError } = await admin.auth.admin.deleteUser(userId);
      if (deleteError) {
        // Delete may have succeeded despite a lost response; verify before reporting failure.
        const { data: verifyUser, error: verifyError } = await admin.auth.admin.getUserById(userId);
        if (verifyError && isNotFound(verifyError)) {
          const { error: finalizeError } = await admin.rpc("finalize_account_deletion", {
            p_batch_id: batchId,
          });
          if (finalizeError) throw new Error("finalize_after_ambiguous_auth_delete_failed");
          summary.completed += 1;
          continue;
        }

        // Only an explicit user record proves deletion did not happen. A lookup error,
        // empty response, or missing user without a recognized not-found error is ambiguous.
        if (verifyError) throw new Error("auth_delete_verification_failed");
        if (!verifyUser?.user) throw new Error("auth_delete_verification_ambiguous");
        throw new Error("auth_delete_failed");
      }

      const { error: finalizeError } = await admin.rpc("finalize_account_deletion", {
        p_batch_id: batchId,
      });
      if (finalizeError) throw new Error("finalize_deletion_failed");
      summary.completed += 1;
      if (item?.work_status === "deleting") summary.retried += 1;
    } catch (error) {
      summary.failed += 1;
      // Store only a stable, non-sensitive error code; never persist raw provider messages.
      if (batchId) {
        await admin.rpc("record_account_deletion_failure", {
          p_batch_id: batchId,
          p_error_code: error instanceof Error ? error.message : "worker_error",
        });
      }
    }
  }

  return json({ ok: summary.failed === 0, ...summary }, summary.failed === 0 ? 200 : 207);
});
