import { assertEquals } from "jsr:@std/assert";
import {
  processAccountDeletionWorkItems,
  type AccountDeletionWorkerDeps,
  type AccountDeletionWorkItem,
} from "./account-deletion-worker.ts";

const item: AccountDeletionWorkItem = {
  target_user_id: "user-1",
  batch_id: null,
  scheduled_for: "2026-12-01T00:00:00Z",
  work_status: "due",
  lease_token: "lease-token-1",
  lease_generation: 1,
  lease_expires_at: "2026-12-01T00:10:00Z",
};

function successfulDeps(calls: unknown[][] = []): AccountDeletionWorkerDeps {
  return {
    prepare: async (id, token, generation) => {
      calls.push(["prepare", id, token, generation]);
      return {
        data: [{ batch_id: "batch-1", target_user_id: id, batch_status: "deleting" }],
        error: null,
      };
    },
    renew: async (id, token, generation) => {
      calls.push(["renew", id, token, generation]);
      return { data: true, error: null };
    },
    deleteAuthUser: async (id) => {
      calls.push(["deleteAuthUser", id]);
      return { error: null };
    },
    isAuthUserAbsent: async (id) => {
      calls.push(["isAuthUserAbsent", id]);
      return false;
    },
    finalize: async (id, batchId, token, generation) => {
      calls.push(["finalize", id, batchId, token, generation]);
      return { data: true, error: null };
    },
    markFailure: async (id, batchId, token, generation, code) => {
      calls.push(["markFailure", id, batchId, token, generation, code]);
      return { data: true, error: null };
    },
  };
}

Deno.test("runs fenced prepare, renew, Auth deletion, renew, and fenced finalize in order", async () => {
  const calls: unknown[][] = [];
  const summary = await processAccountDeletionWorkItems([item], successfulDeps(calls));
  assertEquals(summary, { claimed: 1, completed: 1, failed: 0, skipped: 0, failureReportFailed: 0 });
  assertEquals(calls, [
    ["prepare", "user-1", "lease-token-1", 1],
    ["renew", "user-1", "lease-token-1", 1],
    ["isAuthUserAbsent", "user-1"],
    ["renew", "user-1", "lease-token-1", 1],
    ["deleteAuthUser", "user-1"],
    ["renew", "user-1", "lease-token-1", 1],
    ["finalize", "user-1", "batch-1", "lease-token-1", 1],
  ]);
});

Deno.test("fails closed when fenced prepare fails before a batch exists", async () => {
  const calls: unknown[][] = [];
  const deps = successfulDeps(calls);
  deps.prepare = async () => ({ data: null, error: new Error("archive_mismatch") });
  const summary = await processAccountDeletionWorkItems([item], deps);
  assertEquals(summary.failed, 1);
  assertEquals(calls, [
    ["markFailure", "user-1", null, "lease-token-1", 1, "Error"],
  ]);
});

Deno.test("does not call Auth when lease renewal fails after prepare", async () => {
  const calls: unknown[][] = [];
  const deps = successfulDeps(calls);
  deps.renew = async (id, token, generation) => {
    calls.push(["renew", id, token, generation]);
    return { data: false, error: null };
  };
  const summary = await processAccountDeletionWorkItems([item], deps);
  assertEquals(summary.failed, 1);
  assertEquals(calls.some(([name]) => name === "deleteAuthUser"), false);
  assertEquals(calls.at(-1), [
    "markFailure", "user-1", "batch-1", "lease-token-1", 1, "Error",
  ]);
});

Deno.test("does not finalize when Auth deletion fails and user still exists", async () => {
  const calls: unknown[][] = [];
  const deps = successfulDeps(calls);
  deps.deleteAuthUser = async () => ({ error: { code: "auth_delete_failed" } });
  deps.isAuthUserAbsent = async () => false;
  const summary = await processAccountDeletionWorkItems([item], deps);
  assertEquals(summary.completed, 0);
  assertEquals(summary.failed, 1);
  assertEquals(calls.at(-1), [
    "markFailure", "user-1", "batch-1", "lease-token-1", 1, "auth_delete_failed",
  ]);
  assertEquals(calls.some(([name]) => name === "finalize"), false);
});

Deno.test("finalizes idempotently when Auth user was already deleted", async () => {
  const calls: unknown[][] = [];
  const deps = successfulDeps(calls);
  deps.isAuthUserAbsent = async (id) => {
    calls.push(["isAuthUserAbsent", id]);
    return true;
  };
  const summary = await processAccountDeletionWorkItems([item], deps);
  assertEquals(summary, { claimed: 1, completed: 1, failed: 0, skipped: 0, failureReportFailed: 0 });
  assertEquals(calls.some(([name]) => name === "deleteAuthUser"), false);
  assertEquals(calls.some(([name]) => name === "finalize"), true);
});

Deno.test("does not report success when fenced finalize returns false", async () => {
  const calls: unknown[][] = [];
  const deps = successfulDeps(calls);
  deps.finalize = async () => ({ data: false, error: null });
  const summary = await processAccountDeletionWorkItems([item], deps);
  assertEquals(summary.completed, 0);
  assertEquals(summary.failed, 1);
  assertEquals(calls.at(-1), [
    "markFailure", "user-1", "batch-1", "lease-token-1", 1, "Error",
  ]);
});

Deno.test("recovers a deleting batch after request row cascade and Auth deletion", async () => {
  const calls: unknown[][] = [];
  const deps = successfulDeps(calls);
  deps.prepare = async (id, token, generation) => {
    calls.push(["prepareRecovery", id, token, generation]);
    return {
      data: [{ batch_id: "batch-1", target_user_id: id, batch_status: "deleting" }],
      error: null,
    };
  };
  deps.isAuthUserAbsent = async (id) => {
    calls.push(["isAuthUserAbsent", id]);
    return true;
  };
  const interrupted = { ...item, batch_id: "batch-1", work_status: "deleting" };
  const summary = await processAccountDeletionWorkItems([interrupted], deps);
  assertEquals(summary.completed, 1);
  assertEquals(calls.some(([name]) => name === "deleteAuthUser"), false);
  assertEquals(calls.at(-1), [
    "finalize", "user-1", "batch-1", "lease-token-1", 1,
  ]);
});

Deno.test("passes the exact fencing generation through every database operation", async () => {
  const calls: unknown[][] = [];
  const deps = successfulDeps(calls);
  const generationTwo = { ...item, lease_token: "reclaimed-token", lease_generation: 2 };
  await processAccountDeletionWorkItems([generationTwo], deps);
  const dbCalls = calls.filter(([name]) =>
    name === "prepare" || name === "renew" || name === "finalize"
  );
  assertEquals(dbCalls.every((call) =>
    call.includes("reclaimed-token") && call.includes(2)
  ), true);
});

Deno.test("continues processing later items when failure reporting throws", async () => {
  const calls: unknown[][] = [];
  const deps = successfulDeps(calls);
  deps.prepare = async () => ({ data: null, error: new Error("prepare_unavailable") });
  deps.markFailure = async (id, batchId, token, generation, code) => {
    calls.push(["markFailure", id, batchId, token, generation, code]);
    throw new Error("failure_rpc_unavailable");
  };
  const second = { ...item, target_user_id: "user-2", lease_token: "lease-token-2" };
  const summary = await processAccountDeletionWorkItems([item, second], deps);
  assertEquals(summary, { claimed: 2, completed: 0, failed: 2, skipped: 0, failureReportFailed: 2 });
  assertEquals(calls.filter(([name]) => name === "prepare").length, 0);
});

Deno.test("counts resolved RPC errors from fenced failure reporting", async () => {
  const deps = successfulDeps();
  deps.prepare = async () => ({ data: null, error: new Error("prepare_unavailable") });
  deps.markFailure = async () => ({
    data: null,
    error: { code: "failure_rpc_unavailable" },
  });
  const summary = await processAccountDeletionWorkItems([item], deps);
  assertEquals(summary.failed, 1);
  assertEquals(summary.failureReportFailed, 1);
});
