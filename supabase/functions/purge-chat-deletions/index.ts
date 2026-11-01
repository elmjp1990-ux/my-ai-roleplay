import { createClient } from "npm:@supabase/supabase-js@2";

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

function jwtRole(request: Request): string | null {
  const header = request.headers.get("authorization") ?? "";
  const token = header.replace(/^Bearer\s+/i, "");
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const payload = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = payload.padEnd(Math.ceil(payload.length / 4) * 4, "=");
    const claims = JSON.parse(atob(padded));
    return typeof claims.role === "string" ? claims.role : null;
  } catch {
    return null;
  }
}

function safeErrorCode(value: unknown, fallback: string): string {
  const raw = typeof value === "string" ? value : fallback;
  const cleaned = raw.replace(/[^a-zA-Z0-9:_-]/g, "").slice(0, 100);
  return cleaned || fallback;
}

Deno.serve(async (request: Request) => {
  if (request.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: { "content-type": "application/json" },
    });
  }

  // The platform verifies the JWT; this additional check prevents normal
  // authenticated users from invoking a destructive maintenance worker.
  if (jwtRole(request) !== "service_role") {
    return new Response(JSON.stringify({ error: "service_role_required" }), {
      status: 403,
      headers: { "content-type": "application/json" },
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return new Response(JSON.stringify({ error: "worker_environment_missing" }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

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
    return new Response(JSON.stringify({
      error: "chat_job_claim_failed",
      code: safeErrorCode(chatClaimError.code, "claim_failed"),
      summary,
    }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
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
    return new Response(JSON.stringify({
      error: "storage_job_claim_failed",
      code: safeErrorCode(storageClaimError.code, "claim_failed"),
      summary,
    }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
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

  return new Response(JSON.stringify({ ok: true, summary }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
});
