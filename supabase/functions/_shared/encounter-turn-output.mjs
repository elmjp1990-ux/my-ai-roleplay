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

function buildFallbackEncounterSuggestions(reply) {
  const anchor = Array.from(reply.replace(/[\s*「」『』，。！？、,.!?]/g, "")).slice(0, 12).join("") || "剛才的話";
  return [
    `我想再了解你提到的「${anchor}」，可以多告訴我一些當時的情況嗎？`,
    "聽你這麼說，我也想分享我的想法；你願意聽聽我怎麼看這件事嗎？",
    "我想先順著現在的話題陪你聊下去，也想知道接下來你打算怎麼做。",
  ];
}

export function parseEncounterTurnOutput(raw) {
  let value = parseJsonObject(raw);
  if (!value && typeof raw === "string") {
    const cleaned = raw.trim().replace(/^\x60{3}(?:json)?\s*/i, "").replace(/\s*\x60{3}$/, "");
    // Some providers return a useful plain-text reply despite JSON mode. Recover
    // only ordinary text; malformed object/array output remains rejected.
    if (cleaned && !cleaned.startsWith("{") && !cleaned.startsWith("[") &&
        Array.from(cleaned).length >= 60 && Array.from(cleaned).length <= 600) {
      value = { reply: cleaned };
    }
  }
  if (!value) return null;
  const reply = typeof value.reply === "string" ? value.reply.trim() : "";
  const length = Array.from(reply).length;
  // Prompt target is 150–300 characters, but allow shorter/longer valid output
  // so an otherwise coherent reply is not refunded for minor model drift.
  if (length < 60 || length > 600) return null;

  const rawSuggestions = Array.isArray(value.suggested_replies ?? value.suggestedReplies)
    ? (value.suggested_replies ?? value.suggestedReplies) : [];
  const suggestedReplies = rawSuggestions.map((item) => typeof item === "string" ? item.trim() : "")
    .filter((item) => {
      const size = Array.from(item).length;
      return size >= 30 && size <= 90;
    }).slice(0, 3);
  // Optional metadata drift must not discard a complete, usable character reply.
  // DeepSeek can return valid prose while omitting one of the requested JSON fields.
  const finalSuggestions = suggestedReplies.length === 3
    ? suggestedReplies
    : buildFallbackEncounterSuggestions(reply);
  const rawDelta = value.affinity_delta ?? value.affinityDelta;
  const affinityDelta = Number.isInteger(rawDelta) && rawDelta >= -3 && rawDelta <= 3 ? rawDelta : 0;
  const illustrationId = optionalUuid(value.illustration_id ?? value.illustrationId);
  const sceneBackgroundId = optionalUuid(value.scene_background_id ?? value.sceneBackgroundId);

  return {
    reply,
    suggestedReplies: finalSuggestions,
    affinityDelta,
    illustrationId,
    sceneBackgroundId,
  };
}
