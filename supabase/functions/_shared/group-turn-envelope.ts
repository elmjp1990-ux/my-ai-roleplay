export type GroupTurnSpeaker = { id: string; name: string; sceneId?: string | null; sceneName?: string; phoneNotifications?: GroupPhoneNotification[] };
export type GroupPhoneNotification = { title: string; body: string };
export type GroupTurnEnvelope = {
  speeches: Array<{ speakerId: string; speakerName: string; content: string; sceneId: string | null; sceneName: string }>;
  phoneUpdates: Array<{ characterId: string; notifications: GroupPhoneNotification[] }>;
  storyWorldState: { storyTime: string; storyLocation: string } | null;
};

const asObject = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
const asText = (value: unknown): string => typeof value === "string" ? value.trim() : "";

export function serializeGroupPhoneUpdatesForRpc(updates: GroupTurnEnvelope["phoneUpdates"]) {
  return updates.map(({ characterId, notifications }) => ({
    character_id: characterId,
    notifications,
  }));
}

function extractJsonObject(text: string): string {
  let start = -1, depth = 0, inString = false, escaped = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (start < 0) { if (char === "{") { start = index; depth = 1; } continue; }
    if (inString) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === '"') inString = false;
      continue;
    }
    if (char === '"') inString = true;
    else if (char === "{") depth += 1;
    else if (char === "}" && --depth === 0) return text.slice(start, index + 1);
  }
  return "";
}

export type GroupTurnEnvelopeParseResult = {
  envelope: GroupTurnEnvelope | null;
  errorCode: string | null;
  warningCount: number;
};

export function parseGroupTurnEnvelopeDetailed(output: unknown, speakers: GroupTurnSpeaker[]): GroupTurnEnvelopeParseResult {
  let text = typeof output === "string" ? output.trim() : "";
  if (!text || !Array.isArray(speakers) || speakers.length < 1 || speakers.length > 3) {
    return { envelope: null, errorCode: "empty_output_or_roster", warningCount: 0 };
  }
  text = text.replace(/^\uFEFF/, "").replace(/<think>[\s\S]*?<\/think>/gi, "").trim();
  text = text.replace(/^\x60{3}(?:json)?\s*/i, "").replace(/\s*\x60{3}$/, "").trim();

  let root: Record<string, unknown>;
  try { root = asObject(JSON.parse(text)); }
  catch {
    const jsonObject = extractJsonObject(text);
    if (!jsonObject) return { envelope: null, errorCode: "invalid_json", warningCount: 0 };
    try { root = asObject(JSON.parse(jsonObject)); }
    catch { return { envelope: null, errorCode: "invalid_json", warningCount: 0 }; }
  }
  if (!Object.keys(root).length) return { envelope: null, errorCode: "invalid_root", warningCount: 0 };
  if (!Array.isArray(root.speeches)) return { envelope: null, errorCode: "missing_speeches", warningCount: 0 };

  const byId = new Map(speakers.map(speaker => [speaker.id, speaker]));
  const speeches: GroupTurnEnvelope["speeches"] = [];
  let warningCount = 0;
  for (const item of root.speeches) {
    const row = asObject(item);
    const speakerId = asText(row.speaker_id);
    const speaker = byId.get(speakerId);
    const content = asText(row.content);
    if (!speaker || !content || content.length > 20000) { warningCount += 1; continue; }
    speeches.push({
      speakerId, speakerName: speaker.name, content,
      sceneId: speaker.sceneId ?? null, sceneName: speaker.sceneName ?? "",
    });
    if (speeches.length === 3) break;
  }
  if (speeches.length < 1) return { envelope: null, errorCode: "no_valid_speeches", warningCount };

  const phoneById = new Map<string, GroupPhoneNotification[]>();
  if (Array.isArray(root.phone_updates)) {
    for (const item of root.phone_updates) {
      const row = asObject(item), characterId = asText(row.character_id);
      const speaker = byId.get(characterId);
      if (!speaker || phoneById.has(characterId) || !Array.isArray(row.notifications) || row.notifications.length > 8) {
        warningCount += 1; continue;
      }
      const notifications: GroupPhoneNotification[] = [];
      let valid = true;
      for (const rawNotice of row.notifications) {
        const notice = asObject(rawNotice), title = asText(notice.title), body = asText(notice.body);
        if (!title || !body || title.length > 80 || body.length > 500) { valid = false; break; }
        notifications.push({ title, body });
      }
      if (!valid) { warningCount += 1; continue; }
      phoneById.set(characterId, notifications);
    }
  } else warningCount += 1;

  const phoneUpdates = speakers.map(speaker => ({
    characterId: speaker.id,
    notifications: phoneById.has(speaker.id)
      ? phoneById.get(speaker.id)!
      : (Array.isArray(speaker.phoneNotifications) ? speaker.phoneNotifications.slice(0, 8) : []),
  }));
  const rawWorldState = asObject(root.story_world_state);
  const storyTime = asText(rawWorldState.story_time).slice(0, 80);
  const storyLocation = asText(rawWorldState.story_location).slice(0, 120);
  return {
    envelope: { speeches, phoneUpdates, storyWorldState: storyTime || storyLocation ? { storyTime, storyLocation } : null },
    errorCode: null,
    warningCount,
  };
}

export function parseGroupTurnEnvelope(output: unknown, speakers: GroupTurnSpeaker[]): GroupTurnEnvelope | null {
  return parseGroupTurnEnvelopeDetailed(output, speakers).envelope;
}
