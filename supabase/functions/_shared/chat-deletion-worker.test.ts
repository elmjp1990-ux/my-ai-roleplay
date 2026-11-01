import { assertEquals } from "jsr:@std/assert";
import { processStorageDeletionJobs } from "./chat-deletion-worker.ts";

const job = {
  job_id: "job-1",
  bucket_id: "personax-memory-photos",
  object_path: "owner/session/photo.png",
};

Deno.test("counts success only after Storage removal and queue mark both succeed", async () => {
  const calls: unknown[][] = [];
  const summary = await processStorageDeletionJobs([job], {
    removeObject: async (bucket, path) => {
      calls.push(["remove", bucket, path]);
      return { error: null };
    },
    markJob: async (id, success, code) => {
      calls.push(["mark", id, success, code]);
      return { data: true, error: null };
    },
  });
  assertEquals(summary, { storage_claimed: 1, storage_deleted: 1, storage_failed: 0 });
  assertEquals(calls, [
    ["remove", "personax-memory-photos", "owner/session/photo.png"],
    ["mark", "job-1", true, null],
  ]);
});

Deno.test("routes a simulated Storage HTTP 5xx error to retry and counts failure", async () => {
  let marked: unknown[] = [];
  const summary = await processStorageDeletionJobs([job], {
    removeObject: async () => ({ error: { name: "StorageApiError" } }),
    markJob: async (...args) => {
      marked = args;
      return { data: true, error: null };
    },
  });
  assertEquals(marked, ["job-1", false, "StorageApiError"]);
  assertEquals(summary, { storage_claimed: 1, storage_deleted: 0, storage_failed: 1 });
});

Deno.test("routes a simulated network failure to retry and counts failure", async () => {
  let marked: unknown[] = [];
  const summary = await processStorageDeletionJobs([job], {
    removeObject: async () => ({ error: { name: "FetchError" } }),
    markJob: async (...args) => {
      marked = args;
      return { data: true, error: null };
    },
  });
  assertEquals(marked, ["job-1", false, "FetchError"]);
  assertEquals(summary, { storage_claimed: 1, storage_deleted: 0, storage_failed: 1 });
});

Deno.test("does not count completion when queue mark returns false or errors", async () => {
  const falseResult = await processStorageDeletionJobs([job], {
    removeObject: async () => ({ error: null }),
    markJob: async () => ({ data: false, error: null }),
  });
  const rpcError = await processStorageDeletionJobs([job], {
    removeObject: async () => ({ error: null }),
    markJob: async () => ({ data: null, error: new Error("rpc unavailable") }),
  });
  assertEquals(falseResult.storage_deleted, 0);
  assertEquals(falseResult.storage_failed, 1);
  assertEquals(rpcError.storage_deleted, 0);
  assertEquals(rpcError.storage_failed, 1);
});

Deno.test("rejects non-chat buckets and empty paths without calling Storage", async () => {
  let removeCalls = 0;
  const marked: unknown[][] = [];
  const summary = await processStorageDeletionJobs([
    { job_id: "bad-bucket", bucket_id: "character-illustrations", object_path: "x.png" },
    { job_id: "empty-path", bucket_id: "personax-memory-photos", object_path: "" },
  ], {
    removeObject: async () => {
      removeCalls += 1;
      return { error: null };
    },
    markJob: async (...args) => {
      marked.push(args);
      return { data: true, error: null };
    },
  });
  assertEquals(removeCalls, 0);
  assertEquals(marked, [
    ["bad-bucket", false, "storage_path_not_allowed"],
    ["empty-path", false, "storage_path_not_allowed"],
  ]);
  assertEquals(summary, { storage_claimed: 2, storage_deleted: 0, storage_failed: 2 });
});
