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

/**
 * Parses the single-call Story response envelope.
 * Invalid or legacy plain-text responses remain usable as roleplay replies,
 * but produce no side effects rather than guessing at affinity or phone events.
 */
export function parseStoryTurnEnvelope(raw: string): StoryTurnEnvelope {
  const fallback: StoryTurnEnvelope = {
    reply: raw.trim(),
    affinity_delta: 0,
    affinity_reason: "",
    phone_events: [],
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
  const affinityDelta = Number.isInteger(rawDelta) && Number(rawDelta) >= -3 && Number(rawDelta) <= 3
    ? Number(rawDelta)
    : 0;

  const phoneEvents: StoryPhoneEvent[] = [];
  if (Array.isArray(value.phone_events)) {
    for (const item of value.phone_events.slice(0, 3)) {
      const event = asObject(item);
      if (!event || typeof event.event_type !== "string" || !allowedPhoneEventTypes.has(event.event_type)) continue;
      const title = boundedText(event.title, 80);
      const body = boundedText(event.body, 600);
      if (!title || !body) continue;
      phoneEvents.push({
        event_type: event.event_type as StoryPhoneEvent["event_type"],
        title,
        body,
      });
    }
  }

  return {
    reply,
    affinity_delta: affinityDelta,
    affinity_reason: boundedText(value.affinity_reason, 280),
    phone_events: phoneEvents,
  };
}
