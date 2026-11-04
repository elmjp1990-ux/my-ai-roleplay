import { assertEquals } from "jsr:@std/assert";
import { processChatDeletionJobs } from "./chat-deletion-job-worker.ts";

Deno.test("counts only confirmed purge success and marks returned RPC failures", async () => {
  const marked: unknown[][] = [];
  const summary = await processChatDeletionJobs([
    { job_id: "success" },
    { job_id: "rpc-error" },
    { job_id: "false-result" },
  ], {
    purgeJob: async (id) => {
      if (id === "success") return { data: true, error: null };
      if (id === "rpc-error") return { data: null, error: { code: "23514" } };
      return { data: false, error: null };
    },
    markFailed: async (...args) => {
      marked.push(args);
      return { data: true, error: null };
    },
  });

  assertEquals(marked, [
    ["rpc-error", "23514"],
    ["false-result", "purge_not_completed"],
  ]);
  assertEquals(summary, { chat_claimed: 3, chat_purged: 1, chat_failed: 2 });
});

Deno.test("continues the batch when purge RPC throws", async () => {
  const purged: string[] = [];
  const marked: unknown[][] = [];
  const summary = await processChatDeletionJobs([
    { job_id: "throws" },
    { job_id: "later-success" },
  ], {
    purgeJob: async (id) => {
      purged.push(id);
      if (id === "throws") {
        const error = new Error("database network unavailable");
        error.name = "FetchError";
        throw error;
      }
      return { data: true, error: null };
    },
    markFailed: async (...args) => {
      marked.push(args);
      return { data: true, error: null };
    },
  });

  assertEquals(purged, ["throws", "later-success"]);
  assertEquals(marked, [["throws", "FetchError"]]);
  assertEquals(summary, { chat_claimed: 2, chat_purged: 1, chat_failed: 1 });
});

Deno.test("continues the batch when failure-reporting RPC throws", async () => {
  const purged: string[] = [];
  let marks = 0;
  const summary = await processChatDeletionJobs([
    { job_id: "mark-throws" },
    { job_id: "later-success" },
  ], {
    purgeJob: async (id) => {
      purged.push(id);
      if (id === "mark-throws") return { data: null, error: { code: "P0001" } };
      return { data: true, error: null };
    },
    markFailed: async () => {
      marks += 1;
      throw new Error("failure marker RPC unavailable");
    },
  });

  assertEquals(purged, ["mark-throws", "later-success"]);
  assertEquals(marks, 1);
  assertEquals(summary, { chat_claimed: 2, chat_purged: 1, chat_failed: 1 });
});
