import { assertEquals } from "jsr:@std/assert";
import {
  processAccountDeletionWorkItems,
  type AccountDeletionWorkerDeps,
} from "./account-deletion-worker.ts";

const item = {
  target_user_id: "user-1",
  batch_id: null,
  scheduled_for: "2026-12-01T00:00:00Z",
  work_status: "due",
};

function successfulDeps(calls: unknown[][] = []): AccountDeletionWorkerDeps {
  return {
    archive: async (id) => {
      calls.push(["archive", id]);
      return {
        data: [{
          batch_id: "batch-1",
          target_user_id: id,
          batch_status: "archived",
        }],
        error: null,
      };
    },
    prepare: async (id) => {
      calls.push(["prepare", id]);
      return {
        data: [{
          batch_id: "batch-1",
          target_user_id: id,
          batch_status: "deleting",
        }],
        error: null,
      };
    },
    deleteAuthUser: async (id) => {
      calls.push(["deleteAuthUser", id]);
      return { error: null };
    },
    isAuthUserAbsent: async (id) => {
      calls.push(["isAuthUserAbsent", id]);
      return false;
    },
    finalize: async (id) => {
      calls.push(["finalize", id]);
      return { data: true, error: null };
    },
    markFailure: async (id, code) => {
      calls.push(["markFailure", id, code]);
      return { data: true, error: null };
    },
  };
}

Deno.test("runs archive, prepare, Auth deletion, and finalize in order", async () => {
  const calls: unknown[][] = [];
  const summary = await processAccountDeletionWorkItems([item], successfulDeps(calls));
  assertEquals(summary, { claimed: 1, completed: 1, failed: 0, skipped: 0 });
  assertEquals(calls, [
    ["archive", "user-1"],
    ["prepare", "user-1"],
    ["deleteAuthUser", "user-1"],
    ["finalize", "batch-1"],
  ]);
});

Deno.test("fails closed when archive verification fails", async () => {
  const calls: unknown[][] = [];
  const deps = successfulDeps(calls);
  deps.archive = async () => ({ data: null, error: new Error("archive_mismatch") });
  const summary = await processAccountDeletionWorkItems([item], deps);
  assertEquals(summary.failed, 1);
  assertEquals(calls, [["markFailure", "batch-1", "Error"]]);
});

Deno.test("does not finalize when Auth deletion fails and user still exists", async () => {
  const calls: unknown[][] = [];
  const deps = successfulDeps(calls);
  deps.deleteAuthUser = async () => ({ error: { code: "auth_delete_failed" } });
  deps.isAuthUserAbsent = async () => false;
  const summary = await processAccountDeletionWorkItems([item], deps);
  assertEquals(summary.completed, 0);
  assertEquals(summary.failed, 1);
  assertEquals(calls.at(-1), ["markFailure", "batch-1", "auth_delete_failed"]);
  assertEquals(calls.some(([name]) => name === "finalize"), false);
});

Deno.test("finalizes idempotently when Auth user was already deleted", async () => {
  const calls: unknown[][] = [];
  const deps = successfulDeps(calls);
  deps.deleteAuthUser = async () => ({ error: { code: "user_not_found" } });
  deps.isAuthUserAbsent = async () => true;
  const summary = await processAccountDeletionWorkItems([item], deps);
  assertEquals(summary, { claimed: 1, completed: 1, failed: 0, skipped: 0 });
  assertEquals(calls.some(([name]) => name === "finalize"), true);
});

Deno.test("does not report success when finalize returns false", async () => {
  const calls: unknown[][] = [];
  const deps = successfulDeps(calls);
  deps.finalize = async () => ({ data: false, error: null });
  const summary = await processAccountDeletionWorkItems([item], deps);
  assertEquals(summary.completed, 0);
  assertEquals(summary.failed, 1);
  assertEquals(calls.at(-1), ["markFailure", "batch-1", "Error"]);
});
