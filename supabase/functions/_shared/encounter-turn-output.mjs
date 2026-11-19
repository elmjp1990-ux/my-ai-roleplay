const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function optionalUuid(value) {
  if (value === null || value === undefined || value === "") return null;
  return typeof value === "string" && UUID_PATTERN.test(value) ? value : null;
}

function parseJsonObject(raw) {
  if (raw && typeof raw === "object" && !Array.isArray(raw)) return raw;
  if (typeof raw !== "string") return null;
  const cleaned = raw.trim().replace(/^\x60{3}(?:json)?\s*/i, "").replace(/\s*\x60{3}$/, "");
  try {
    const value = JSON.parse(cleaned);
    return value && typeof value === "object" && !Array.isArray(value) ? value : null;
  } catch {
    const start = cleaned.indexOf("{");
    const end = cleaned.lastIndexOf("}");
    if (start < 0 || end <= start) return null;
    try {
      const value = JSON.parse(cleaned.slice(start, end + 1));
      return value && typeof value === "object" && !Array.isArray(value) ? value : null;
    } catch {
      return null;
    }
  }
}

export function parseEncounterTurnOutput(raw) {
  const value = parseJsonObject(raw);
  if (!value) return null;
  const reply = typeof value.reply === "string" ? value.reply.trim() : "";
  const length = Array.from(reply).length;
  // The prompt targets 150–300 characters. Accept a bounded margin so a
  // slightly short/long valid character reply is not refunded as malformed.
  if (length < 100 || length > 420) return null;

  const rawSuggestions = Array.isArray(value.suggested_replies ?? value.suggestedReplies)
    ? (value.suggested_replies ?? value.suggestedReplies) : [];
  const suggestedReplies = rawSuggestions.map((item) => typeof item === "string" ? item.trim() : "")
    .filter((item) => {
      const size = Array.from(item).length;
      return size >= 30 && size <= 90;
    }).slice(0, 3);
  const illustrationId = optionalUuid(value.illustration_id ?? value.illustrationId);
  const sceneBackgroundId = optionalUuid(value.scene_background_id ?? value.sceneBackgroundId);

  return {
    reply,
    suggestedReplies: suggestedReplies.length === 3 ? suggestedReplies : [],
    illustrationId,
    sceneBackgroundId,
  };
}
