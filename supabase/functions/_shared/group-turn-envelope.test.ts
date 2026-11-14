import { assertEquals } from "jsr:@std/assert";
import { parseGroupTurnEnvelope } from "./group-turn-envelope.ts";

const roster = [
  { id: "a", name: "夜辰", sceneId: "scene-1", sceneName: "客廳" },
  { id: "b", name: "黎音", sceneId: "scene-2", sceneName: "公司" },
];

Deno.test("parses per-character group speeches and phone notifications", () => {
  const result = parseGroupTurnEnvelope(JSON.stringify({
    speeches: [{ speaker_id: "a", content: "*抬眼*妳回來了。" }],
    phone_updates: [
      { character_id: "a", notifications: [{ title: "最近訊息", body: "客戶確認明天下午會議。" }] },
      { character_id: "b", notifications: [{ title: "待辦事項", body: "目前沒有待辦事項" }] },
    ],
  }), roster);
  assertEquals(result?.speeches.map(row => [row.speakerId, row.content]), [["a", "*抬眼*妳回來了。"]]);
  assertEquals(result?.phoneUpdates.map(row => [row.characterId, row.notifications.length]), [["a", 1], ["b", 1]]);
});

Deno.test("rejects unknown speakers, unknown phone owners, missing character phone state and invalid rows", () => {
  const base = { speeches: [{ speaker_id: "a", content: "你好" }], phone_updates: [
    { character_id: "a", notifications: [] }, { character_id: "b", notifications: [] },
  ] };
  assertEquals(parseGroupTurnEnvelope(JSON.stringify({ ...base, speeches: [{ speaker_id: "outside", content: "不屬於群組的發言" }] }), roster), null);
  assertEquals(parseGroupTurnEnvelope(JSON.stringify({ ...base, phone_updates: [{ character_id: "outside", notifications: [] }] }), roster), null);
  assertEquals(parseGroupTurnEnvelope(JSON.stringify({ ...base, phone_updates: [{ character_id: "a", notifications: [] }] }), roster), null);
  assertEquals(parseGroupTurnEnvelope(JSON.stringify({ ...base, phone_updates: [{ character_id: "a", notifications: [{ title: "", body: "內容" }] }, { character_id: "b", notifications: [] }] }), roster), null);
});
