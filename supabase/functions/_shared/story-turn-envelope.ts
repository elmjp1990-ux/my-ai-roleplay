export type StoryPhoneEvent = {
  event_type: "message" | "social_post" | "missed_call" | "voice_message" | "notification";
  title: string;
  body: string;
};

export type StoryTurnEnvelope = {
  reply: string;
  affinity_delta: number;
  affinity_reason: string;
  phone_events: StoryPhoneEvent[];
  suggested_replies: string[];
};

export type StoryTurnEnvelopeOptions = {
  configuredPrompts?: string[];
  currentUserMessage?: string;
  playerName?: string;
};

const allowedPhoneEventTypes = new Set([
  "message",
  "social_post",
  "missed_call",
  "voice_message",
  "notification",
]);

const asObject = (value: unknown): Record<string, unknown> | null =>
  value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;

const boundedText = (value: unknown, max: number): string =>
  typeof value === "string" ? value.trim().slice(0, max) : "";

const hasExplicitPhoneSendAction = (message: string): boolean =>
  /(?:拿起|打開|解鎖|操作)?\s*(?:手機|電話|LINE|line|簡訊|訊息).{0,24}(?:傳(?:訊息|簡訊|LINE|line)?|發(?:訊息|簡訊)?|傳送|撥打|打電話)|(?:我|玩家).{0,18}(?:傳(?:訊息|簡訊|LINE|line)?給|發(?:訊息|簡訊)?給|傳送(?:訊息)?給|撥打電話給|打電話給)/i.test(message);

const escapeRegExp = (value: string): string => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

const isLikelyPlayerOriginMessage = (event: StoryPhoneEvent, playerName: string): boolean => {
  const source = `${event.title} ${event.body}`;
  const genericPlayerSource = /(?:玩家|你)(?:的)?(?:簡訊|訊息|LINE)|(?:簡訊|訊息|LINE).{0,12}(?:來自|由)(?:玩家|你)/i.test(source);
  const namedPlayerSource = playerName && playerName !== "玩家"
    ? new RegExp(`${escapeRegExp(playerName)}\\s*(?:的)?\\s*(?:簡訊|訊息|LINE)`, "i").test(source)
    : false;
  return genericPlayerSource || namedPlayerSource;
};

const fallbackBodyForLabel = (label: string): string => {
  if (/(?:最近|最新|收到).*(?:手機)?(?:訊息|簡訊)|(?:手機)?(?:訊息|簡訊).*(?:最近|最新|收到)/.test(label)) {
    return "目前沒有新的手機訊息";
  }
  if (/待辦|未完成事項/.test(label)) return "目前沒有待辦事項";
  return "目前沒有足夠資訊";
};

const promptLabel = (prompt: string): string =>
  (prompt.split("|", 1)[0] || "").trim().replace(/\{CHAR\}/g, "角色").replace(/\{USER\}/g, "玩家").slice(0, 80);

/**
 * Parses the single-call Story response envelope.
 * When author-configured phone fields exist, the server enforces their exact
 * count/order and safe empty-state copy rather than trusting model compliance.
 */
export function parseStoryTurnEnvelope(raw: string, options: StoryTurnEnvelopeOptions = {}): StoryTurnEnvelope {
  const fallback: StoryTurnEnvelope = {
    reply: raw.trim(),
    affinity_delta: 0,
    affinity_reason: "",
    phone_events: [],
    suggested_replies: [],
  };

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return fallback;
  }

  const value = asObject(parsed);
  if (!value) return fallback;
  const reply = boundedText(value.reply, 12000);
  if (!reply) return fallback;

  const rawDelta = value.affinity_delta;
  const affinityDelta = typeof rawDelta === "number" && Number.isInteger(rawDelta) && rawDelta >= -3 && rawDelta <= 3
    ? Number(rawDelta)
    : 0;

  const parsedPhoneEvents: StoryPhoneEvent[] = [];
  if (Array.isArray(value.phone_events)) {
    for (const item of value.phone_events.slice(0, 8)) {
      const event = asObject(item);
      if (!event || typeof event.event_type !== "string" || !allowedPhoneEventTypes.has(event.event_type)) continue;
      const title = boundedText(event.title, 80);
      const body = boundedText(event.body, 600);
      if (!title || !body) continue;
      parsedPhoneEvents.push({
        event_type: event.event_type as StoryPhoneEvent["event_type"],
        title,
        body,
      });
    }
  }

  let phoneEvents = parsedPhoneEvents;
  const configuredPrompts = (options.configuredPrompts ?? []).map((item) => boundedText(item, 500)).filter(Boolean).slice(0, 8);
  if (configuredPrompts.length > 0) {
    const explicitSend = hasExplicitPhoneSendAction(options.currentUserMessage ?? "");
    const playerName = boundedText(options.playerName, 80) || "玩家";
    phoneEvents = configuredPrompts.map((prompt, index) => {
      const label = promptLabel(prompt);
      const candidate = parsedPhoneEvents[index];
      if (!candidate) {
        return { event_type: "notification", title: label, body: fallbackBodyForLabel(label) };
      }
      const isPlayerMessageField = /(?:最近|最新|收到).*(?:訊息|簡訊)|(?:訊息|簡訊).*(?:最近|最新|收到)/.test(label);
      if (
        isPlayerMessageField &&
        !explicitSend &&
        (candidate.event_type === "message" || candidate.event_type === "notification") &&
        isLikelyPlayerOriginMessage(candidate, playerName)
      ) {
        return { event_type: "notification", title: label, body: "目前沒有新的手機訊息" };
      }
      return {
        event_type: "notification",
        title: label,
        body: candidate.body || fallbackBodyForLabel(label),
      };
    });
  }

  const rawSuggestions = Array.isArray(value.suggested_replies)
    ? value.suggested_replies
    : Array.isArray(value.suggestedReplies)
    ? value.suggestedReplies
    : Array.isArray(value.suggestions)
    ? value.suggestions
    : [];
  const validSuggestedReplies = rawSuggestions
    .slice(0, 3)
    .map((item) => typeof item === "string" ? item.trim() : "")
    .filter((item) => {
      if (item.length < 30 || item.length > 80 || /[\r\n]/.test(item)) return false;
      const narration = item.match(/\*[^*]+\*/g) ?? [];
      const spokenText = item.replace(/\*[^*]+\*/g, "").trim();
      return narration.length >= 1 && spokenText.length > 0;
    });
  const suggestedReplies = validSuggestedReplies.length === 3 ? validSuggestedReplies : [];

  return {
    reply,
    affinity_delta: affinityDelta,
    affinity_reason: boundedText(value.affinity_reason, 280),
    phone_events: phoneEvents,
    suggested_replies: suggestedReplies,
  };
}
