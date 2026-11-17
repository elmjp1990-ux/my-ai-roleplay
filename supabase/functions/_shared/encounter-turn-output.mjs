const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function optionalUuid(value) {
  if (value === null || value === undefined || value === "") return null;
  return typeof value === "string" && UUID_PATTERN.test(value) ? value : undefined;
}

export function parseEncounterTurnOutput(raw) {
  let value;
  try {
    value = typeof raw === "string" ? JSON.parse(raw) : raw;
  } catch {
    return null;
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const reply = typeof value.reply === "string" ? value.reply.trim() : "";
  const length = Array.from(reply).length;
  if (length < 150 || length > 300) return null;

  const illustrationId = optionalUuid(value.illustration_id ?? value.illustrationId);
  const sceneBackgroundId = optionalUuid(value.scene_background_id ?? value.sceneBackgroundId);
  if (illustrationId === undefined || sceneBackgroundId === undefined) return null;

  return { reply, illustrationId, sceneBackgroundId };
}
