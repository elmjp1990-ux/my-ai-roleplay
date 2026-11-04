const test = require("node:test");
const assert = require("node:assert/strict");
const { buildPlayerMemoryExcerpt } = require("../memory-capture.js");

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
