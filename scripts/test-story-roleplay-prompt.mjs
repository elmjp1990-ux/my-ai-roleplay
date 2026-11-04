import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("supabase/functions/chat-turn/index.ts", "utf8");
const start = source.indexOf("const systemTemplate = [");
const end = source.indexOf("].join(\"\\n\");", start);
assert.ok(start >= 0 && end > start, "Story system prompt must exist");
const prompt = source.slice(start, end);

const requiredRules = [
  ["vary paragraph and sentence structures", "連續段落不得沿用相同的句子骨架"],
  ["avoid repeated metaphors and imagery", "不要連續使用相同或近似的譬喻"],
  ["prefer concrete descriptions", "優先寫清楚誰做了什麼"],
  ["character agency; do not flatter the player", "角色不是以滿足玩家、稱讚玩家或認同玩家為唯一目的"],
  ["permit disagreement and boundaries", "允許角色有不同意見、遲疑、拒絕"],
  ["separate spoken dialogue from private thoughts", "只供 AI 理解劇情的內心話"],
  ["do not let characters read the player's mind", "不得讓角色直接引用、回應、猜中或表現得像讀心"],
  ["narration and actions use the UI single-asterisk syntax", "一律使用 *單星號* 包住"],
];
for (const [label, phrase] of requiredRules) {
  assert.ok(prompt.includes(phrase), `Missing roleplay prompt rule: ${label}`);
}

assert.ok(
  prompt.includes("除非角色人設卡或世界觀明確要求這種詩性／抽象語氣"),
  "Character card/world setting may explicitly authorize an abstract or poetic style",
);
assert.ok(
  prompt.includes("角色實際說出口的話直接寫"),
  "Spoken dialogue must remain visually distinct from narration",
);
assert.ok(
  prompt.includes("星號只決定畫面呈現，不代表角色能得知其中資訊"),
  "Asterisks control presentation, not character knowledge",
);
const uiSource = readFileSync("index.html", "utf8");
assert.ok(
  uiSource.includes("Legacy single-asterisk *...* narration remains supported"),
  "The chat UI must preserve single-asterisk narration rendering",
);
assert.ok(
  !prompt.includes("每次至少包含兩段動作／背景描寫與兩處角色對話"),
  "Do not force repetitive narration/dialogue quotas",
);

console.log("Story roleplay prompt contracts passed: varied prose, concrete detail, character agency, POV boundaries and bold narration.");
