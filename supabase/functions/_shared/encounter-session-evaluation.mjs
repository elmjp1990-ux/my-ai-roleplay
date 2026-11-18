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


const MAX_TRANSCRIPT_CHARS = 60_000;
const MAX_TRANSCRIPT_MESSAGE_CHARS = 450;
const transcriptText = (value) => typeof value === "string" ? value.trim() : "";

export function buildEncounterEvaluationTranscript(turnRows, messages, openingText = "") {
  const byId = new Map((Array.isArray(messages) ? messages : []).map((message) => [
    transcriptText(message?.id), message,
  ]));
  const pairs = (Array.isArray(turnRows) ? turnRows : []).map((turn) => {
    const userMessage = byId.get(transcriptText(turn?.user_message_id));
    const assistantMessage = byId.get(transcriptText(turn?.assistant_message_id));
    if (!userMessage || !assistantMessage ||
        userMessage.role !== "user" || assistantMessage.role !== "assistant" ||
        !transcriptText(userMessage.content) || !transcriptText(assistantMessage.content)) {
      throw new Error("encounter_evaluation_message_evidence_incomplete");
    }
    return {
      turnNumber: Number(turn.turn_number),
      user: transcriptText(userMessage.content).slice(0, MAX_TRANSCRIPT_MESSAGE_CHARS),
      assistant: transcriptText(assistantMessage.content).slice(0, MAX_TRANSCRIPT_MESSAGE_CHARS),
    };
  });

  const allLines = pairs.map((pair) =>
    "第" + pair.turnNumber + "回合\\n玩家：" + pair.user + "\\n角色：" + pair.assistant
  );
  const opening = transcriptText(openingText).slice(0, MAX_TRANSCRIPT_MESSAGE_CHARS);
  if (opening && !pairs.some((pair) => pair.assistant === opening)) {
    allLines.unshift("角色開場\\n角色：" + opening);
  }

  let lines = allLines;
  let omittedTurns = 0;
  let transcript = lines.join("\\n\\n");
  if (transcript.length > MAX_TRANSCRIPT_CHARS && lines.length > 20) {
    const first = lines.slice(0, 10);
    const remaining = lines.slice(first.length);
    const last = remaining.slice(-50);
    omittedTurns = Math.max(0, remaining.length - last.length);
    lines = [
      ...first,
      ...(omittedTurns ? ["（中間省略 " + omittedTurns + " 段較早對話；請勿推測未提供的事件。）"] : []),
      ...last,
    ];
    transcript = lines.join("\\n\\n");
  }
  if (transcript.length > MAX_TRANSCRIPT_CHARS) {
    throw new Error("encounter_evaluation_transcript_limit_exceeded");
  }
  return {
    transcript,
    includedTurns: pairs.length - omittedTurns,
    omittedTurns,
  };
}
