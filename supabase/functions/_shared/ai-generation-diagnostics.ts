type DbRow = Record<string, unknown>;

const asText = (value: unknown): string =>
  typeof value === "string" ? value : "";

export type AiGenerationDiagnosticInput = {
  generationType: "story_chat" | "group_chat" | "encounter_chat" | "memory_summary" |
    "character_profile" | "encounter_schedule" | "encounter_evaluation";
  status?: "received" | "completed" | "failed" | "partial";
  userId?: string | null;
  characterId?: string | null;
  sessionId?: string | null;
  turnId?: string | null;
  batchNumber?: number | null;
  sourceRef?: string | null;
  model?: string | null;
  provider?: string | null;
  requestId?: string | null;
  httpStatus?: number | null;
  finishReason?: string | null;
  responseContentType?: string | null;
  responseBodyLength?: number | null;
  responseParsed?: boolean | null;
  rawOutputText?: string | null;
  rawResponseBody?: string | null;
  refusalText?: string | null;
  failureStage?: string | null;
  failureCode?: string | null;
  validationErrors?: unknown[];
  usage?: DbRow;
  metadata?: DbRow;
};

/**
 * Best-effort diagnostics: a logging outage must never change generation,
 * billing, refund, queue, or persistence behavior.
 */
export async function recordAiGenerationDiagnostic(
  admin: any,
  input: AiGenerationDiagnosticInput,
): Promise<string | null> {
  try {
    const { data, error } = await admin.from("ai_generation_diagnostics").insert({
      generation_type: input.generationType,
      status: input.status || "received",
      user_id: input.userId || null,
      character_id: input.characterId || null,
      session_id: input.sessionId || null,
      turn_id: input.turnId || null,
      batch_number: input.batchNumber || null,
      source_ref: input.sourceRef || null,
      model: input.model || null,
      provider: input.provider || null,
      gateway_request_id: /^[A-Za-z0-9._:-]{1,128}$/.test(asText(input.requestId))
        ? input.requestId : null,
      http_status: input.httpStatus ?? null,
      finish_reason: input.finishReason || null,
      response_content_type: input.responseContentType || null,
      response_body_length: input.responseBodyLength ?? null,
      response_parsed: input.responseParsed ?? null,
      raw_output_text: input.rawOutputText ?? null,
      raw_response_body: input.rawResponseBody ?? null,
      raw_response_truncated: Boolean(input.rawResponseBody && Number(input.responseBodyLength || 0) > input.rawResponseBody.length),
      refusal_text: input.refusalText ?? null,
      failure_stage: input.failureStage || null,
      failure_code: input.failureCode || null,
      validation_errors: Array.isArray(input.validationErrors) ? input.validationErrors : [],
      usage: input.usage || {},
      metadata: input.metadata || {},
    }).select("id").maybeSingle();
    if (error || !data?.id) {
      console.warn("ai_generation_diagnostic_write_failed", {
        code: error?.code || "diagnostic_insert_failed",
        generation_type: input.generationType,
      });
      return null;
    }
    return String(data.id);
  } catch {
    console.warn("ai_generation_diagnostic_write_failed", {
      code: "diagnostic_insert_exception",
      generation_type: input.generationType,
    });
    return null;
  }
}

export async function updateAiGenerationDiagnostic(
  admin: any,
  id: string | null,
  update: Partial<AiGenerationDiagnosticInput>,
): Promise<void> {
  if (!id) return;
  try {
    const patch: DbRow = {};
    if (update.status) patch.status = update.status;
    if (update.failureStage !== undefined) patch.failure_stage = update.failureStage;
    if (update.failureCode !== undefined) patch.failure_code = update.failureCode;
    if (update.validationErrors !== undefined) patch.validation_errors = update.validationErrors;
    if (update.metadata !== undefined) patch.metadata = update.metadata;
    if (update.model !== undefined) patch.model = update.model;
    if (update.provider !== undefined) patch.provider = update.provider;
    if (update.requestId !== undefined) {
      patch.gateway_request_id = /^[A-Za-z0-9._:-]{1,128}$/.test(asText(update.requestId))
        ? update.requestId : null;
    }
    if (update.httpStatus !== undefined) patch.http_status = update.httpStatus;
    if (update.finishReason !== undefined) patch.finish_reason = update.finishReason;
    if (update.responseContentType !== undefined) patch.response_content_type = update.responseContentType;
    if (update.responseBodyLength !== undefined) patch.response_body_length = update.responseBodyLength;
    if (update.responseParsed !== undefined) patch.response_parsed = update.responseParsed;
    if (update.rawOutputText !== undefined) patch.raw_output_text = update.rawOutputText;
    if (update.rawResponseBody !== undefined) patch.raw_response_body = update.rawResponseBody;
    if (update.refusalText !== undefined) patch.refusal_text = update.refusalText;
    if (update.usage !== undefined) patch.usage = update.usage;
    const { error } = await admin.from("ai_generation_diagnostics").update(patch).eq("id", id);
    if (error) console.warn("ai_generation_diagnostic_update_failed", { code: error.code || "database_error" });
  } catch {
    console.warn("ai_generation_diagnostic_update_failed", { code: "update_exception" });
  }
}
