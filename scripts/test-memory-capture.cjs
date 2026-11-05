const test = require("node:test");
const assert = require("node:assert/strict");
const { buildPlayerMemoryExcerpt, appendMemoryWithLimit, createSerialQueue, createMemoryMutationTracker, nextSessionUpdatedAt, rebaseSessionSaveVersion } = require("../memory-capture.js");

function makeConversation(playerCount) {
  const messages = [];
  for (let index = 1; index <= playerCount; index += 1) {
    messages.push({ id: "u" + index, role: "user", text: "PLAYER_" + index });
    messages.push({ id: "a" + index, role: "assistant", text: "ASSISTANT_" + index });
  }
  return messages;
}

test("does not create a memory excerpt before five player turns", () => {
  assert.equal(buildPlayerMemoryExcerpt(makeConversation(4), "Mira"), "");
});

test("preserves all five player messages and uses assistant replies only as context", () => {
  const memory = buildPlayerMemoryExcerpt(makeConversation(5), "Mira");
  for (let index = 1; index <= 5; index += 1) {
    assert.ok(memory.includes("玩家原話 " + index + "：PLAYER_" + index));
    assert.ok(memory.includes("Mira回應：ASSISTANT_" + index));
  }
  assert.ok(memory.indexOf("玩家原話優先保存") < memory.indexOf("角色回應脈絡"));
  assert.ok(memory.length <= 3000);
});

test("captures the newest five player turns at each five-turn boundary", () => {
  const memory = buildPlayerMemoryExcerpt(makeConversation(10), "Mira");
  const playerLines = memory.split("\n").filter((line) => line.startsWith("玩家原話 "));
  for (let index = 6; index <= 10; index += 1) {
    assert.ok(playerLines.includes("玩家原話 " + (index - 5) + "：PLAYER_" + index));
  }
  for (let index = 1; index <= 5; index += 1) {
    assert.equal(playerLines.some((line) => line.endsWith("：PLAYER_" + index)), false);
  }
});

test("limits each player quote to 480 Unicode code points without splitting emoji", () => {
  const messages = makeConversation(5);
  messages[0].text = "😀".repeat(500);
  const memory = buildPlayerMemoryExcerpt(messages, "Mira");
  const line = memory.split("\n").find((value) => value.startsWith("玩家原話 1："));
  const quote = line.slice("玩家原話 1：".length);
  assert.equal(Array.from(quote).length, 480);
  assert.equal(quote.includes("\uFFFD"), false);
});

test("caps assistant context separately and safely handles missing assistant replies", () => {
  const messages = makeConversation(5);
  for (const message of messages) {
    if (message.role === "assistant") message.text = "A".repeat(300);
  }
  const memory = buildPlayerMemoryExcerpt(messages, "Mira");
  const assistantSection = memory.split("【角色回應脈絡】")[1] || "";
  assert.ok(Array.from(assistantSection).length <= 430);

  const playerOnly = messages.filter((message) => message.role === "user");
  const withoutAssistant = buildPlayerMemoryExcerpt(playerOnly, "Mira");
  assert.ok(withoutAssistant.includes("【玩家原話優先保存】"));
  assert.equal(withoutAssistant.includes("角色回應脈絡"), false);
});


test("memory capacity evicts oldest ordinary entries before pinned memories", () => {
  const existing = [
    { id: "old", text: "O".repeat(4000), important: false },
    { id: "pinned", text: "P".repeat(4000), important: true },
    { id: "recent", text: "R".repeat(3000), important: false },
  ];
  const result = appendMemoryWithLimit(existing, { id: "new", text: "N".repeat(2000), important: false }, 10000);
  assert.equal(result.added, true);
  assert.equal(result.memories.some((item) => item.id === "old"), false);
  assert.equal(result.memories.some((item) => item.id === "pinned"), true);
  assert.equal(result.memories.some((item) => item.id === "recent"), true);
  assert.equal(result.memories.some((item) => item.id === "new"), true);
  assert.ok(result.memories.reduce((sum, item) => sum + Array.from(item.text).length, 0) <= 10000);
});

test("does not evict pinned memories or partially mutate history when a new item cannot fit", () => {
  const existing = [
    { id: "pinned-a", text: "A".repeat(6000), important: true },
    { id: "pinned-b", text: "B".repeat(4000), important: true },
  ];
  const result = appendMemoryWithLimit(existing, { id: "new", text: "N", important: false }, 10000);
  assert.equal(result.added, false);
  assert.deepEqual(result.memories, existing);
});

test("uses Unicode code points when enforcing memory capacity", () => {
  const existing = [{ id: "emoji", text: "😀".repeat(6), important: true }];
  const result = appendMemoryWithLimit(existing, { id: "next", text: "x".repeat(5), important: false }, 10);
  assert.equal(result.added, false);
  assert.deepEqual(result.memories, existing);
});


test("serializes writes for one session while allowing independent sessions to progress", async () => {
  const enqueue = createSerialQueue();
  const order = [];
  let releaseFirst;
  const firstGate = new Promise((resolve) => { releaseFirst = resolve; });
  const first = enqueue("user-a:session-1", async () => {
    order.push("first-start");
    await firstGate;
    order.push("first-end");
  });
  const second = enqueue("user-a:session-1", async () => {
    order.push("second");
  });
  const independent = enqueue("user-a:session-2", async () => {
    order.push("independent");
  });
  await Promise.resolve();
  assert.deepEqual(order, ["first-start", "independent"]);
  releaseFirst();
  await Promise.all([first, second, independent]);
  assert.deepEqual(order, ["first-start", "independent", "first-end", "second"]);
});

test("a failed save does not block later queued saves", async () => {
  const enqueue = createSerialQueue();
  const failed = enqueue("session", async () => { throw new Error("write failed"); });
  const later = enqueue("session", async () => "saved");
  await assert.rejects(failed, /write failed/);
  assert.equal(await later, "saved");
});

test("only the newest mutation may roll back, using the last confirmed persisted snapshot", () => {
  const tracker = createMemoryMutationTracker();
  const first = tracker.begin("session", [{ id: "old", text: "persisted", important: false }]);
  const second = tracker.begin("session", [{ id: "old", text: "first edit", important: false }]);
  assert.equal(tracker.isCurrent("session", first), false);
  assert.equal(tracker.isCurrent("session", second), true);
  assert.deepEqual(tracker.rollback("session", second), [{ id: "old", text: "persisted", important: false }]);
  tracker.markSaved("session", [{ id: "old", text: "first edit", important: false }]);
  assert.deepEqual(tracker.rollback("session", second), [{ id: "old", text: "first edit", important: false }]);
});

test("chat session version timestamps always advance beyond the prior server version", () => {
  const previous = "2026-11-04T03:52:10.123456+00:00";
  assert.equal(nextSessionUpdatedAt(previous, Date.parse(previous)), "2026-11-04T03:52:10.124Z");
  assert.equal(nextSessionUpdatedAt(previous, Date.parse(previous) - 5000), "2026-11-04T03:52:10.124Z");
  assert.equal(nextSessionUpdatedAt(previous, Date.parse(previous) + 5000), "2026-11-04T03:52:15.123Z");
  assert.throws(() => nextSessionUpdatedAt(null), /valid previous chat-session version/);
});


test("queued session saves rebase only the cloud version token onto the last confirmed row", async () => {
  const enqueue = createSerialQueue();
  const latest = {
    cloudOwned: true,
    cloudOwnerUid: "user-a",
    cloudUpdatedAt: "v1",
    cloudCharacterSnapshot: { id: "character-a", name: "Mira" },
  };
  const firstSnapshot = { id: "session-a", messages: ["first"], cloudUpdatedAt: "v1" };
  const secondSnapshot = { id: "session-a", messages: ["second"], cloudUpdatedAt: "v1" };
  let releaseFirst;
  const firstGate = new Promise((resolve) => { releaseFirst = resolve; });
  const first = enqueue("user-a:session-a", async () => {
    await firstGate;
    latest.cloudUpdatedAt = "v2";
    return true;
  });
  const second = enqueue("user-a:session-a", async () => {
    const rebased = rebaseSessionSaveVersion(secondSnapshot, latest, "user-a");
    assert.equal(rebased.cloudUpdatedAt, "v2");
    assert.deepEqual(rebased.messages, ["second"]);
    assert.equal(rebased.cloudCharacterSnapshot.name, "Mira");
    assert.equal(rebaseSessionSaveVersion(secondSnapshot, latest, "user-b").cloudUpdatedAt, "v1");
    return true;
  });
  releaseFirst();
  await Promise.all([first, second]);
});
