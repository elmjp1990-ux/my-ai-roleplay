import { assertEquals } from "jsr:@std/assert@1";
import {
  isSafeCharacterAssetJob,
  processCharacterAssetCleanupJobs,
  type CharacterAssetCleanupJob,
} from "./character-asset-cleanup-worker.ts";

const base: CharacterAssetCleanupJob = {
  id: "11111111-1111-4111-8111-111111111111",
  bucket_id: "character-illustrations",
  owner_id: "22222222-2222-4222-8222-222222222222",
  character_id: "33333333-3333-4333-8333-333333333333",
  object_path: "22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333/art.webp",
};

Deno.test("accepts only allowlisted owner/character scoped asset paths", () => {
  assertEquals(isSafeCharacterAssetJob(base), true);
  assertEquals(isSafeCharacterAssetJob({ ...base, bucket_id: "personax-memory-photos" }), false);
  assertEquals(isSafeCharacterAssetJob({ ...base, object_path: "other-owner/character/art.webp" }), false);
  assertEquals(isSafeCharacterAssetJob({ ...base, object_path: base.object_path + "/nested" }), false);
});

Deno.test("skips assets still referenced by a remaining character", async () => {
  let removed = 0;
  const summary = await processCharacterAssetCleanupJobs([base], {
    isReferenced: async () => ({ referenced: true, error: null }),
    removeObject: async () => { removed += 1; return { error: null }; },
    markJob: async (_id, status, code) => {
      assertEquals(status, "skipped");
      assertEquals(code, "asset_still_referenced");
      return { error: null };
    },
  });
  assertEquals(removed, 0);
  assertEquals(summary.skipped, 1);
  assertEquals(summary.deleted, 0);
});

Deno.test("removes only unreferenced allowlisted assets", async () => {
  const removed: string[] = [];
  const summary = await processCharacterAssetCleanupJobs([base], {
    isReferenced: async () => ({ referenced: false, error: null }),
    removeObject: async (bucket, path) => {
      removed.push(`${bucket}:${path}`);
      return { error: null };
    },
    markJob: async (_id, status) => {
      assertEquals(status, "completed");
      return { error: null };
    },
  });
  assertEquals(removed.length, 1);
  assertEquals(summary.deleted, 1);
});

Deno.test("fails closed and reports Storage errors for retry", async () => {
  const marked: string[] = [];
  const summary = await processCharacterAssetCleanupJobs([base], {
    isReferenced: async () => ({ referenced: false, error: null }),
    removeObject: async () => ({ error: { code: "storage_503" } }),
    markJob: async (_id, status, code) => {
      marked.push(`${status}:${code}`);
      return { error: null };
    },
  });
  assertEquals(marked[0], "failed:storage_503");
  assertEquals(summary.failed, 1);
});
