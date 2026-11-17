export function parseEncounterTurnOutput(raw) {
  let value;
  try {
    value = JSON.parse(String(raw ?? ""));
  } catch {
    return null;
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const reply = typeof value.reply === "string" ? value.reply.trim() : "";
  const length = Array.from(reply).length;
  if (length < 150 || length > 300) return null;
  return reply;
}
