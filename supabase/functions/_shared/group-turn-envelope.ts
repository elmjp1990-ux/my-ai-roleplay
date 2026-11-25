export type GroupTurnSpeaker = { id: string; name: string; sceneId?: string | null; sceneName?: string; phoneSettings?: Record<string, unknown>; phoneNotifications?: GroupPhoneNotification[] };
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

function extractPlainReply(text: string): string {
  const normalized = text
    .replace(/^\uFEFF/, "")
    .replace(/<think>[\s\S]*?<\/think>/gi, "")
    .replace(/^\x60{3}(?:json)?\s*/i, "")
    .replace(/\s*\x60{3}$/, "")
    .trim();
  if (!normalized || normalized.startsWith("{") || normalized.startsWith("[")) return "";
  return normalized.slice(0, 20000);
}

function configuredPrompts(speaker: GroupTurnSpeaker): string[] {
  const settings = asObject(speaker.phoneSettings);
  const raw = Array.isArray(settings.noticePrompts) ? settings.noticePrompts
    : Array.isArray(settings.notices) ? settings.notices : [];
  return raw.map(asText).filter(Boolean).slice(0, 8);
}

function fallbackBodyForLabel(label: string): string {
  if (/(?:最近|最新|收到).*(?:手機)?(?:訊息|簡訊)|(?:手機)?(?:訊息|簡訊).*(?:最近|最新|收到)/.test(label)) {
    return "目前沒有新的手機訊息";
  }
  if (/待辦|未完成事項/.test(label)) return "目前沒有待辦事項";
  return "目前沒有足夠資訊";
}

function fallbackNotifications(speaker: GroupTurnSpeaker, playerName: string): GroupPhoneNotification[] {
  const prompts = configuredPrompts(speaker);
  if (prompts.length) {
    return prompts.map((prompt, index) => {
      const title = (prompt.split("|", 1)[0] || "").trim()
        .replace(/\{CHAR\}/g, speaker.name)
        .replace(/\{USER\}/g, asText(playerName) || "玩家")
        .slice(0, 80);
      const previousBody = asText(speaker.phoneNotifications?.[index]?.body);
      return {
        title: title || `手機資訊${index + 1}`,
        body: previousBody.slice(0, 500) || fallbackBodyForLabel(title),
      };
    });
  }
  return Array.isArray(speaker.phoneNotifications)
    ? speaker.phoneNotifications.slice(0, 8).map((notice) => ({
      title: asText(notice.title).slice(0, 80),
      body: asText(notice.body).slice(0, 500),
    })).filter((notice) => notice.title && notice.body)
    : [];
}

function chooseFallbackSpeaker(text: string, speakers: GroupTurnSpeaker[]): GroupTurnSpeaker {
  const matched = speakers.find((speaker) => speaker.name && text.includes(speaker.name));
  return matched || speakers[0];
}

function makeFallbackSpeech(text: string, speakers: GroupTurnSpeaker[]) {
  const speaker = chooseFallbackSpeaker(text, speakers);
  return speaker && text
    ? [{ speakerId: speaker.id, speakerName: speaker.name, content: text, sceneId: speaker.sceneId ?? null, sceneName: speaker.sceneName ?? "" }]
    : [];
}

export type GroupTurnEnvelopeParseResult = {
  envelope: GroupTurnEnvelope | null;
  errorCode: string | null;
  warningCount: number;
};

/**
 * Character speech is the billable user-facing result. Phone metadata and world
 * state are best-effort side effects: incomplete model metadata is normalized
 * from the last known state instead of invalidating otherwise usable speech.
 */
export function parseGroupTurnEnvelopeDetailed(output: unknown, speakers: GroupTurnSpeaker[], playerName = "玩家"): GroupTurnEnvelopeParseResult {
  let text = typeof output === "string" ? output.trim() : "";
  if (!text || !Array.isArray(speakers) || speakers.length < 1 || speakers.length > 3) {
    return { envelope: null, errorCode: "empty_output_or_roster", warningCount: 0 };
  }
  text = text.replace(/^\uFEFF/, "").replace(/<think>[\s\S]*?<\/think>/gi, "").trim();
  text = text.replace(/^\x60{3}(?:json)?\s*/i, "").replace(/\s*\x60{3}$/, "").trim();

  let root: Record<string, unknown> = {};
  let parsedJson = false;
  try {
    const parsed = JSON.parse(text);
    root = asObject(parsed);
    parsedJson = Object.keys(root).length > 0;
  } catch {
    const jsonObject = extractJsonObject(text);
    if (jsonObject) {
      try {
        root = asObject(JSON.parse(jsonObject));
        parsedJson = Object.keys(root).length > 0;
      } catch { /* Fall through to plain-text speech recovery below. */ }
    }
  }

  const byId = new Map(speakers.map((speaker) => [speaker.id, speaker]));
  const speeches: GroupTurnEnvelope["speeches"] = [];
  let warningCount = 0;
  if (Array.isArray(root.speeches)) {
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
  }

  // Some providers occasionally ignore JSON mode and return the actual roleplay
  // prose directly. Preserve that reply rather than refunding a successfully
  // generated turn solely because its transport wrapper is missing.
  if (!speeches.length) {
    const plainReply = asText(root.reply) || asText(root.content) || (!parsedJson ? extractPlainReply(text) : "");
    if (plainReply) {
      speeches.push(...makeFallbackSpeech(plainReply, speakers));
      warningCount += 1;
    }
  }
  if (!speeches.length) return { envelope: null, errorCode: parsedJson ? "no_valid_speeches" : "empty_or_unrecoverable_output", warningCount };

  const phoneById = new Map<string, GroupPhoneNotification[]>();
  if (!Array.isArray(root.phone_updates)) {
    warningCount += 1;
  } else {
    for (const item of root.phone_updates) {
      const row = asObject(item);
      const characterId = asText(row.character_id);
      const speaker = byId.get(characterId);
      if (!speaker || phoneById.has(characterId) || !Array.isArray(row.notifications)) {
        warningCount += 1;
        continue;
      }
      const notifications = row.notifications.slice(0, 8).map((rawNotice: unknown) => {
        const notice = asObject(rawNotice);
        return { title: asText(notice.title).slice(0, 80), body: asText(notice.body).slice(0, 500) };
      });
      phoneById.set(characterId, notifications);
    }
  }

  const phoneUpdates: GroupTurnEnvelope["phoneUpdates"] = speakers.map((speaker) => {
    const prompts = configuredPrompts(speaker);
    const supplied = phoneById.get(speaker.id) || [];
    const previous = fallbackNotifications(speaker, playerName);
    if (prompts.length) {
      const notifications = prompts.map((prompt, index) => {
        const configuredTitle = (prompt.split("|", 1)[0] || "").trim()
          .replace(/\{CHAR\}/g, speaker.name)
          .replace(/\{USER\}/g, asText(playerName) || "玩家")
          .slice(0, 80);
        const candidate = supplied[index];
        const body = asText(candidate?.body).slice(0, 500) || previous[index]?.body || fallbackBodyForLabel(configuredTitle);
        if (!candidate?.body || !candidate.title || supplied.length !== prompts.length) warningCount += 1;
        return { title: configuredTitle || candidate?.title || `手機資訊${index + 1}`, body };
      });
      if (supplied.length > prompts.length) warningCount += 1;
      return { characterId: speaker.id, notifications };
    }
    if (!supplied.length) return { characterId: speaker.id, notifications: previous };
    const notifications = supplied.filter((notice) => notice.title && notice.body);
    if (notifications.length !== supplied.length) warningCount += 1;
    return { characterId: speaker.id, notifications: notifications.length ? notifications : previous };
  });

  const rawWorldState = asObject(root.story_world_state);
  const storyTime = asText(rawWorldState.story_time).slice(0, 80);
  const storyLocation = asText(rawWorldState.story_location).slice(0, 120);
  return {
    envelope: {
      speeches,
      phoneUpdates,
      storyWorldState: storyTime || storyLocation ? { storyTime, storyLocation } : null,
    },
    errorCode: null,
    warningCount,
  };
}

export function parseGroupTurnEnvelope(output: unknown, speakers: GroupTurnSpeaker[]): GroupTurnEnvelope | null {
  return parseGroupTurnEnvelopeDetailed(output, speakers).envelope;
}
