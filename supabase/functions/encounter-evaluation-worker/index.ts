import { createClient } from "npm:@supabase/supabase-js@2.57.4";
import {
  requestOpenRouterChatCompletion,
  POYOZZ_DEFAULT_CHAT_MODEL,
} from "../_shared/openrouter-chat-completions.ts";
import { parseEncounterSessionEvaluation } from "../_shared/encounter-session-evaluation.mjs";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: CORS });
const asRow = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
const asText = (value: unknown): string => typeof value === "string" ? value.trim() : "";
const MAX_TRANSCRIPT_CHARS = 60_000;
const MAX_TURNS = 1_000;

type ClaimedJob = {
  session_id: string;
  user_id: string;
  character_id: string;
  turn_count: number;
  attempt_count: number;
};

function buildTranscript(
  turnRows: Record<string, unknown>[],
  messages: Record<string, unknown>[],
  openingText: string,
): { transcript: string; includedTurns: number; omittedTurns: number } {
  const byId = new Map(messages.map((message) => [asText(message.id), message]));
  const pairs = turnRows.map((turn) => {
    const userMessage = byId.get(asText(turn.user_message_id));
    const assistantMessage = byId.get(asText(turn.assistant_message_id));
    if (!userMessage || !assistantMessage ||
        userMessage.role !== "user" || assistantMessage.role !== "assistant" ||
        !asText(userMessage.content) || !asText(assistantMessage.content)) {
      throw new Error("encounter_evaluation_message_evidence_incomplete");
    }
    return {
      turnNumber: Number(turn.turn_number),
      user: asText(userMessage.content).slice(0, 2_000),
      assistant: asText(assistantMessage.content).slice(0, 2_000),
    };
  });

  const allLines = pairs.map((pair) =>
    "第" + pair.turnNumber + "回合\n玩家：" + pair.user + "\n角色：" + pair.assistant
  );
  if (openingText && !pairs.some((pair) => pair.assistant === openingText)) {
    allLines.unshift("角色開場\n角色：" + openingText.slice(0, 2_000));
  }

  let lines = allLines;
  let omittedTurns = 0;
  let transcript = lines.join("\n\n");
  if (transcript.length > MAX_TRANSCRIPT_CHARS && lines.length > 20) {
    const first = lines.slice(0, 10);
    const last = lines.slice(-50);
    omittedTurns = Math.max(0, pairs.length - 60);
    lines = [...first, "（中間省略 " + omittedTurns + " 段較早對話；請勿推測未提供的事件。）", ...last];
    transcript = lines.join("\n\n");
  }
  if (transcript.length > MAX_TRANSCRIPT_CHARS) {
    transcript = transcript.slice(-MAX_TRANSCRIPT_CHARS);
  }
  return {
    transcript,
    includedTurns: pairs.length,
    omittedTurns,
  };
}

async function evaluateJob(admin: any, job: ClaimedJob, apiKey: string) {
  const { data: lifecycle, error: lifecycleError } = await admin
    .from("encounter_session_lifecycle")
    .select("session_id,user_id,character_id,status,turn_count,scheduled_end_at,location_key,schedule_snapshot")
    .eq("session_id", job.session_id)
    .maybeSingle();
  if (lifecycleError || !lifecycle) throw new Error("encounter_evaluation_lifecycle_unavailable");
  if (lifecycle.user_id !== job.user_id || lifecycle.character_id !== job.character_id ||
      lifecycle.status !== "ready_to_settle" ||
      new Date(lifecycle.scheduled_end_at).getTime() > Date.now()) {
    throw new Error("encounter_evaluation_lifecycle_not_due");
  }
  if (Number(lifecycle.turn_count) !== Number(job.turn_count)) {
    throw new Error("encounter_evaluation_turn_count_changed");
  }

  const { data: session, error: sessionError } = await admin
    .from("chat_sessions")
    .select("id,user_id,character_id,character_name,character_snapshot,session_data,chat_mode,deleted_at")
    .eq("id", job.session_id)
    .maybeSingle();
  if (sessionError || !session || session.user_id !== job.user_id ||
      session.character_id !== job.character_id || session.chat_mode !== "encounter" ||
      session.deleted_at !== null) {
    throw new Error("encounter_evaluation_session_unavailable");
  }

  const { data: currentState, error: stateError } = await admin
    .from("encounter_character_state")
    .select("affinity,relationship_stage")
    .eq("user_id", job.user_id)
    .eq("character_id", job.character_id)
    .maybeSingle();
  if (stateError) throw new Error("encounter_evaluation_relationship_state_unavailable");

  const currentAffinity = Number.isInteger(currentState?.affinity) ? currentState.affinity : 0;
  const currentStage = asText(currentState?.relationship_stage) || "first_meeting";
  if (Number(job.turn_count) === 0) {
    const { data, error } = await admin.rpc("settle_encounter_session", {
      p_session_id: job.session_id,
      p_affinity_delta: 0,
      p_relationship_stage: currentStage,
      p_memories: [],
      p_evaluation: {
        source: "encounter_session_evaluation_worker",
        model: "not_called_no_turns",
        turn_count: 0,
        diary_summary: "本次相遇沒有進行對話。",
      },
    });
    if (error || !data?.settled) throw new Error("encounter_empty_session_settlement_failed");
    return { sessionId: job.session_id, settled: true, noTurns: true, result: data.result };
  }

  if (!apiKey) throw new Error("encounter_evaluation_provider_not_configured");
  if (Number(job.turn_count) > MAX_TURNS) throw new Error("encounter_evaluation_turn_limit_exceeded");
  const { data: turns, error: turnsError } = await admin
    .from("encounter_session_turns")
    .select("turn_number,user_message_id,assistant_message_id")
    .eq("session_id", job.session_id)
    .order("turn_number", { ascending: true })
    .limit(MAX_TURNS);
  if (turnsError || !Array.isArray(turns) || turns.length !== Number(job.turn_count)) {
    throw new Error("encounter_evaluation_turn_evidence_unavailable");
  }

  const messageIds = turns.flatMap((turn: Record<string, unknown>) => [
    asText(turn.user_message_id), asText(turn.assistant_message_id),
  ]).filter(Boolean);
  const { data: messages, error: messagesError } = await admin
    .from("chat_messages")
    .select("id,session_id,role,content,deleted_at")
    .in("id", messageIds)
    .eq("session_id", job.session_id)
    .is("deleted_at", null);
  if (messagesError || !Array.isArray(messages) || messages.length !== messageIds.length) {
    throw new Error("encounter_evaluation_message_evidence_unavailable");
  }

  const snapshot = asRow(session.character_snapshot);
  const sessionData = asRow(session.session_data);
  const encounterData = asRow(sessionData.encounter);
  const openingMessage = asRow(sessionData.openingMessage);
  const openingText = asText(openingMessage.text);
  const schedule = asRow(lifecycle.schedule_snapshot);
  const transcript = buildTranscript(turns as Record<string, unknown>[], messages, openingText);

  const system = [
    "你是 POYOZZ 相遇模式的整場互動評估器，不是角色扮演者。",
    "只根據提供的實際對話評估玩家與角色在本次相遇中的關係變化；不可虛構未發生的事件，也不可把角色單方面的台詞當成玩家已同意或已做出的行動。",
    "請評估整體互動品質、互相尊重、信任、衝突、界線、情緒支持與關係發展。正負向都可以，沒有足夠互動時應接近 0。",
    "affinity_delta 是本次整場相遇的總變化，整數 -100 至 100；relationship_stage 必須從 hostile、dislike、wary、first_meeting、acquaintance、close、intimate、special 選一個，並與本次結束後的 affinity 一致。",
    "memories 僅保留 0 至 5 條對未來互動有幫助、由實際對話確認的長期事實；不得記錄推測、短暫瑣事、敏感個資或角色未確認的玩家資訊。",
    "diary_summary 是 1 至 1200 字元的繁體中文相遇摘要。rationale 是簡短、可稽核的結論理由，不要輸出隱藏思考過程。",
    "只輸出 JSON object：{\"affinity_delta\":整數,\"relationship_stage\":\"八種階段之一\",\"memories\":[\"記憶\"] ,\"diary_summary\":\"摘要\",\"rationale\":\"簡短理由\"}。不得輸出 Markdown 或其他欄位。",
  ].join("\n");
  const user = [
    "角色：" + (asText(snapshot.name) || asText(session.character_name) || "角色"),
    "公開介紹：" + asText(snapshot.intro),
    "角色風格：" + asText(snapshot.style),
    "角色標籤：" + (Array.isArray(snapshot.tags) ? snapshot.tags.join("、") : ""),
    "本次場景：" + asText(schedule.location_key || lifecycle.location_key),
    "本次活動：" + asText(schedule.activity),
    "目前好感度：" + currentAffinity,
    "目前關係階段：" + currentStage,
    "本次有效回合數：" + job.turn_count,
    "以下為本次相遇對話（可能包含為控制長度而省略的中間段落）：",
    transcript.transcript,
  ].join("\n\n");

  const response = await requestOpenRouterChatCompletion({
    messages: [{ role: "system", content: system }, { role: "user", content: user }],
    apiKey,
    model: POYOZZ_DEFAULT_CHAT_MODEL,
    timeoutMs: 55_000,
    temperature: 0.2,
    responseFormat: { type: "json_object" },
  });
  if (response.result.kind !== "generated") {
    throw new Error("encounter_evaluation_provider_" + response.result.kind);
  }
  const evaluation = parseEncounterSessionEvaluation(response.result.text);
  if (!evaluation) throw new Error("encounter_evaluation_output_invalid");

  const { data: settled, error: settlementError } = await admin.rpc("settle_encounter_session", {
    p_session_id: job.session_id,
    p_affinity_delta: evaluation.affinityDelta,
    p_relationship_stage: evaluation.relationshipStage,
    p_memories: evaluation.memories,
    p_evaluation: {
      source: "encounter_session_evaluation_worker",
      model: response.model || POYOZZ_DEFAULT_CHAT_MODEL,
      turn_count: job.turn_count,
      included_turn_count: transcript.includedTurns,
      omitted_turn_count: transcript.omittedTurns,
      diary_summary: evaluation.diarySummary,
      rationale: evaluation.rationale,
      provider_request_id: response.requestId || null,
    },
  });
  if (settlementError || !settled?.settled) {
    throw new Error("encounter_evaluation_settlement_failed");
  }
  return { sessionId: job.session_id, settled: true, idempotent: settled.idempotent === true, result: settled.result };
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")?.trim();
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim();
  const openRouterKey = Deno.env.get("OPENROUTER_API_KEY")?.trim() || "";
  if (!url || !serviceRoleKey) return json({ error: "server_not_configured" }, 503);
  if (request.headers.get("Authorization") !== "Bearer " + serviceRoleKey) {
    return json({ error: "service_role_required" }, 401);
  }
  let requestedLimit = 1;
  try {
    const body = await request.json();
    if (body && Number.isInteger(body.limit)) requestedLimit = Math.min(Math.max(body.limit, 1), 3);
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const admin = createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: claimed, error: claimError } = await admin.rpc("claim_encounter_evaluation_jobs", {
    p_limit: requestedLimit,
  });
  if (claimError) return json({ error: "evaluation_job_claim_failed" }, 503);
  const jobs = Array.isArray(claimed) ? claimed as ClaimedJob[] : [];
  const results: Record<string, unknown>[] = [];

  for (const job of jobs) {
    try {
      results.push(await evaluateJob(admin, job, openRouterKey));
    } catch (error) {
      const code = String(error instanceof Error ? error.message : "evaluation_failed").slice(0, 120);
      console.error("Encounter evaluation job failed:", job.session_id, code);
      const { error: failError } = await admin.rpc("fail_encounter_evaluation_job", {
        p_session_id: job.session_id,
        p_error: code,
      });
      results.push({ sessionId: job.session_id, settled: false, error: failError ? "job_failure_state_unconfirmed" : code });
    }
  }

  return json({
    status: "completed",
    claimed: jobs.length,
    settled: results.filter((result) => result.settled === true).length,
    results,
  });
});
