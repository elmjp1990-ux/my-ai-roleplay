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
  let value = parseJsonObject(raw);
  if (!value && typeof raw === "string") {
    const cleaned = raw.trim().replace(/^\x60{3}(?:json)?\s*/i, "").replace(/\s*\x60{3}$/, "");
    // Some providers return a useful plain-text reply despite JSON mode. Recover
    // only ordinary text; malformed object/array output remains rejected.
    if (cleaned && !cleaned.startsWith("{") && !cleaned.startsWith("[")) {
      value = { reply: cleaned };
    }
  }
  if (!value) return null;
  const reply = typeof value.reply === "string" ? value.reply.trim() : "";
  const length = Array.from(reply).length;
  // Length is a generation target, not a save gate: preserve usable replies
  // even when the model drifts shorter or longer than requested.
  if (!reply) return null;

  const rawSuggestions = Array.isArray(value.suggested_replies ?? value.suggestedReplies)
    ? (value.suggested_replies ?? value.suggestedReplies) : [];
  const suggestedReplies = rawSuggestions.map((item) => typeof item === "string" ? item.trim() : "")
    .filter((item) => {
      const size = Array.from(item).length;
      return size >= 30 && size <= 90;
    }).slice(0, 3);
  // Suggestions are optional. Never invent player choices to fill a panel;
  // missing/invalid items remain absent and the UI shows its empty-state notice.
  const rawDelta = value.affinity_delta ?? value.affinityDelta;
  const affinityDelta = Number.isInteger(rawDelta) && rawDelta >= -3 && rawDelta <= 3 ? rawDelta : 0;
  const illustrationId = optionalUuid(value.illustration_id ?? value.illustrationId);
  const sceneBackgroundId = optionalUuid(value.scene_background_id ?? value.sceneBackgroundId);

  return {
    reply,
    suggestedReplies,
    affinityDelta,
    illustrationId,
    sceneBackgroundId,
  };
}
