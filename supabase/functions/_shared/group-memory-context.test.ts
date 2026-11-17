import { assertEquals, assertStringIncludes } from "jsr:@std/assert";
import { buildGroupMemoryContext, getGroupHistoryLimit, isCurrentGroupMemorySummary } from "./group-memory-context.ts";

Deno.test("shared-scene context includes the cumulative summary and curated memories", () => {
  const context = buildGroupMemoryContext("shared",
    { batch_number: 3, summary: "最新累積摘要", important: false, user_edited: false },
    [
      { batch_number: 3, summary: "最新累積摘要", important: true },
      { batch_number: 2, summary: "一般摘要，不需重複加入", important: false, user_edited: false },
      { batch_number: 1, summary: "玩家手動修訂的舊記憶", important: false, user_edited: true },
      { batch_number: 0, summary: "無效批次", important: true },
    ],
  );
  assertStringIncludes(context, "【長期群組記憶摘要】\n最新累積摘要");
  assertStringIncludes(context, "【玩家珍藏／手動編輯的群組記憶】");
  assertStringIncludes(context, "玩家手動修訂的舊記憶");
  assertEquals(context.includes("一般摘要，不需重複加入"), false);
  assertEquals(context.includes("無效批次"), false);
  assertEquals(context.match(/最新累積摘要/g)?.length, 1);
});

Deno.test("separate-scene groups never receive a group-wide memory summary", () => {
  const context = buildGroupMemoryContext("separate",
    { batch_number: 2, summary: "不可跨場景共享的內容", important: true },
    [{ batch_number: 1, summary: "另一場景的珍藏內容", important: true }],
  );
  assertEquals(context, "");
  assertEquals(getGroupHistoryLimit("separate", true, false), 40);
});

Deno.test("curated group memories are capped to the eight newest valid batches", () => {
  const rows = Array.from({ length: 10 }, (_, index) => ({
    batch_number: 10 - index,
    summary: "珍藏摘要 " + (10 - index),
    important: true,
  }));
  const context = buildGroupMemoryContext("shared", null, rows);
  assertStringIncludes(context, "珍藏摘要 10");
  assertStringIncludes(context, "珍藏摘要 3");
  assertEquals(context.split(/\n/).includes("第 2 批：珍藏摘要 2"), false);
  assertEquals(context.split(/\n/).includes("第 1 批：珍藏摘要 1"), false);
  assertEquals(context.split(/\n/).filter((line) => line.startsWith("第 ")).length, 8);
});

Deno.test("a stale cumulative summary cannot reduce history while a newer five-turn batch is pending", () => {
  const batchOne = { batch_number: 1, summary: "第一批累積摘要" };
  const batchTwo = { batch_number: 2, summary: "第二批累積摘要" };
  assertEquals(isCurrentGroupMemorySummary(batchOne, 9), true);
  assertEquals(isCurrentGroupMemorySummary(batchOne, 10), false);
  assertEquals(isCurrentGroupMemorySummary(batchTwo, 10), true);
  assertEquals(isCurrentGroupMemorySummary(batchTwo, 14), true);
  assertEquals(isCurrentGroupMemorySummary(batchTwo, 15), false);
  assertEquals(isCurrentGroupMemorySummary(null, 15), false);
});

Deno.test("shared-scene history is reduced only when the summary lookup is healthy and a cumulative summary exists", () => {
  assertEquals(getGroupHistoryLimit("shared", true, false), 24);
  assertEquals(getGroupHistoryLimit("shared", false, false), 40);
  assertEquals(getGroupHistoryLimit("shared", true, true), 40);
  assertEquals(getGroupHistoryLimit("shared", false, true), 40);
});
