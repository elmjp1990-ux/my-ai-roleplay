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

Deno.test("omitted phone updates preserve prior states and never invalidate valid character speech", () => {
  const result = parseGroupTurnEnvelopeDetailed(JSON.stringify({
    speeches: [{ speaker_id: "a", content: "有效角色發言" }],
  }), roster);
  assertEquals(result.errorCode, null);
  assertEquals(result.envelope?.speeches[0].content, "有效角色發言");
  assertEquals(result.envelope?.phoneUpdates, [
    { characterId: "a", notifications: [{ title: "👔夜辰衣著/姿勢", body: "保留既有狀態" }] },
    { characterId: "b", notifications: [{ title: "💼公司訊息", body: "目前沒有足夠資訊" }] },
  ]);
});

Deno.test("partial phone updates are merged with prior state instead of rejecting the turn", () => {
  const result = parseGroupTurnEnvelopeDetailed(JSON.stringify({
    speeches: [{ speaker_id: "a", content: "有效角色發言" }],
    phone_updates: [{ character_id: "b", notifications: [{ title: "工作", body: "會議延後" }] }],
  }), roster);
  assertEquals(result.errorCode, null);
  assertEquals(result.envelope?.speeches[0].content, "有效角色發言");
  assertEquals(result.envelope?.phoneUpdates, [
    { characterId: "a", notifications: [{ title: "👔夜辰衣著/姿勢", body: "保留既有狀態" }] },
    { characterId: "b", notifications: [{ title: "💼公司訊息", body: "會議延後" }] },
  ]);
});

Deno.test("accepts omitted model titles for configured fields and rejects missing bodies", () => {
  const mismatch = parseGroupTurnEnvelopeDetailed(JSON.stringify({
    speeches: [{ speaker_id: "a", content: "有效角色發言" }],
    phone_updates: [
      { character_id: "a", notifications: [] },
      { character_id: "b", notifications: [{ title: "公司訊息", body: "正常" }] },
    ],
  }), roster);
  assertEquals(mismatch.errorCode, null);
  assertEquals(mismatch.envelope?.speeches[0].content, "有效角色發言");
  assertEquals(mismatch.envelope?.phoneUpdates[0].notifications[0].body, "保留既有狀態");

  const missingModelTitle = parseGroupTurnEnvelopeDetailed(JSON.stringify({
    speeches: [{ speaker_id: "a", content: "有效角色發言" }],
    phone_updates: [
      { character_id: "a", notifications: [{ title: "", body: "目前穿著深色西裝，站在辦公室。" }] },
      { character_id: "b", notifications: [{ title: "", body: "會議已延後。" }] },
    ],
  }), roster);
  assertEquals(missingModelTitle.errorCode, null);
  assertEquals(missingModelTitle.envelope?.phoneUpdates, [
    { characterId: "a", notifications: [{ title: "👔夜辰衣著/姿勢", body: "目前穿著深色西裝，站在辦公室。" }] },
    { characterId: "b", notifications: [{ title: "💼公司訊息", body: "會議已延後。" }] },
  ]);

  const missingBody = parseGroupTurnEnvelopeDetailed(JSON.stringify({
    speeches: [{ speaker_id: "a", content: "有效角色發言" }],
    phone_updates: [
      { character_id: "a", notifications: [{ title: "欄位", body: "" }] },
      { character_id: "b", notifications: [{ title: "公司訊息", body: "" }] },
    ],
  }), roster);
  assertEquals(missingBody.errorCode, null);
  assertEquals(missingBody.envelope?.phoneUpdates, [
    { characterId: "a", notifications: [{ title: "👔夜辰衣著/姿勢", body: "保留既有狀態" }] },
    { characterId: "b", notifications: [{ title: "💼公司訊息", body: "目前沒有足夠資訊" }] },
  ]);

  const overlongDuplicateTitle = parseGroupTurnEnvelopeDetailed(JSON.stringify({
    speeches: [{ speaker_id: "a", content: "有效角色發言" }],
    phone_updates: [
      { character_id: "a", notifications: [{ title: "模型重複輸出的標題".repeat(20), body: "狀態正常" }] },
      { character_id: "b", notifications: [{ title: "", body: "公司行程正常" }] },
    ],
  }), roster);
  assertEquals(overlongDuplicateTitle.errorCode, null);
  assertEquals(overlongDuplicateTitle.envelope?.phoneUpdates[0].notifications[0].title, "👔夜辰衣著/姿勢");
  assertEquals(overlongDuplicateTitle.envelope?.phoneUpdates[0].notifications[0].body, "狀態正常");

  const overlongBody = "狀態".repeat(300);
  const truncatedBody = parseGroupTurnEnvelopeDetailed(JSON.stringify({
    speeches: [{ speaker_id: "a", content: "有效角色發言" }],
    phone_updates: [
      { character_id: "a", notifications: [{ title: "", body: overlongBody }] },
      { character_id: "b", notifications: [{ title: "", body: "公司行程正常" }] },
    ],
  }), roster);
  assertEquals(truncatedBody.errorCode, null);
  assertEquals(truncatedBody.envelope?.phoneUpdates[0].notifications[0].body.length, 500);
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

Deno.test("recovers plain-text model output as a character speech", () => {
  const result = parseGroupTurnEnvelopeDetailed(
    "*蘇清雅抬起眼，將手中的文件放到一旁。*我聽見了，你先坐下，我們慢慢談。",
    [
      { id: "a", name: "傅司辰" },
      { id: "b", name: "蘇清雅" },
      { id: "c", name: "顧言" },
    ],
  );
  assertEquals(result.errorCode, null);
  assertEquals(result.envelope?.speeches, [{
    speakerId: "b",
    speakerName: "蘇清雅",
    content: "*蘇清雅抬起眼，將手中的文件放到一旁。*我聽見了，你先坐下，我們慢慢談。",
    sceneId: null,
    sceneName: "",
  }]);
});

Deno.test("rejects output with no recoverable character content and invalid roster identities", () => {
  assertEquals(parseGroupTurnEnvelope("{not-json}", roster), null);
  assertEquals(parseGroupTurnEnvelope("", roster), null);
  assertEquals(parseGroupTurnEnvelope("   ", roster), null);
});
