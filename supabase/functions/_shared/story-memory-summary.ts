import { normalizeAiProviderResult } from "./ai-provider-result.ts";

type DbRow = Record<string, unknown>;
const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const SUMMARY_MODEL = "openai/gpt-oss-20b";
const SUMMARY_INTERVAL = 5;
const row = (value: unknown): DbRow =>
  value && typeof value === "object" && !Array.isArray(value) ? value as DbRow : {};
const str = (value: unknown): string => typeof value === "string" ? value.trim() : "";
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
    assistantMessageId: string;
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
    prompt_tokens: accumulatedUsage.prompt_tokens,
    completion_tokens: accumulatedUsage.completion_tokens,
    total_tokens: accumulatedUsage.total_tokens,
    cost_usd: accumulatedUsage.cost_usd,
    status: input.requestStatus,
    processed_at: new Date().toISOString(),
  });
  if (error) console.error("AI usage record write failed:", error.code || "database_error");
}

async function requestMemorySummary(messages: Array<{ role: "system" | "user"; content: string }>, apiKey: string) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 45_000);
  try {
    const response = await fetch(OPENROUTER_URL, {
      method: "POST",
      headers: {
        "Authorization": "Bearer " + apiKey,
        "Content-Type": "application/json",
        "X-OpenRouter-Title": "POYOZZ",
      },
      body: JSON.stringify({
        model: SUMMARY_MODEL,
        messages,
        temperature: 0.2,
        // No client-side output limit is set; the benchmark showed that
        // fixed caps can truncate reasoning-heavy summaries.
        provider: { only: ["deepinfra"], allow_fallbacks: false, data_collection: "deny" },
      }),
      signal: controller.signal,
    });
    let payload: DbRow;
    try {
      payload = row(await response.json());
    } catch {
      payload = { error: { code: "invalid_provider_response" } };
    }
    payload.status = response.status;
    if (!response.ok && payload.error == null) payload.error = { code: "http_" + response.status };
    return {
      result: normalizeAiProviderResult(payload),
      httpStatus: response.status,
      requestId: response.headers.get("x-request-id") || str(payload.id),
      provider: str(payload.provider) || "deepinfra",
      model: str(payload.model) || SUMMARY_MODEL,
      usage: row(payload.usage),
    };
  } finally {
    clearTimeout(timeout);
  }
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
    if (found?.status === "completed") continue;
    if (found?.status === "processing") {
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

  const previousBatch = rows.find((item: DbRow) =>
    Number(item.batch_number) === batchNumber - 1 && item.status === "completed"
  );
  const sessionData = row(session.session_data);
  const previousSummary = str(previousBatch?.summary) || str(sessionData.summary);
  const characterName = str(session.character_name) || "角色";
  const transcript = sourceMessages.map((message: DbRow) =>
    (message.role === "assistant" ? characterName : "玩家") + "：" + str(message.content)
  ).join("\n");

  let response;
  try {
    response = await requestMemorySummary([
      {
        role: "system",
        content: [
          "你是 POYOZZ 的長期劇情記憶整理器。請將既有摘要與本批新增對話整合成一份可供角色下次自然接續的繁體中文記憶。",
          "摘要目標為 50～150 個中文字，單一精簡段落，不要標題、條列、分析或補充說明。",
          "優先保留玩家明確偏好、角色關係變化、重要共同事件、承諾、界線、情緒轉折，以及尚未完成或下次要接續的事情。",
          "只記錄確實發生或明確約定的內容。不可推測、補造事件、替玩家決定想法或行動，也不可把角色提出但未完成的事寫成已完成。",
          "若新對話明確更正舊記憶，以玩家最新明確更正為準。不要因追求精簡而遺失重要承諾或未完成事項。",
        ].join("\n"),
      },
      {
        role: "user",
        content: "【既有記憶摘要】\n" + (previousSummary || "尚無既有摘要") +
          "\n\n【本次新增的五回合對話】\n" + transcript +
          "\n\n請輸出更新後的完整累積摘要。",
      },
    ], apiKey);
  } catch {
    await admin.from("ai_model_usage").update({
      status: "failed", processed_at: new Date().toISOString(),
    }).eq("id", batchRowId).eq("status", "processing");
    throw new Error("memory_summary_provider_request_failed");
  }

  const usage = usageSnapshot(response.usage);
  const priorUsage = usageSnapshot({
    prompt_tokens: existingBatch?.prompt_tokens,
    completion_tokens: existingBatch?.completion_tokens,
    total_tokens: existingBatch?.total_tokens,
    cost: existingBatch?.cost_usd,
  });
  const accumulatedUsage = {
    prompt_tokens: priorUsage.prompt_tokens === null && usage.prompt_tokens === null ? null : (priorUsage.prompt_tokens || 0) + (usage.prompt_tokens || 0),
    completion_tokens: priorUsage.completion_tokens === null && usage.completion_tokens === null ? null : (priorUsage.completion_tokens || 0) + (usage.completion_tokens || 0),
    total_tokens: priorUsage.total_tokens === null && usage.total_tokens === null ? null : (priorUsage.total_tokens || 0) + (usage.total_tokens || 0),
    cost_usd: priorUsage.cost_usd === null && usage.cost_usd === null ? null : (priorUsage.cost_usd || 0) + (usage.cost_usd || 0),
  };
  const requestId = /^[A-Za-z0-9._:-]{1,128}$/.test(response.requestId) ? response.requestId : null;
  const summary = response.result.kind === "generated" ? response.result.text.trim() : "";
  if (response.httpStatus < 200 || response.httpStatus >= 300 || !summary) {
    await admin.from("ai_model_usage").update({
      status: "failed",
      model: response.model,
      provider: response.provider,
      gateway_request_id: requestId,
      prompt_tokens: accumulatedUsage.prompt_tokens,
      completion_tokens: accumulatedUsage.completion_tokens,
      total_tokens: accumulatedUsage.total_tokens,
      cost_usd: accumulatedUsage.cost_usd,
      processed_at: new Date().toISOString(),
    }).eq("id", batchRowId).eq("status", "processing");
    return;
  }

  const { error: completeError } = await admin.from("ai_model_usage").update({
    status: "completed",
    summary,
    model: response.model,
    provider: response.provider,
    gateway_request_id: requestId,
    prompt_tokens: usage.prompt_tokens,
    completion_tokens: usage.completion_tokens,
    total_tokens: usage.total_tokens,
    cost_usd: usage.cost_usd,
    processed_at: new Date().toISOString(),
  }).eq("id", batchRowId).eq("status", "processing");
  if (completeError) throw new Error("memory_summary_result_persist_failed");
}
