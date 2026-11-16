import { assertEquals } from "jsr:@std/assert";
import { parseGroupTurnEnvelope, parseGroupTurnEnvelopeDetailed, serializeGroupPhoneUpdatesForRpc } from "./group-turn-envelope.ts";

const roster = [
  { id: "a", name: "夜辰", sceneId: "scene-1", sceneName: "客廳", phoneSettings: { noticePrompts: ["👔{CHAR}衣著/姿勢 | 角色目前狀態"] }, phoneNotifications: [{ title: "舊訊息", body: "保留既有狀態" }] },
  { id: "b", name: "黎音", sceneId: "scene-2", sceneName: "公司", phoneSettings: { noticePrompts: ["💼公司訊息 | 公司通知"] }, phoneNotifications: [] },
];

Deno.test("parses every member phone field even when only one character speaks", () => {
  const result = parseGroupTurnEnvelopeDetailed(JSON.stringify({
    speeches: [{ speaker_id: "a", content: "*抬眼*妳回來了。*他將桌上的文件收好，替妳留出座位。*今天的事我已經安排好了，我們可以慢慢談。" }],
    phone_updates: [
      { character_id: "a", notifications: [{ title: "model title ignored", body: "目前穿著深色襯衫，站在客廳窗邊。" }] },
      { character_id: "b", notifications: [{ title: "model title ignored", body: "下午會議改到三點，助理已更新行程。" }] },
    ],
    story_world_state: { story_time: "2026-11-16 19:30", story_location: "蘇清雅的辦公室" },
  }), roster, "Una Kao").envelope;
  assertEquals(result?.speeches.length, 1);
  assertEquals(result?.phoneUpdates, [
    { characterId: "a", notifications: [{ title: "👔夜辰衣著/姿勢", body: "目前穿著深色襯衫，站在客廳窗邊。" }] },
    { characterId: "b", notifications: [{ title: "💼公司訊息", body: "下午會議改到三點，助理已更新行程。" }] },
  ]);
  assertEquals(result?.storyWorldState, { storyTime: "2026-11-16 19:30", storyLocation: "蘇清雅的辦公室" });
  assertEquals(serializeGroupPhoneUpdatesForRpc(result!.phoneUpdates), [
    { character_id: "a", notifications: [{ title: "👔夜辰衣著/姿勢", body: "目前穿著深色襯衫，站在客廳窗邊。" }] },
    { character_id: "b", notifications: [{ title: "💼公司訊息", body: "下午會議改到三點，助理已更新行程。" }] },
  ]);
});

Deno.test("rejects omitted phone updates when characters have configured fields", () => {
  const result = parseGroupTurnEnvelopeDetailed(JSON.stringify({
    speeches: [{ speaker_id: "a", content: "有效角色發言" }],
  }), roster);
  assertEquals(result.envelope, null);
  assertEquals(result.errorCode, "missing_phone_updates");
});

Deno.test("rejects partial phone updates instead of silently completing with empty states", () => {
  const result = parseGroupTurnEnvelopeDetailed(JSON.stringify({
    speeches: [{ speaker_id: "a", content: "有效角色發言" }],
    phone_updates: [{ character_id: "b", notifications: [{ title: "工作", body: "會議延後" }] }],
  }), roster);
  assertEquals(result.envelope, null);
  assertEquals(result.errorCode, "incomplete_phone_updates");
});

Deno.test("rejects configured phone field count mismatches and malformed values", () => {
  const mismatch = parseGroupTurnEnvelopeDetailed(JSON.stringify({
    speeches: [{ speaker_id: "a", content: "有效角色發言" }],
    phone_updates: [
      { character_id: "a", notifications: [] },
      { character_id: "b", notifications: [{ title: "公司訊息", body: "正常" }] },
    ],
  }), roster);
  assertEquals(mismatch.errorCode, "phone_notification_count_mismatch");

  const malformed = parseGroupTurnEnvelopeDetailed(JSON.stringify({
    speeches: [{ speaker_id: "a", content: "有效角色發言" }],
    phone_updates: [
      { character_id: "a", notifications: [{ title: "", body: "不完整" }] },
      { character_id: "b", notifications: [{ title: "公司訊息", body: "正常" }] },
    ],
  }), roster);
  assertEquals(malformed.errorCode, "invalid_required_phone_notification");
});

Deno.test("keeps prior phone state only for characters without configured fields", () => {
  const unconfigured = [{ id: "a", name: "夜辰", phoneNotifications: [{ title: "舊訊息", body: "保留既有狀態" }] }];
  const result = parseGroupTurnEnvelopeDetailed(JSON.stringify({
    speeches: [{ speaker_id: "a", content: "你好" }],
  }), unconfigured);
  assertEquals(result.errorCode, null);
  assertEquals(result.envelope?.phoneUpdates, [
    { characterId: "a", notifications: [{ title: "舊訊息", body: "保留既有狀態" }] },
  ]);
});

Deno.test("rejects invalid speaker identities and malformed JSON", () => {
  assertEquals(parseGroupTurnEnvelope(JSON.stringify({
    speeches: [{ speaker_id: "outside", content: "不屬於群組的發言" }],
    phone_updates: [
      { character_id: "a", notifications: [{ title: "欄位", body: "狀態" }] },
      { character_id: "b", notifications: [{ title: "欄位", body: "狀態" }] },
    ],
  }), roster), null);
  assertEquals(parseGroupTurnEnvelope("{not-json}", roster), null);
});
