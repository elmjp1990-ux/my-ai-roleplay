import { createClient } from "npm:@supabase/supabase-js@2";
import { processStorageDeletionJobs } from "../supabase/functions/_shared/chat-deletion-worker.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const apiUrl = Deno.env.get("API_URL") ?? Deno.env.get("SUPABASE_URL");
const serviceKey = Deno.env.get("SERVICE_ROLE_KEY") ??
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
assert(apiUrl, "Local Supabase API_URL is required");
assert(serviceKey, "Local Supabase SERVICE_ROLE_KEY is required");

const supabase = createClient(apiUrl, serviceKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const bucketId = "personax-memory-photos";
// This path is seeded by the disposable SQL fixture through the exact
// private.enqueue_account_chat_memory_photo_cleanup() helper used by
// prepare_account_deletion(); the Storage API test consumes that same queue row.
const ownerId = "10000000-0000-4000-8000-000000000031";
const sessionId = "50000000-0000-4000-8000-000000000031";
const photoId = "c0000000-0000-4000-8000-000000000031";
const objectPath = `${ownerId}/single/${sessionId}/${photoId}.jpg`;
let fakeServer: Deno.HttpServer | null = null;
let bucketCreated = false;
let parentJobId: string | null = null;

try {
  const bucket = await supabase.storage.createBucket(bucketId, { public: false });
  if (bucket.error && !/already exists/i.test(bucket.error.message)) {
    throw bucket.error;
  }
  bucketCreated = !bucket.error;

  const upload = await supabase.storage.from(bucketId).upload(
    objectPath,
    new Blob(["poyozz-storage-retry-e2e"], { type: "image/jpeg" }),
    { contentType: "image/jpeg" },
  );
  if (upload.error) throw upload.error;

  const parent = await supabase.from("chat_deletion_jobs")
    .select("id")
    .eq("resource_type", "single_session")
    .eq("resource_id", sessionId)
    .eq("owner_id", ownerId)
    .single();
  if (parent.error) throw parent.error;
  parentJobId = parent.data.id;

  const child = await supabase.from("chat_storage_deletion_jobs")
    .select("id")
    .eq("deletion_job_id", parentJobId)
    .eq("bucket_id", bucketId)
    .eq("object_path", objectPath)
    .single();
  if (child.error) throw child.error;

  // Complete the due relational parent first. The real Storage claim RPC only
  // releases photo jobs after the 30-day chat purge has completed.
  const parentClaim = await supabase.rpc("claim_chat_deletion_jobs", { p_limit: 10 });
  if (parentClaim.error) throw parentClaim.error;
  assert(
    (parentClaim.data ?? []).some((job: { job_id: string }) => job.job_id === parentJobId),
    "Account photo parent deletion job was not claimed at its 30-day deadline",
  );
  const parentPurge = await supabase.rpc("purge_chat_deletion_job", {
    p_job_id: parentJobId,
  });
  if (parentPurge.error) throw parentPurge.error;
  assert(parentPurge.data === true, "Account photo parent chat purge must complete");

  const firstClaim = await supabase.rpc("claim_chat_storage_deletion_jobs", {
    p_limit: 10,
  });
  if (firstClaim.error) throw firstClaim.error;
  assert(
    (firstClaim.data ?? []).some((job: { job_id: string }) => job.job_id === child.data.id),
    "Storage retry job was not claimed on the first attempt",
  );

  // A local HTTP 503 exercises the real Supabase Storage client error path while
  // the real local database remains available for durable queue state updates.
  fakeServer = Deno.serve(
    { hostname: "127.0.0.1", port: 55321 },
    () => new Response(
      JSON.stringify({ message: "simulated_storage_service_unavailable" }),
      { status: 503, headers: { "content-type": "application/json" } },
    ),
  );
  const unavailableStorage = createClient("http://127.0.0.1:55321", serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const failedSummary = await processStorageDeletionJobs(firstClaim.data ?? [], {
    removeObject: async (bucket, path) => {
      const { error } = await unavailableStorage.storage.from(bucket).remove([path]);
      return { error };
    },
    markJob: async (jobId, success, errorCode) => {
      const { data, error } = await supabase.rpc("mark_chat_storage_deletion_job", {
        p_job_id: jobId,
        p_success: success,
        p_error_code: errorCode,
      });
      return { data, error };
    },
  });

  assert(failedSummary.storage_failed === 1, "HTTP 503 must mark one storage job failed");
  const afterFailure = await supabase.from("chat_storage_deletion_jobs")
    .select("status,attempt_count,last_error_code")
    .eq("id", child.data.id)
    .single();
  if (afterFailure.error) throw afterFailure.error;
  assert(afterFailure.data.status === "retry", "HTTP 503 must move job to retry");
  assert(afterFailure.data.attempt_count === 1, "HTTP 503 must increment attempt_count");
  assert(!!afterFailure.data.last_error_code, "HTTP 503 must record a bounded error code");

  const stillPresent = await supabase.storage.from(bucketId).list(
    `${ownerId}/single/${sessionId}`,
    { search: `${photoId}.jpg` },
  );
  if (stillPresent.error) throw stillPresent.error;
  assert(
    stillPresent.data.some((item) => item.name === `${photoId}.jpg`),
    "Object must remain after the simulated 503",
  );

  const release = await supabase.from("chat_storage_deletion_jobs")
    .update({ next_attempt_at: new Date(Date.now() - 1000).toISOString() })
    .eq("id", child.data.id);
  if (release.error) throw release.error;

  const secondClaim = await supabase.rpc("claim_chat_storage_deletion_jobs", {
    p_limit: 10,
  });
  if (secondClaim.error) throw secondClaim.error;
  assert(
    (secondClaim.data ?? []).some((job: { job_id: string }) => job.job_id === child.data.id),
    "Storage retry job was not reclaimed after next_attempt_at",
  );

  const successSummary = await processStorageDeletionJobs(secondClaim.data ?? [], {
    removeObject: async (bucket, path) => {
      const { error } = await supabase.storage.from(bucket).remove([path]);
      return { error };
    },
    markJob: async (jobId, success, errorCode) => {
      const { data, error } = await supabase.rpc("mark_chat_storage_deletion_job", {
        p_job_id: jobId,
        p_success: success,
        p_error_code: errorCode,
      });
      return { data, error };
    },
  });

  assert(successSummary.storage_deleted === 1, "Storage retry must delete one object");
  const afterSuccess = await supabase.from("chat_storage_deletion_jobs")
    .select("status,attempt_count")
    .eq("id", child.data.id)
    .single();
  if (afterSuccess.error) throw afterSuccess.error;
  assert(afterSuccess.data.status === "completed", "Successful retry must complete the queue job");

  const removed = await supabase.storage.from(bucketId).list(
    `${ownerId}/single/${sessionId}`,
    { search: `${photoId}.jpg` },
  );
  if (removed.error) throw removed.error;
  assert(
    !removed.data.some((item) => item.name === `${photoId}.jpg`),
    "Storage object must be absent after successful retry",
  );

  console.log("Local Storage API 503 -> durable retry -> successful object deletion passed.");
} finally {
  if (fakeServer) await fakeServer.shutdown();
  if (parentJobId) {
    await supabase.from("chat_storage_deletion_jobs").delete().eq("deletion_job_id", parentJobId);
    await supabase.from("chat_deletion_jobs").delete().eq("id", parentJobId);
  }
  await supabase.from("chat_memory_photos").delete().eq("id", photoId);
  await supabase.from("chat_sessions").delete().eq("id", sessionId);
  await supabase.from("profiles").delete().eq("id", ownerId);
  await supabase.auth.admin.deleteUser(ownerId);
  await supabase.storage.from(bucketId).remove([objectPath]);
  if (bucketCreated) {
    await supabase.storage.deleteBucket(bucketId);
  }
}
