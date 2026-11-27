import { detectPlayerSummaryLanguage } from "./story-summary-language.ts";
import { requestOpenRouterChatCompletion } from "./openrouter-chat-completions.ts";
import { asRecord as row, asTrimmedString as str } from "./ai-value-utils.ts";
import { recordAiGenerationDiagnostic, updateAiGenerationDiagnostic } from "./ai-generation-diagnostics.ts";

type DbRow = Record<string, unknown>;
const SUMMARY_MODEL = "openai/gpt-oss-20b";
const SUMMARY_INTERVAL = 5;
function normalizeStoryMemorySummaryText(value: unknown): string {
  const compact = str(value).replace(/\s+/g, " ").trim();
  const chars = Array.from(compact);
  if (chars.length < 30) return "";
  if (chars.length <= 100) return compact;
  const clipped = chars.slice(0, 100).join("");
  const sentenceEnd = Math.max(...["。", "！", "？", "!", "?"].map(mark => clipped.lastIndexOf(mark)));
  return (sentenceEnd >= 29 ? clipped.slice(0, sentenceEnd + 1) : clipped).trim();
}

const usageSnapshot = (usage: DbRow) => {
  const numeric = (value: unknown): number | null => {
    if (value === null || value === undefined || value === "") return null;
    const parsed = Number(value);
    return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
  };
  return {
    prompt_tokens: numeric(usage.prompt_tokens),
    completion_tokens: numeric(usage.completion_tokens),
    total_tokens: numeric(usage.total_tokens),
    cost_usd: numeric(usage.cost),
  };
};

export async function recordChatModelUsage(
  admin: any,
  input: {
    userId: string;
    sessionId: string;
    turnId: string;
    assistantMessageId: string | null;
    requestedModel: string;
    providerResponse: { model: string; provider: string; requestId: string; usage: DbRow };
    requestStatus: "completed" | "failed";
  },
): Promise<void> {
  const usage = usageSnapshot(input.providerResponse.usage);
  const requestId = /^[A-Za-z0-9._:-]{1,128}$/.test(input.providerResponse.requestId)
    ? input.providerResponse.requestId
    : null;
  const { error } = await admin.from("ai_model_usage").insert({
    user_id: input.userId,
    session_id: input.sessionId,
    turn_id: input.turnId,
    assistant_message_id: input.assistantMessageId,
    generation_type: "chat_response",
    model: input.providerResponse.model || input.requestedModel,
    provider: input.providerResponse.provider || "deepinfra",
    gateway_request_id: requestId,
    prompt_tokens: usage.prompt_tokens,
    completion_tokens: usage.completion_tokens,
    total_tokens: usage.total_tokens,
    cost_usd: usage.cost_usd,
    status: input.requestStatus,
    processed_at: new Date().toISOString(),
  });
  if (error) console.error("AI usage record write failed:", error.code || "database_error");
}

type MemorySummaryUsage = ReturnType<typeof usageSnapshot>;

async function generateMemorySummary(
  messages: Array<{ role: "system" | "user"; content: string }>,
  apiKey: string,
  previousBatch: DbRow | null,
) {
  const response = await requestOpenRouterChatCompletion({
    messages,
    apiKey,
    model: SUMMARY_MODEL,
    provider: "deepinfra",
    disableProviderFallback: true,
    retrySameProviderOnRateLimit: true,
    timeoutMs: 45_000,
    temperature: 0.2,
    responseFormat: { type: "json_object" },
  });
  const usage = usageSnapshot(response.usage);
  const priorUsage = usageSnapshot({
    prompt_tokens: previousBatch?.prompt_tokens,
    completion_tokens: previousBatch?.completion_tokens,
    total_tokens: previousBatch?.total_tokens,
    cost: previousBatch?.cost_usd,
  });
  const accumulatedUsage: MemorySummaryUsage = {
    prompt_tokens: priorUsage.prompt_tokens === null && usage.prompt_tokens === null ? null : (priorUsage.prompt_tokens || 0) + (usage.prompt_tokens || 0),
    completion_tokens: priorUsage.completion_tokens === null && usage.completion_tokens === null ? null : (priorUsage.completion_tokens || 0) + (usage.completion_tokens || 0),
    total_tokens: priorUsage.total_tokens === null && usage.total_tokens === null ? null : (priorUsage.total_tokens || 0) + (usage.total_tokens || 0),
    cost_usd: priorUsage.cost_usd === null && usage.cost_usd === null ? null : (priorUsage.cost_usd || 0) + (usage.cost_usd || 0),
  };
  const requestId = /^[A-Za-z0-9._:-]{1,128}$/.test(response.requestId) ? response.requestId : null;
  const rawOutput = response.result.kind === "generated" ? response.result.text.trim() : "";
  let summary = "";
  let affinityCorrection = 0;
  let affinityReason = "";
  try {
    const parsed = JSON.parse(rawOutput) as Record<string, unknown>;
    summary = normalizeStoryMemorySummaryText(parsed.summary);
    const correction = parsed.affinity_correction;
    if (typeof correction === "number" && Number.isInteger(correction) && correction >= -5 && correction <= 5) {
      affinityCorrection = correction;
    }
    affinityReason = typeof parsed.affinity_reason === "string" ? parsed.affinity_reason.trim().slice(0, 280) : "";
  } catch {
    // Legacy plain-text summaries remain usable, but cannot adjust affinity.
    summary = normalizeStoryMemorySummaryText(rawOutput);
  }
  return { response, summary, affinityCorrection, affinityReason, requestId, usage: accumulatedUsage };
}

function summaryUsageMetadata(generation: Awaited<ReturnType<typeof generateMemorySummary>>) {
  return {
    model: generation.response.model,
    provider: generation.response.provider,
    gateway_request_id: generation.requestId,
    prompt_tokens: generation.usage.prompt_tokens,
    completion_tokens: generation.usage.completion_tokens,
    total_tokens: generation.usage.total_tokens,
    cost_usd: generation.usage.cost_usd,
  };
}

export async function processDueStoryMemorySummary(
  admin: any,
  session: DbRow,
  userId: string,
  apiKey: string,
): Promise<void> {
  const sessionId = str(session.id);
  const { count: settledCount, error: countError } = await admin
    .from("chat_turn_charges")
    .select("turn_id", { count: "exact", head: true })
    .eq("session_id", sessionId)
    .eq("user_id", userId)
    .eq("status", "settled");
  if (countError) throw new Error("memory_summary_turn_count_failed");
  const eligibleBatchCount = Math.floor(Number(settledCount || 0) / SUMMARY_INTERVAL);
  if (eligibleBatchCount < 1) return;

  const { data: existingRows, error: existingError } = await admin
    .from("ai_model_usage")
    .select("id,batch_number,status,summary,created_at,prompt_tokens,completion_tokens,total_tokens,cost_usd")
    .eq("session_id", sessionId)
    .eq("generation_type", "memory_summary")
    .order("batch_number", { ascending: true });
  if (existingError) throw new Error("memory_summary_batch_lookup_failed");
  const rows = Array.isArray(existingRows) ? existingRows : [];

  // Process the oldest incomplete batch. Later turns retry a failed batch first.
  let batchNumber = 0;
  let existingBatch: DbRow | null = null;
  for (let candidate = 1; candidate <= eligibleBatchCount; candidate++) {
    const found = rows.find((item: DbRow) => Number(item.batch_number) === candidate) || null;
    if (found?.status === "completed") {
      const existingSummary = str(found.summary);
      const existingSummaryLength = Array.from(existingSummary).length;
      if (existingSummaryLength >= 30 && existingSummaryLength <= 100 && normalizeStoryMemorySummaryText(existingSummary)) continue;
      // Reclaim completed summaries outside the current 30–100 character contract.
      // The next turn regenerates this exact five-turn batch using the current prompt.
      const { data: released, error: releaseError } = await admin
        .from("ai_model_usage")
        .update({ status: "failed", processed_at: new Date().toISOString() })
        .eq("id", str(found.id))
        .eq("status", "completed")
        .select("id")
        .maybeSingle();
      if (releaseError || !released) return;
      existingBatch = { ...found, status: "failed" };
    } else if (found?.status === "processing") {
      const createdAt = Date.parse(str(found.created_at));
      if (!Number.isFinite(createdAt) || Date.now() - createdAt < 120_000) return;
      const { data: released, error: releaseError } = await admin
        .from("ai_model_usage")
        .update({ status: "failed" })
        .eq("id", str(found.id))
        .eq("status", "processing")
        .select("id")
        .maybeSingle();
      if (releaseError || !released) return;
      existingBatch = { ...found, status: "failed" };
    } else {
      existingBatch = found;
    }
    batchNumber = candidate;
    break;
  }
  if (!batchNumber) return;

  const offset = (batchNumber - 1) * SUMMARY_INTERVAL;
  const { data: turns, error: turnsError } = await admin
    .from("chat_turn_charges")
    .select("turn_id,user_message_id,assistant_message_id,created_at")
    .eq("session_id", sessionId)
    .eq("user_id", userId)
    .eq("status", "settled")
    .order("created_at", { ascending: true })
    .range(offset, offset + SUMMARY_INTERVAL - 1);
  if (turnsError || !Array.isArray(turns) || turns.length !== SUMMARY_INTERVAL) {
    throw new Error("memory_summary_source_turns_unavailable");
  }
  const sourceTurnIds = turns.map((turn: DbRow) => str(turn.turn_id));
  const messageIds = turns.flatMap((turn: DbRow) => [
    str(turn.user_message_id), str(turn.assistant_message_id),
  ]).filter(Boolean);
  if (messageIds.length !== SUMMARY_INTERVAL * 2) {
    throw new Error("memory_summary_source_message_ids_invalid");
  }

  let batchRowId = str(existingBatch?.id);
  if (existingBatch?.status === "failed") {
    const { data: claimed, error: claimError } = await admin
      .from("ai_model_usage")
      .update({ status: "processing", summary: null, processed_at: null, source_turn_ids: sourceTurnIds })
      .eq("id", batchRowId)
      .eq("status", "failed")
      .select("id")
      .maybeSingle();
    if (claimError || !claimed) return;
    batchRowId = str(claimed.id);
  } else if (!existingBatch) {
    const { data: created, error: createError } = await admin
      .from("ai_model_usage")
      .insert({
        user_id: userId,
        session_id: sessionId,
        generation_type: "memory_summary",
        batch_number: batchNumber,
        source_turn_ids: sourceTurnIds,
        model: SUMMARY_MODEL,
        status: "processing",
      })
      .select("id")
      .maybeSingle();
    if (createError || !created) {
      if (createError?.code === "23505") return;
      throw new Error("memory_summary_batch_create_failed");
    }
    batchRowId = str(created.id);
  }
  if (!batchRowId) return;

  const { data: sourceMessages, error: messagesError } = await admin
    .from("chat_messages")
    .select("id,role,content,created_at")
    .eq("session_id", sessionId)
    .is("deleted_at", null)
    .in("id", messageIds)
    .order("created_at", { ascending: true });
  if (messagesError || !Array.isArray(sourceMessages) || sourceMessages.length !== messageIds.length) {
    await admin.from("ai_model_usage").update({
      status: "failed", processed_at: new Date().toISOString(),
    }).eq("id", batchRowId).eq("status", "processing");
    throw new Error("memory_summary_source_messages_unavailable");
  }

  const previousBatch = rows
    .filter((item: DbRow) =>
      Number(item.batch_number) < batchNumber &&
      item.status === "completed" &&
      Boolean(str(item.summary))
    )
    .sort((left: DbRow, right: DbRow) => Number(right.batch_number) - Number(left.batch_number))[0] || null;
  const sessionData = row(session.session_data);
  // If summary batches exist but were intentionally cleared by the user,
  // never resurrect the stale session_data.summary fallback.
  const previousSummary = str(previousBatch?.summary) ||
    (rows.length === 0 ? str(sessionData.summary) : "");
  const characterName = str(session.character_name) || "角色";
  const playerMessages = sourceMessages.filter((message: DbRow) => message.role === "user").map((message: DbRow) => str(message.content));
  const summaryLanguage = detectPlayerSummaryLanguage(playerMessages);
  const transcript = sourceMessages.map((message: DbRow) =>
    (message.role === "assistant" ? characterName : "玩家") + "：" + str(message.content)
  ).join("\n");
  const { data: relationshipState, error: relationshipStateError } = await admin
    .from("story_relationship_states")
    .select("affinity,relationship_stage")
    .eq("session_id", sessionId)
    .eq("user_id", userId)
    .maybeSingle();
  if (relationshipStateError || !relationshipState) {
    await admin.from("ai_model_usage").update({ status: "failed", processed_at: new Date().toISOString() })
      .eq("id", batchRowId).eq("status", "processing");
    throw new Error("story_relationship_state_unavailable");
  }

  let generated;
  try {
    generated = await generateMemorySummary([
      {
        role: "system",
        content: [
          "你是 POYOZZ 的長期劇情記憶整理器與關係校正器。每次只整理本批新增的五個已完成回合，產生一則獨立的本批重點摘要，供角色下次接續故事使用。",
          "只輸出 JSON object：{\"summary\":\"30～100 個中文字的本批摘要\",\"affinity_correction\":0,\"affinity_reason\":\"校正理由\"}。不要 Markdown 或其他文字。",
          "摘要目標為 30～100 字，單一精簡段落，不要標題、條列、分析或補充說明。摘要必須使用玩家本批對話主要輸入語言及文字系統；本批判定語言為：" + summaryLanguage + "。嚴禁將玩家使用的繁體中文轉成簡體中文，也不可自行固定使用中文；若玩家使用英文、日文、韓文或其他語言，摘要就用該語言。只摘要本批五回合新發生的重點，不要把前一批摘要的 1～5 回合事件再次寫入；既有摘要只供理解長期背景，除非本批有明確更新，否則不要重述。",
          "好感度校正不是把這五回合的變化重新累加。每回合好感度已即時微調；請檢視五回合完整互動後，判斷目前累積值是否需要小幅修正，只回傳 -5 到 5 的整數 correction。若逐回合評估合理就填 0；不可把五回合淨變化再加一次，也不可因單次甜蜜互動直接跳級。",
          "優先保留玩家明確偏好、角色關係變化、重要共同事件、承諾、界線、情緒轉折，以及尚未完成或下次要接續的事情。",
          "只記錄確實發生或明確約定的內容。不可推測、補造事件、替玩家決定想法或行動，也不可把角色提出但未完成的事寫成已完成。",
          "若新對話明確更正舊記憶，以玩家最新明確更正為準。不要因追求精簡而遺失重要承諾或未完成事項。",
        ].join("\n"),
      },
      {
        role: "user",
        content: "【既有記憶摘要（僅供背景參照，不可重複寫入本批摘要）】\n" + (previousSummary || "尚無既有摘要") +
          "\n\n【目前好感度】" + String(relationshipState.affinity) + "；目前關係階段：" + str(relationshipState.relationship_stage) +
          "\n\n【本次新增的五回合對話】\n" + transcript +
          "\n\n請依指定 JSON 格式輸出只涵蓋本批新增五回合的摘要，以及必要的好感度小幅校正；不要重述既有摘要。",
      },
    ], apiKey, existingBatch);
  } catch {
    await admin.from("ai_model_usage").update({
      status: "failed", processed_at: new Date().toISOString(),
    }).eq("id", batchRowId).eq("status", "processing");
    throw new Error("memory_summary_provider_request_failed");
  }

  const { summary, affinityCorrection, affinityReason } = generated;
  const response = generated.response;
  const diagnosticId = await recordAiGenerationDiagnostic(admin, {
    generationType: "memory_summary", userId, characterId: str(session.character_id),
    sessionId, batchNumber, model: response.model, provider: response.provider,
    requestId: response.requestId, httpStatus: response.httpStatus, finishReason: response.finishReason,
    responseContentType: response.responseContentType, responseBodyLength: response.responseBodyLength,
    responseParsed: response.responseParsed,
    rawOutputText: response.rawOutputText || (response.result.kind === "generated" ? response.result.text : ""),
    rawResponseBody: response.rawResponseBody,
    refusalText: response.rawRefusalText, usage: response.usage,
    status: summary && response.result.kind === "generated" ? "received" : "failed",
    failureStage: summary && response.result.kind === "generated" ? null : "summary_output_validation",
    failureCode: summary ? null : response.result.kind === "provider_error" ? response.result.code :
      response.result.kind === "content_rejected" ? "provider_content_rejected" : "memory_summary_invalid",
  });
  if (response.httpStatus < 200 || response.httpStatus >= 300 || !summary) {
    await updateAiGenerationDiagnostic(admin, diagnosticId, { status: "failed", failureStage: "summary_output_validation", failureCode: "memory_summary_invalid" });
    await admin.from("ai_model_usage").update({
      status: "failed",
      ...summaryUsageMetadata(generated),
      processed_at: new Date().toISOString(),
    }).eq("id", batchRowId).eq("status", "processing");
    return;
  }

  const { error: relationshipBatchError } = await admin.rpc("complete_story_relationship_batch", {
    p_session_id: sessionId,
    p_user_id: userId,
    p_character_id: session.character_id ?? null,
    p_batch_number: batchNumber,
    p_source_turn_ids: sourceTurnIds,
    p_summary: summary,
    p_affinity_delta: affinityCorrection,
    p_evaluation: { reason: affinityReason, source: "five_turn_summary_calibration" },
  });
  if (relationshipBatchError) {
    await updateAiGenerationDiagnostic(admin, diagnosticId, { status: "failed", failureStage: "summary_persistence", failureCode: "story_relationship_batch_persist_failed" });
    await admin.from("ai_model_usage").update({ status: "failed", processed_at: new Date().toISOString() })
      .eq("id", batchRowId).eq("status", "processing");
    throw new Error("story_relationship_batch_persist_failed");
  }

  const { error: completeError } = await admin.from("ai_model_usage").update({
    status: "completed",
    summary,
    ...summaryUsageMetadata(generated),
    processed_at: new Date().toISOString(),
  }).eq("id", batchRowId).eq("status", "processing");
  if (completeError) {
    await updateAiGenerationDiagnostic(admin, diagnosticId, { status: "failed", failureStage: "summary_persistence", failureCode: "memory_summary_result_persist_failed" });
    throw new Error("memory_summary_result_persist_failed");
  }
  await updateAiGenerationDiagnostic(admin, diagnosticId, { status: "completed", failureStage: null, failureCode: null });
}

/**
 * Group Story memory uses the same five-completed-turn cadence and summary model
 * as single Story chats. Group transcripts are read from durable group turn rows;
 * raw prompts and provider output are never copied into operational logs.
 */
export async function processDueGroupMemorySummary(
  admin: any,
  groupId: string,
  userId: string,
  apiKey: string,
): Promise<void> {
  const { count: completedTurnCount, error: countError } = await admin
    .from("chat_group_turns")
    .select("id", { count: "exact", head: true })
    .eq("group_id", groupId)
    .eq("user_id", userId)
    .eq("status", "completed");
  if (countError) throw new Error("group_memory_summary_turn_count_failed");
  const eligibleBatchCount = Math.floor(Number(completedTurnCount || 0) / SUMMARY_INTERVAL);
  if (eligibleBatchCount < 1) return;

  const { data: existingRows, error: existingError } = await admin
    .from("chat_group_memory_summaries")
    .select("id,batch_number,status,summary,created_at,prompt_tokens,completion_tokens,total_tokens,cost_usd")
    .eq("group_id", groupId)
    .eq("user_id", userId)
    .order("batch_number", { ascending: true });
  if (existingError) throw new Error("group_memory_summary_batch_lookup_failed");
  const rows = Array.isArray(existingRows) ? existingRows : [];

  let batchNumber = 0;
  let existingBatch: DbRow | null = null;
  for (let candidate = 1; candidate <= eligibleBatchCount; candidate++) {
    const found = rows.find((item: DbRow) => Number(item.batch_number) === candidate) || null;
    if (found?.status === "completed") {
      const existingSummary = str(found.summary);
      const existingSummaryLength = Array.from(existingSummary).length;
      if (existingSummaryLength >= 30 && existingSummaryLength <= 100 && normalizeStoryMemorySummaryText(existingSummary)) continue;
      // Reclaim older completed summaries outside the current 30–100 character contract.
      const { data: released, error: releaseError } = await admin
        .from("chat_group_memory_summaries")
        .update({ status: "failed", processed_at: new Date().toISOString() })
        .eq("id", str(found.id))
        .eq("status", "completed")
        .select("id")
        .maybeSingle();
      if (releaseError || !released) return;
      existingBatch = { ...found, status: "failed" };
    } else if (found?.status === "processing") {
      const createdAt = Date.parse(str(found.created_at));
      if (!Number.isFinite(createdAt) || Date.now() - createdAt < 120_000) return;
      const { data: released, error: releaseError } = await admin
        .from("chat_group_memory_summaries")
        .update({ status: "failed" })
        .eq("id", str(found.id))
        .eq("status", "processing")
        .select("id")
        .maybeSingle();
      if (releaseError || !released) return;
      existingBatch = { ...found, status: "failed" };
    } else {
      existingBatch = found;
    }
    batchNumber = candidate;
    break;
  }
  if (!batchNumber) return;

  const offset = (batchNumber - 1) * SUMMARY_INTERVAL;
  const { data: turns, error: turnsError } = await admin
    .from("chat_group_turns")
    .select("id,request_content,created_at,completed_at")
    .eq("group_id", groupId)
    .eq("user_id", userId)
    .eq("status", "completed")
    .order("created_at", { ascending: true })
    .order("id", { ascending: true })
    .range(offset, offset + SUMMARY_INTERVAL - 1);
  if (turnsError || !Array.isArray(turns) || turns.length !== SUMMARY_INTERVAL) {
    throw new Error("group_memory_summary_source_turns_unavailable");
  }
  const sourceTurnIds = turns.map((turn: DbRow) => str(turn.id)).filter(Boolean);
  if (sourceTurnIds.length !== SUMMARY_INTERVAL) {
    throw new Error("group_memory_summary_source_turn_ids_invalid");
  }

  let batchRowId = str(existingBatch?.id);
  if (existingBatch?.status === "failed") {
    const { data: claimed, error: claimError } = await admin
      .from("chat_group_memory_summaries")
      .update({
        status: "processing",
        summary: null,
        processed_at: null,
        source_turn_ids: sourceTurnIds,
      })
      .eq("id", batchRowId)
      .eq("status", "failed")
      .select("id")
      .maybeSingle();
    if (claimError || !claimed) return;
    batchRowId = str(claimed.id);
  } else if (!existingBatch) {
    const { data: created, error: createError } = await admin
      .from("chat_group_memory_summaries")
      .insert({
        group_id: groupId,
        user_id: userId,
        batch_number: batchNumber,
        source_turn_ids: sourceTurnIds,
        model: SUMMARY_MODEL,
        status: "processing",
      })
      .select("id")
      .maybeSingle();
    if (createError || !created) {
      if (createError?.code === "23505") return;
      throw new Error("group_memory_summary_batch_create_failed");
    }
    batchRowId = str(created.id);
  }
  if (!batchRowId) return;

  const { data: sourceMessages, error: messagesError } = await admin
    .from("chat_group_messages")
    .select("turn_id,speaker_type,speaker_snapshot,content,created_at,sequence_no")
    .eq("group_id", groupId)
    .is("deleted_at", null)
    .in("turn_id", sourceTurnIds)
    .order("created_at", { ascending: true })
    .order("sequence_no", { ascending: true });
  if (messagesError || !Array.isArray(sourceMessages) ||
      !sourceTurnIds.every((turnId) => sourceMessages.some((message: DbRow) => str(message.turn_id) === turnId))) {
    await admin.from("chat_group_memory_summaries").update({
      status: "failed", processed_at: new Date().toISOString(),
    }).eq("id", batchRowId).eq("status", "processing");
    throw new Error("group_memory_summary_source_messages_unavailable");
  }

  const previousBatch = rows
    .filter((item: DbRow) =>
      Number(item.batch_number) < batchNumber &&
      item.status === "completed" &&
      Boolean(str(item.summary))
    )
    .sort((left: DbRow, right: DbRow) => Number(right.batch_number) - Number(left.batch_number))[0] || null;
  const previousSummary = str(previousBatch?.summary);
  const transcript = sourceMessages.map((message: DbRow) => {
    const speaker = message.speaker_type === "user"
      ? "玩家"
      : str(row(message.speaker_snapshot).name) || "角色";
    const content = str(message.content) === "__GROUP_CONTINUE__"
      ? "（玩家要求延續劇情）"
      : str(message.content);
    return speaker + "：" + content;
  }).filter((line: string) => line.length > 1).join("\n");

  let generated;
  try {
    generated = await generateMemorySummary([
      {
        role: "system",
        content: [
          "你是 POYOZZ 的長期劇情記憶整理器。每次只整理本批新增的五個已完成群組回合，產生一則獨立的本批重點摘要，供角色下次接續故事使用。",
          "只輸出 JSON object：{\"summary\":\"30～100 個中文字的本批摘要\"}。不要 Markdown、標題、條列或其他文字。",
          "摘要必須是 30～100 個中文字、單一精簡段落。以本批五回合為唯一摘要範圍，凝結玩家偏好、角色關係變化、重要共同事件、承諾、界線、情緒轉折，以及尚未完成或下次要接續的事情。既有摘要只供背景參照，不可再次重述前一批已記錄的事件。",
          "群組內每位角色的人格與發言必須分清楚，不可把不同角色的行動、背景或想法混在一起。",
          "只記錄確實發生或明確約定的內容。不可推測、補造事件、替玩家決定想法或行動，也不可把角色提出但未完成的事寫成已完成。",
          "若新對話明確更正舊記憶，以玩家最新明確更正為準；不可為追求精簡而遺失仍有效的重要承諾或未完成事項。",
        ].join("\n"),
      },
      {
        role: "user",
        content: "【既有摘要（僅供背景參照，不可重複寫入本批摘要）】\n" + (previousSummary || "尚無既有摘要") +
          "\n\n【本次新增的五個群組回合】\n" + transcript +
          "\n\n請只輸出本批新增五回合的獨立摘要，不要重述既有摘要。",
      },
    ], apiKey, existingBatch);
  } catch {
    await admin.from("chat_group_memory_summaries").update({
      status: "failed", processed_at: new Date().toISOString(),
    }).eq("id", batchRowId).eq("status", "processing");
    throw new Error("group_memory_summary_provider_request_failed");
  }

  const { summary } = generated;
  const response = generated.response;
  const diagnosticId = await recordAiGenerationDiagnostic(admin, {
    generationType: "memory_summary", userId, sourceRef: groupId, batchNumber,
    model: response.model, provider: response.provider, requestId: response.requestId,
    httpStatus: response.httpStatus, finishReason: response.finishReason,
    responseContentType: response.responseContentType, responseBodyLength: response.responseBodyLength,
    responseParsed: response.responseParsed,
    rawOutputText: response.rawOutputText || (response.result.kind === "generated" ? response.result.text : ""),
    refusalText: response.rawRefusalText, usage: response.usage,
    status: summary && response.result.kind === "generated" ? "received" : "failed",
    failureStage: summary && response.result.kind === "generated" ? null : "group_summary_output_validation",
    failureCode: summary ? null : response.result.kind === "provider_error" ? response.result.code :
      response.result.kind === "content_rejected" ? "provider_content_rejected" : "group_memory_summary_invalid",
    metadata: { scope: "group", source_turn_ids: sourceTurnIds },
  });
  if (response.httpStatus < 200 || response.httpStatus >= 300 || !summary) {
    await updateAiGenerationDiagnostic(admin, diagnosticId, { status: "failed", failureStage: "group_summary_output_validation", failureCode: "group_memory_summary_invalid" });
    await admin.from("chat_group_memory_summaries").update({
      status: "failed",
      ...summaryUsageMetadata(generated),
      processed_at: new Date().toISOString(),
    }).eq("id", batchRowId).eq("status", "processing");
    return;
  }

  const { data: completed, error: completeError } = await admin.from("chat_group_memory_summaries").update({
    status: "completed",
    summary,
    ...summaryUsageMetadata(generated),
    processed_at: new Date().toISOString(),
  }).eq("id", batchRowId).eq("status", "processing").select("id").maybeSingle();
  if (completeError || !completed) {
    await updateAiGenerationDiagnostic(admin, diagnosticId, { status: "failed", failureStage: "group_summary_persistence", failureCode: "group_memory_summary_result_persist_failed" });
    throw new Error("group_memory_summary_result_persist_failed");
  }
  await updateAiGenerationDiagnostic(admin, diagnosticId, { status: "completed", failureStage: null, failureCode: null });
}
