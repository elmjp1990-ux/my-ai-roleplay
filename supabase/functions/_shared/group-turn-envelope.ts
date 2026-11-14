export type GroupTurnSpeaker = { id: string; name: string; sceneId?: string | null; sceneName?: string };
export type GroupPhoneNotification = { title: string; body: string };
export type GroupTurnEnvelope = {
  speeches: Array<{ speakerId: string; speakerName: string; content: string; sceneId: string | null; sceneName: string }>;
  phoneUpdates: Array<{ characterId: string; notifications: GroupPhoneNotification[] }>;
};

const asObject = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
const asText = (value: unknown): string => typeof value === "string" ? value.trim() : "";

/** Parse and validate one JSON response containing group speeches and per-character phone state. */
export function parseGroupTurnEnvelope(output: unknown, speakers: GroupTurnSpeaker[]): GroupTurnEnvelope | null {
  let text = typeof output === "string" ? output.trim() : "";
  if (!text || !Array.isArray(speakers) || speakers.length < 1 || speakers.length > 3) return null;
  text = text.replace(/^\uFEFF/, "").replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "").trim();
  let root: Record<string, unknown>;
  try { root = asObject(JSON.parse(text)); } catch { return null; }
  if (!Object.keys(root).length || !Array.isArray(root.speeches) || !Array.isArray(root.phone_updates)) return null;

  const byId = new Map(speakers.map(speaker => [speaker.id, speaker]));
  const speeches: GroupTurnEnvelope["speeches"] = [];
  for (const item of root.speeches) {
    const row = asObject(item);
    const speakerId = asText(row.speaker_id);
    const speaker = byId.get(speakerId);
    const content = asText(row.content);
    if (!speaker || !content || content.length > 20000) return null;
    speeches.push({
      speakerId, speakerName: speaker.name, content,
      sceneId: speaker.sceneId ?? null, sceneName: speaker.sceneName ?? "",
    });
  }
  if (speeches.length < 1 || speeches.length > 3) return null;

  const phoneById = new Map<string, GroupPhoneNotification[]>();
  for (const item of root.phone_updates) {
    const row = asObject(item);
    const characterId = asText(row.character_id);
    if (!byId.has(characterId) || phoneById.has(characterId) || !Array.isArray(row.notifications) || row.notifications.length > 8) return null;
    const notifications: GroupPhoneNotification[] = [];
    for (const rawNotice of row.notifications) {
      const notice = asObject(rawNotice);
      const title = asText(notice.title);
      const body = asText(notice.body);
      if (!title || !body || title.length > 80 || body.length > 500) return null;
      notifications.push({ title, body });
    }
    phoneById.set(characterId, notifications);
  }
  if (phoneById.size !== speakers.length) return null;
  return {
    speeches,
    phoneUpdates: speakers.map(speaker => ({
      characterId: speaker.id,
      notifications: phoneById.get(speaker.id) || [],
    })),
  };
}
