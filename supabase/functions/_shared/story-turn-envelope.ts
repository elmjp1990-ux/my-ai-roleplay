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
  characterName?: string;
};

const fallbackSuggestedReplies = (): string[] => [
  "*我稍微停下動作，認真看向你*你剛才提到的事，我還想再聽你多說一點，可以嗎？",
  "*我輕輕點頭，語氣放緩一些*那我們先把眼前這件事處理好，之後再慢慢聊。",
  "*我看了看四周，再把目光移回你身上*如果你願意，我想陪你一起確認接下來的安排。",
];

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
  /(?:我|玩家).{0,24}(?:傳|發|傳送)\s*(?:一則|一封)?\s*(?:訊息|簡訊|LINE|line).{0,12}(?:給|給了)|(?:我|玩家).{0,24}(?:撥打|打電話).{0,12}給/i.test(message);

const isLikelyPlayerOriginMessage = (event: StoryPhoneEvent, playerName: string): boolean => {
  const source = `${event.title} ${event.body}`;
  const genericPlayerSource = /(?:玩家|你)(?:的)?(?:簡訊|訊息|LINE)|(?:簡訊|訊息|LINE).{0,12}(?:來自|由)(?:玩家|你)/i.test(source);
  const normalizedSource = source.toLocaleLowerCase();
  const normalizedPlayerName = playerName.toLocaleLowerCase();
  const namedPlayerSource = Boolean(playerName && playerName !== "玩家" && [
    `${normalizedPlayerName}的簡訊`,
    `${normalizedPlayerName}的訊息`,
    `${normalizedPlayerName}的line`,
    `${normalizedPlayerName}傳來`,
    `${normalizedPlayerName}發來`,
    `來自${normalizedPlayerName}`,
    `由${normalizedPlayerName}發送`,
  ].some((token) => normalizedSource.includes(token)));
  return genericPlayerSource || namedPlayerSource;
};

const fallbackBodyForLabel = (label: string): string => {
  if (/(?:最近|最新|收到).*(?:手機)?(?:訊息|簡訊)|(?:手機)?(?:訊息|簡訊).*(?:最近|最新|收到)/.test(label)) {
    return "目前沒有新的手機訊息";
  }
  if (/待辦|未完成事項/.test(label)) return "目前沒有待辦事項";
  return "目前沒有足夠資訊";
};

const promptLabel = (prompt: string, characterName: string, playerName: string): string =>
  (prompt.split("|", 1)[0] || "").trim()
    .replace(/\{CHAR\}/g, characterName)
    .replace(/\{USER\}/g, playerName)
    .slice(0, 80);

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
    suggested_replies: fallbackSuggestedReplies(),
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

  const parsedPhoneEvents: Array<StoryPhoneEvent | null> = [];
  if (Array.isArray(value.phone_events)) {
    for (const item of value.phone_events.slice(0, 8)) {
      const event = asObject(item);
      if (!event || typeof event.event_type !== "string" || !allowedPhoneEventTypes.has(event.event_type)) {
        parsedPhoneEvents.push(null);
        continue;
      }
      const title = boundedText(event.title, 80);
      const body = boundedText(event.body, 600);
      if (!title || !body) {
        parsedPhoneEvents.push(null);
        continue;
      }
      parsedPhoneEvents.push({
        event_type: event.event_type as StoryPhoneEvent["event_type"],
        title,
        body,
      });
    }
  }

  let phoneEvents = parsedPhoneEvents.filter((event): event is StoryPhoneEvent => event !== null);
  const configuredPrompts = (options.configuredPrompts ?? []).map((item) => boundedText(item, 500)).filter(Boolean).slice(0, 8);
  const explicitSend = hasExplicitPhoneSendAction(options.currentUserMessage ?? "");
  const playerName = boundedText(options.playerName, 80) || "玩家";
  if (configuredPrompts.length === 0) {
    phoneEvents = phoneEvents.filter((event) => explicitSend || !isLikelyPlayerOriginMessage(event, playerName));
  } else {
    phoneEvents = configuredPrompts.map((prompt, index) => {
      const label = promptLabel(prompt, boundedText(options.characterName, 80) || "角色", playerName);
      const candidate = parsedPhoneEvents[index] ?? undefined;
      if (!candidate || (!explicitSend && isLikelyPlayerOriginMessage(candidate, playerName))) {
        return { event_type: "notification", title: label, body: fallbackBodyForLabel(label) };
      }
      const candidateBody = candidate.body || fallbackBodyForLabel(label);
      return {
        // Preserve true event types only when the model identifies a new event
        // in this turn. "notification" remains a replaceable configured-field snapshot.
        event_type: candidate.event_type,
        title: label,
        // Status fields are rendered as one concise line; multiple todo items use separators.
        body: candidate.event_type === "notification"
          ? candidateBody.replace(/\s*[\r\n]+\s*/g, "；").slice(0, 600)
          : candidateBody,
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
  const suggestedReplies = validSuggestedReplies.length === 3
    ? validSuggestedReplies
    : fallbackSuggestedReplies();

  return {
    reply,
    affinity_delta: affinityDelta,
    affinity_reason: boundedText(value.affinity_reason, 280),
    phone_events: phoneEvents,
    suggested_replies: suggestedReplies,
  };
}
