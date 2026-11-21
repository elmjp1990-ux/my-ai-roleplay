const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function optionalUuid(value) {
  if (value === null || value === undefined || value === "") return null;
  return typeof value === "string" && UUID_PATTERN.test(value) ? value : null;
}

function cleanProviderText(raw) {
  return raw.trim()
    .replace(/^\uFEFF/, "")
    .replace(/<think>[\s\S]*?<\/think>/gi, "")
    .replace(/^\x60{3}(?:json)?\s*/i, "")
    .replace(/\s*\x60{3}$/, "")
    .trim();
}

function extractJsonStringField(text, fieldName) {
  const objectStart = text.indexOf("{");
  if (objectStart < 0) return "";
  const keyIndex = text.indexOf(JSON.stringify(fieldName), objectStart);
  if (keyIndex < 0) return "";
  const colonIndex = text.indexOf(":", keyIndex + fieldName.length + 2);
  if (colonIndex < 0) return "";
  let start = colonIndex + 1;
  while (/\s/.test(text[start] || "")) start += 1;
  if (text[start] !== '"') return "";
  let escaped = false;
  for (let index = start + 1; index < text.length; index += 1) {
    const char = text[index];
    if (escaped) escaped = false;
    else if (char === "\\") escaped = true;
    else if (char === '"') {
      try {
        const value = JSON.parse(text.slice(start, index + 1));
        return typeof value === "string" ? value : "";
      } catch { return ""; }
    }
  }
  return "";
}

function extractJsonIntegerField(text, fieldName) {
  const objectStart = text.indexOf("{");
  if (objectStart < 0) return undefined;
  const keyIndex = text.indexOf(JSON.stringify(fieldName), objectStart);
  if (keyIndex < 0) return undefined;
  const colonIndex = text.indexOf(":", keyIndex + fieldName.length + 2);
  if (colonIndex < 0) return undefined;
  const remainder = text.slice(colonIndex + 1).trimStart();
  const match = remainder.match(/^-?\d+(?=\s*[,}])/);
  return match ? Number(match[0]) : undefined;
}

function parseJsonObject(raw) {
  if (raw && typeof raw === "object" && !Array.isArray(raw)) return raw;
  if (typeof raw !== "string") return null;
  const cleaned = cleanProviderText(raw);
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
    const cleaned = cleanProviderText(raw);
    // Recover only a complete JSON string from the top-level reply field when
    // the provider truncates its envelope. Never expose malformed JSON syntax.
    const recoveredReply = extractJsonStringField(cleaned, "reply");
    if (recoveredReply.trim()) {
      value = {
        reply: recoveredReply,
        affinity_delta: extractJsonIntegerField(cleaned, "affinity_delta"),
        illustration_id: extractJsonStringField(cleaned, "illustration_id"),
        scene_background_id: extractJsonStringField(cleaned, "scene_background_id"),
      };
    } else if (cleaned && !cleaned.startsWith("{") && !cleaned.startsWith("[")) {
      // Some providers return plain text despite JSON mode.
      value = { reply: cleaned };
    }
  }
  if (!value) return null;
  const reply = typeof value.reply === "string" ? value.reply.trim() : "";
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
