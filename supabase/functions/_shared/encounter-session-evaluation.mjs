const RELATIONSHIP_STAGES = new Set([
  "hostile",
  "dislike",
  "wary",
  "first_meeting",
  "acquaintance",
  "close",
  "intimate",
  "special",
]);

const isRecord = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);

const cleanText = (value, maxLength) =>
  typeof value === "string" ? value.trim().slice(0, maxLength) : "";

export function parseEncounterSessionEvaluation(raw) {
  let value;
  try {
    value = typeof raw === "string" ? JSON.parse(raw) : raw;
  } catch {
    return null;
  }
  if (!isRecord(value)) return null;

  const affinityDelta = value.affinity_delta;
  const relationshipStage = value.relationship_stage;
  const memories = value.memories;
  const diarySummary = cleanText(value.diary_summary, 1200);
  const rationale = cleanText(value.rationale, 800);

  if (!Number.isInteger(affinityDelta) || affinityDelta < -100 || affinityDelta > 100) return null;
  if (typeof relationshipStage !== "string" || !RELATIONSHIP_STAGES.has(relationshipStage)) return null;
  if (!Array.isArray(memories) || memories.length > 5) return null;
  if (memories.some((item) => typeof item !== "string" || !item.trim() || item.trim().length > 500)) return null;
  if (diarySummary.length < 1 || rationale.length < 1) return null;

  return {
    affinityDelta,
    relationshipStage,
    memories: memories.map((item) => item.trim()),
    diarySummary,
    rationale,
  };
}

export { RELATIONSHIP_STAGES };
