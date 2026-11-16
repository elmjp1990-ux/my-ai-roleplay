import { assertEquals } from "jsr:@std/assert";
import { parseGroupTurnEnvelope, parseGroupTurnEnvelopeDetailed, serializeGroupPhoneUpdatesForRpc } from "./group-turn-envelope.ts";

const roster = [
  { id: "a", name: "夜辰", sceneId: "scene-1", sceneName: "客廳", phoneNotifications: [{ title: "舊訊息", body: "保留既有狀態" }] },
  { id: "b", name: "黎音", sceneId: "scene-2", sceneName: "公司", phoneNotifications: [] },
];

Deno.test("parses per-character group speeches and phone notifications", () => {
  const result = parseGroupTurnEnvelope(JSON.stringify({
    speeches: [{ speaker_id: "a", content: "*抬眼*妳回來了。" }],
    phone_updates: [
      { character_id: "a", notifications: [{ title: "最近訊息", body: "客戶確認明天下午會議。" }] },
      { character_id: "b", notifications: [{ title: "待辦事項", body: "目前沒有待辦事項" }] },
    ],
    story_world_state: { story_time: "2026-11-16 19:30", story_location: "蘇清雅的辦公室" },
  }), roster);
  assertEquals(result?.speeches.map(row => [row.speakerId, row.content]), [["a", "*抬眼*妳回來了。"]]);
  assertEquals(result?.phoneUpdates.map(row => [row.characterId, row.notifications.length]), [["a", 1], ["b", 1]]);
  assertEquals(result?.storyWorldState, { storyTime: "2026-11-16 19:30", storyLocation: "蘇清雅的辦公室" });
  assertEquals(serializeGroupPhoneUpdatesForRpc(result!.phoneUpdates), [
    { character_id: "a", notifications: [{ title: "最近訊息", body: "客戶確認明天下午會議。" }] },
    { character_id: "b", notifications: [{ title: "待辦事項", body: "目前沒有待辦事項" }] },
  ]);
});

Deno.test("accepts wrapped JSON and preserves phone state omitted by the model", () => {
  const result = parseGroupTurnEnvelopeDetailed(
    '<think>先整理角色狀態，再輸出 JSON。</think>\n\x60\x60\x60json\n{"speeches":[{"speaker_id":"a","content":"*點頭*我知道了。"}]}\n\x60\x60\x60',
    roster,
  );
  assertEquals(result.errorCode, null);
  assertEquals(result.envelope?.phoneUpdates, [
    { characterId: "a", notifications: [{ title: "舊訊息", body: "保留既有狀態" }] },
    { characterId: "b", notifications: [] },
  ]);
});

Deno.test("accepts partial phone updates without discarding another character's saved state", () => {
  const result = parseGroupTurnEnvelope(JSON.stringify({
    speeches: [{ speaker_id: "a", content: "你好" }],
    phone_updates: [{ character_id: "b", notifications: [{ title: "工作", body: "會議延後" }] }],
  }), roster);
  assertEquals(result?.phoneUpdates, [
    { characterId: "a", notifications: [{ title: "舊訊息", body: "保留既有狀態" }] },
    { characterId: "b", notifications: [{ title: "工作", body: "會議延後" }] },
  ]);
});

Deno.test("recovers from malformed optional phone metadata but rejects invalid speeches", () => {
  const result = parseGroupTurnEnvelopeDetailed(JSON.stringify({
    speeches: [{ speaker_id: "a", content: "你好" }],
    phone_updates: [{ character_id: "b", notifications: [{ title: "", body: "不完整" }] }],
  }), roster);
  assertEquals(result.errorCode, null);
  assertEquals(result.warningCount, 1);
  assertEquals(result.envelope?.phoneUpdates[1].notifications, []);

  assertEquals(parseGroupTurnEnvelope(JSON.stringify({
    speeches: [{ speaker_id: "outside", content: "不屬於群組的發言" }],
  }), roster), null);
  assertEquals(parseGroupTurnEnvelope("{not-json}", roster), null);
  assertEquals(parseGroupTurnEnvelope(JSON.stringify({ phone_updates: [] }), roster), null);
});
