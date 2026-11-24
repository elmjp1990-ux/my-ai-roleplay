import { requestOpenRouterChatCompletion, POYOZZ_DEFAULT_CHAT_MODEL } from "./openrouter-chat-completions.ts";
import { recordAiGenerationDiagnostic, updateAiGenerationDiagnostic } from "./ai-generation-diagnostics.ts";
import { findPrivateContextLeak } from "./private-context-guard.ts";
import {
  buildEncounterScheduleBatchMessages,
  classifyEncounterWorldview,
  getEncounterWorldviewScheduleDisposition,
  parseEncounterScheduleBatchOutput,
  normalizeEncounterSceneKey,
  type EncounterScheduleSource,
  type EncounterSceneCatalogEntry,
} from "./encounter-schedule-generation.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...corsHeaders, "Content-Type": "application/json" },
});
const asRow = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
const asText = (value: unknown): string => typeof value === "string" ? value.trim() : "";
const ENCOUNTER_SCHEDULE_BATCH_SIZE = 1;
// Runtime adapters choose a provider timeout that fits their execution budget.

async function recordBatchUsage(
  admin: any,
  batchId: string,
  providerResponse: any,
  status: string,
  failureCode: string | null = null,
  characterId: string | null = null,
  diagnostics: Record<string, unknown> = {},
) {
  const { error } = await admin.from("encounter_schedule_generation_usage").insert({
    batch_id: batchId,
    requested_model: POYOZZ_DEFAULT_CHAT_MODEL,
    provider: asText(providerResponse?.provider) || "openrouter",
    status,
    usage: {
      ...(providerResponse?.usage && typeof providerResponse.usage === "object" ? providerResponse.usage : {}),
      _poyozz_diagnostics: {
        character_id: characterId,
        http_status: Number(providerResponse?.httpStatus || 0),
        provider_duration_ms: Number(providerResponse?.durationMs || diagnostics.provider_duration_ms || 0),
        response_content_type: asText(providerResponse?.responseContentType),
        response_body_length: Number(providerResponse?.responseBodyLength || 0),
        response_json_parsed: providerResponse?.responseParsed !== false,
        ...diagnostics,
      },
    },
    gateway_request_id: /^[A-Za-z0-9._:-]{1,128}$/.test(asText(providerResponse?.requestId)) ? providerResponse.requestId : null,
    failure_code: failureCode,
  });
  if (error) console.warn("Encounter schedule usage logging failed:", error.message);
}

async function failBatch(admin: any, batchId: string, leaseToken: string, failureCode: string, retryable: boolean, ambiguous = false) {
  const { data, error } = await admin.rpc("fail_encounter_schedule_batch", {
    p_batch_id: batchId,
    p_lease_token: leaseToken,
    p_failure_code: failureCode.slice(0, 100),
    p_retryable: retryable,
    p_ambiguous: ambiguous,
  });
  return !error && !!data;
}


async function recordRawGenerationOutput(
  admin: any,
  batchId: string,
  characterId: string,
  actorUserId: string | null,
  providerResponse: any,
) {
  const { data: job, error: jobError } = await admin.from("encounter_schedule_generation_jobs")
    .select("source_hash").eq("character_id", characterId).maybeSingle();
  if (jobError || !job?.source_hash) {
    console.warn("Encounter schedule raw output source hash unavailable:", jobError?.message || characterId);
    return null;
  }
  const rawText = typeof providerResponse?.rawOutputText === "string" ? providerResponse.rawOutputText : "";
  const rawBody = typeof providerResponse?.rawResponseBody === "string" ? providerResponse.rawResponseBody : "";
  const { data, error } = await admin.from("encounter_schedule_generation_outputs").insert({
    batch_id: batchId,
    character_id: characterId,
    actor_user_id: actorUserId,
    source_hash: job.source_hash,
    requested_model: POYOZZ_DEFAULT_CHAT_MODEL,
    provider: asText(providerResponse?.provider) || "openrouter",
    response_model: asText(providerResponse?.model) || null,
    finish_reason: asText(providerResponse?.finishReason) || null,
    raw_response_text: rawText.slice(0, 500000) || null,
    raw_output_truncated: rawText.length > 500000,
    raw_response_body: rawBody.slice(0, 250000) || null,
    response_body_truncated: rawBody.length > 250000 ||
      Number(providerResponse?.responseBodyLength || 0) > 250000,
    http_status: Number(providerResponse?.httpStatus || 0) || null,
    response_content_type: asText(providerResponse?.responseContentType) || null,
    response_parsed: providerResponse?.responseParsed !== false,
    usage: providerResponse?.usage && typeof providerResponse.usage === "object" ? providerResponse.usage : {},
    status: "received",
  }).select("id").single();
  if (error || !data?.id) {
    console.warn("Encounter schedule raw output persistence failed:", error?.message || characterId);
    return null;
  }
  return asText(data.id);
}

async function updateRawGenerationOutput(
  admin: any,
  outputId: string | null,
  status: string,
  failureCode: string | null = null,
  validationErrors: string[] = [],
) {
  if (!outputId) return;
  const { error } = await admin.from("encounter_schedule_generation_outputs")
    .update({ status, failure_code: failureCode, validation_errors: validationErrors.slice(0, 30) })
    .eq("id", outputId);
  if (error) console.warn("Encounter schedule raw output status update failed:", error.message);
}

async function handleScheduleRepairHide(admin: any, actorUserId: string, body: Record<string, unknown>) {
  const outputId = asText(body.output_id);
  if (!/^[0-9a-f-]{36}$/i.test(outputId)) return json({ error: "schedule_repair_input_invalid" }, 400);
  const { data: output, error: outputError } = await admin.from("encounter_schedule_generation_outputs")
    .select("id,batch_id,character_id").eq("id", outputId).eq("actor_user_id", actorUserId)
    .is("removed_at", null).maybeSingle();
  if (outputError || !output) return json({ error: "schedule_repair_output_not_found" }, 404);
  const { data: originalBatch, error: batchError } = await admin.from("encounter_schedule_batch_runs")
    .select("actor_user_id,is_manual,character_ids").eq("id", output.batch_id).maybeSingle();
  if (batchError || !originalBatch || originalBatch.is_manual !== true ||
      originalBatch.actor_user_id !== actorUserId ||
      !Array.isArray(originalBatch.character_ids) || !originalBatch.character_ids.includes(output.character_id)) {
    return json({ error: "schedule_repair_not_authorized" }, 403);
  }
  const { data: hidden, error: hideError } = await admin.from("encounter_schedule_generation_outputs")
    .update({ removed_at: new Date().toISOString(), removed_by: actorUserId })
    .eq("id", outputId).eq("actor_user_id", actorUserId).is("removed_at", null)
    .select("id").maybeSingle();
  if (hideError || !hidden) return json({ error: "schedule_repair_hide_failed" }, 503);
  return json({ status: "hidden", ai_called: false, original_preserved: true });
}

async function handleScheduleRepairDraft(admin: any, actorUserId: string, body: Record<string, unknown>) {
  const outputId = asText(body.output_id);
  const correctedText = typeof body.corrected_response === "string" ? body.corrected_response : "";
  if (!/^[0-9a-f-]{36}$/i.test(outputId) || correctedText.length < 2 || correctedText.length > 500000) {
    return json({ error: "schedule_repair_input_invalid" }, 400);
  }

  const { data: output, error: outputError } = await admin.from("encounter_schedule_generation_outputs")
    .select("id,batch_id,character_id,source_hash")
    .eq("id", outputId).eq("actor_user_id", actorUserId)
    .is("removed_at", null).gt("expires_at", new Date().toISOString()).maybeSingle();
  if (outputError || !output) return json({ error: "schedule_repair_output_not_found" }, 404);
  if (!output.source_hash || !output.batch_id || !output.character_id) {
    return json({ error: "schedule_repair_source_metadata_missing" }, 409);
  }

  const { data: originalBatch, error: batchError } = await admin.from("encounter_schedule_batch_runs")
    .select("actor_user_id,is_manual,character_ids").eq("id", output.batch_id).maybeSingle();
  if (batchError || !originalBatch || originalBatch.is_manual !== true ||
      originalBatch.actor_user_id !== actorUserId ||
      !Array.isArray(originalBatch.character_ids) || !originalBatch.character_ids.includes(output.character_id)) {
    return json({ error: "schedule_repair_not_authorized" }, 403);
  }

  const { data: revision, error: revisionError } = await admin.from("encounter_schedule_generation_output_revisions")
    .insert({
      output_id: output.id,
      corrected_response_text: correctedText,
      validation_errors: [],
      status: "draft",
      created_by: actorUserId,
    }).select("id,created_at").single();
  if (revisionError || !revision?.id) return json({ error: "schedule_repair_draft_save_failed" }, 503);

  return json({
    status: "draft_saved",
    revision_id: revision.id,
    saved_at: revision.created_at,
    ai_called: false,
    published: false,
    original_preserved: true,
  });
}

async function handleScheduleRepair(admin: any, actorUserId: string, body: Record<string, unknown>) {
  const outputId = asText(body.output_id);
  const correctedText = typeof body.corrected_response === "string" ? body.corrected_response : "";
  if (!/^[0-9a-f-]{36}$/i.test(outputId) || correctedText.length < 2 || correctedText.length > 500000) {
    return json({ error: "schedule_repair_input_invalid" }, 400);
  }

  const { data: output, error: outputError } = await admin.from("encounter_schedule_generation_outputs")
    .select("*").eq("id", outputId).eq("actor_user_id", actorUserId)
    .is("removed_at", null).gt("expires_at", new Date().toISOString()).maybeSingle();
  if (outputError || !output) return json({ error: "schedule_repair_output_not_found" }, 404);
  if (!output.source_hash || !output.batch_id || !output.character_id) {
    return json({ error: "schedule_repair_source_metadata_missing" }, 409);
  }

  const { data: originalBatch, error: batchError } = await admin.from("encounter_schedule_batch_runs")
    .select("actor_user_id,is_manual,character_ids").eq("id", output.batch_id).maybeSingle();
  if (batchError || !originalBatch || originalBatch.is_manual !== true ||
      originalBatch.actor_user_id !== actorUserId ||
      !Array.isArray(originalBatch.character_ids) || !originalBatch.character_ids.includes(output.character_id)) {
    return json({ error: "schedule_repair_not_authorized" }, 403);
  }

  const { data: job, error: jobError } = await admin.from("encounter_schedule_generation_jobs")
    .select("status,source_hash").eq("character_id", output.character_id).maybeSingle();
  if (jobError || !job) return json({ error: "schedule_repair_job_unavailable" }, 503);
  if (job.status !== "failed") return json({ error: "schedule_repair_job_not_failed", job_status: job.status }, 409);
  if (job.source_hash !== output.source_hash) return json({ error: "schedule_repair_source_changed" }, 409);

  const { data: source, error: sourceError } = await admin.rpc("encounter_schedule_source_payload", {
    p_character_id: output.character_id,
  });
  if (sourceError || !source) return json({ error: "schedule_repair_source_unavailable" }, 409);

  const { data: sceneCatalogData, error: sceneCatalogError } = await admin.rpc("get_encounter_scene_catalog");
  const sceneCatalog = sceneCatalogError
    ? []
    : (Array.isArray(sceneCatalogData) ? sceneCatalogData : []) as EncounterSceneCatalogEntry[];
  if (sceneCatalogError) {
    console.warn("Encounter repair scene catalog unavailable; using free natural-language locations:", sceneCatalogError.message);
  }

  let promptContext;
  try {
    promptContext = buildEncounterScheduleBatchMessages([source as EncounterScheduleSource], sceneCatalog);
  } catch (error) {
    return json({ error: asText(error instanceof Error ? error.message : "schedule_repair_context_invalid") }, 409);
  }

  const parsed = parseEncounterScheduleBatchOutput(
    correctedText,
    [source as EncounterScheduleSource],
    sceneCatalog,
  );
  const validationErrors = parsed.ok && parsed.characters.length === 1
    ? []
    : (parsed.errors.length ? parsed.errors.slice(0, 30) : ["schedule_output_shape_invalid"]);
  if (!validationErrors.length && parsed.characters.length === 1) {
    const protectedValues = promptContext.protectedContextByCharacter[output.character_id] || [];
    if (findPrivateContextLeak(JSON.stringify(parsed.characters[0]), protectedValues, [])) {
      validationErrors.push("private_context_output_blocked");
    }
  }

  const { data: revision, error: revisionError } = await admin.from("encounter_schedule_generation_output_revisions")
    .insert({
      output_id: output.id,
      corrected_response_text: correctedText,
      validation_errors: validationErrors,
      status: validationErrors.length ? "invalid" : "validated",
      created_by: actorUserId,
    }).select("id").single();
  if (revisionError || !revision?.id) return json({ error: "schedule_repair_revision_save_failed" }, 503);

  if (validationErrors.length) {
    return json({
      status: "validation_failed",
      revision_id: revision.id,
      validation_errors: validationErrors,
      original_preserved: true,
      ai_called: false,
    });
  }

  const { data: claimData, error: claimError } = await admin.rpc("claim_encounter_schedule_repair", {
    p_original_batch_id: output.batch_id,
    p_character_id: output.character_id,
    p_actor_user_id: actorUserId,
    p_expected_source_hash: output.source_hash,
  });
  const claim = Array.isArray(claimData) ? claimData[0] : claimData;
  if (claimError || claim?.status !== "claimed") {
    return json({ error: "schedule_repair_claim_failed", revision_id: revision.id }, 409);
  }

  const repairBatchId = asText(claim.batch_id);
  const repairLeaseToken = asText(claim.lease_token);
  const { data: published, error: publishError } = await admin.rpc("publish_encounter_schedule_batch", {
    p_batch_id: repairBatchId,
    p_lease_token: repairLeaseToken,
    p_characters: parsed.characters,
  });

  let publishRow = Array.isArray(published) ? published[0] : published;
  if (publishError || !publishRow || !["partial", "completed"].includes(asText(publishRow.status))) {
    const { data: currentJob, error: currentJobError } = await admin.from("encounter_schedule_generation_jobs")
      .select("status").eq("character_id", output.character_id).maybeSingle();
    if (currentJobError || currentJob?.status === "processing") {
      await failBatch(admin, repairBatchId, repairLeaseToken, "schedule_manual_repair_publish_unknown", false, true);
      await admin.from("encounter_schedule_generation_output_revisions")
        .update({ status: "needs_reconciliation" }).eq("id", revision.id);
      return json({ error: "schedule_repair_needs_reconciliation", revision_id: revision.id }, 503);
    }
    if (currentJob?.status !== "completed") {
      await failBatch(admin, repairBatchId, repairLeaseToken, "schedule_manual_repair_publish_failed", false, false);
      await admin.from("encounter_schedule_generation_output_revisions")
        .update({ status: "publish_failed" }).eq("id", revision.id);
      return json({ error: "schedule_repair_publish_failed", revision_id: revision.id }, 503);
    }
    publishRow = { status: "completed", published_character_count: 1, unplaced_character_count: 0 };
  }

  if (Array.isArray(parsed.scenes) && parsed.scenes.length > 0) {
    const { error: sceneError } = await admin.rpc("publish_encounter_scene_metadata", {
      p_scenes: parsed.scenes,
    });
    if (sceneError) console.warn("Encounter repaired scene metadata publish failed:", sceneError.message);
  }

  const { error: revisionUpdateError } = await admin.from("encounter_schedule_generation_output_revisions")
    .update({ status: "published", published_at: new Date().toISOString() }).eq("id", revision.id);
  const { error: outputUpdateError } = await admin.from("encounter_schedule_generation_outputs")
    .update({ status: "repaired", failure_code: null, validation_errors: [] }).eq("id", output.id);
  if (revisionUpdateError || outputUpdateError) {
    console.warn("Encounter repair audit status update failed:", revisionUpdateError?.message || outputUpdateError?.message);
  }

  return json({
    status: "completed",
    revision_id: revision.id,
    published_character_count: Number(publishRow.published_character_count || 0),
    unplaced_character_count: Number(publishRow.unplaced_character_count || 0),
    ai_called: false,
    original_preserved: true,
  });
}

type ScheduleRuntimeEnvironment = { get(name: string): string | undefined };
type SupabaseClientFactory = (url: string, key: string, options?: any) => any;

/** Explicit seams for deterministic, network-free integration tests. Production
 * callers omit this argument and retain the real provider and diagnostics. */
export type EncounterScheduleHandlerTestDependencies = {
  requestOpenRouterChatCompletion?: typeof requestOpenRouterChatCompletion;
  recordAiGenerationDiagnostic?: typeof recordAiGenerationDiagnostic;
  updateAiGenerationDiagnostic?: typeof updateAiGenerationDiagnostic;
};

/**
 * Shared Encounter schedule handler.
 * Supabase Edge Functions use the 100s provider timeout; Vercel uses 270s.
 */
export async function handleEncounterScheduleOrganizer(
  request: Request,
  env: ScheduleRuntimeEnvironment,
  createClient: SupabaseClientFactory,
  providerTimeoutMs = 100_000,
  testDependencies: EncounterScheduleHandlerTestDependencies = {},
): Promise<Response> {
  const requestProvider = testDependencies.requestOpenRouterChatCompletion ?? requestOpenRouterChatCompletion;
  const recordDiagnostic = testDependencies.recordAiGenerationDiagnostic ?? recordAiGenerationDiagnostic;
  const updateDiagnostic = testDependencies.updateAiGenerationDiagnostic ?? updateAiGenerationDiagnostic;
  const ENCOUNTER_SCHEDULE_PROVIDER_TIMEOUT_MS = Math.min(
    270_000,
    Math.max(1_000, Math.floor(Number(providerTimeoutMs) || 100_000)),
  );
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = env.get("SUPABASE_URL");
  const anon = env.get("SUPABASE_ANON_KEY");
  const service = env.get("SUPABASE_SERVICE_ROLE_KEY");
  const openRouterKey = env.get("OPENROUTER_API_KEY")?.trim();
  const authorization = request.headers.get("Authorization") || "";
  if (!url || !anon || !service) return json({ error: "server_not_configured" }, 503);

  let body: Record<string, unknown> = {};
  try { body = asRow(await request.json()); } catch { return json({ error: "invalid_json" }, 400); }
  const mode = ["manual", "status", "repair_list", "repair", "repair_draft", "repair_hide", "reconcile_confirm"].includes(asText(body.mode))
    ? asText(body.mode)
    : "scheduled";
  const isServiceRoleRequest = authorization === "Bearer " + service;
  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
  let actorUserId: string | null = null;

  if (mode === "status") {
    if (env.get("ENCOUNTER_SCHEDULE_TEST_MODE") !== "true") {
      return json({ enabled: false, test_mode: false });
    }
    if (isServiceRoleRequest) return json({ enabled: false, test_mode: true });
    const userClient = createClient(url, anon, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await userClient.auth.getUser();
    if (authError || !authData?.user) return json({ enabled: false, test_mode: true });
    actorUserId = authData.user.id;
    const [pendingResult, processingResult, failedResult, reconciliationResult, reviewResult, lastRunResult, reconciliationBatchesResult] = await Promise.all([
      admin.from("encounter_schedule_generation_jobs").select("character_id", { count: "exact", head: true })
        .eq("status", "pending").eq("author_id", actorUserId),
      admin.from("encounter_schedule_generation_jobs").select("character_id", { count: "exact", head: true })
        .eq("status", "processing").eq("author_id", actorUserId),
      admin.from("encounter_schedule_generation_jobs").select("character_id", { count: "exact", head: true })
        .eq("status", "failed").eq("author_id", actorUserId),
      admin.from("encounter_schedule_generation_jobs").select("character_id", { count: "exact", head: true })
        .eq("status", "needs_reconciliation").eq("author_id", actorUserId),
      admin.from("encounter_schedule_generation_jobs")
        .select("character_id,last_error_code,updated_at")
        .eq("status", "needs_review").eq("author_id", actorUserId)
        .order("updated_at", { ascending: false })
        .limit(50),
      admin.from("encounter_schedule_batch_runs").select("completed_at,status")
        .eq("status", "completed").eq("actor_user_id", actorUserId).eq("is_manual", true)
        .not("completed_at", "is", null)
        .order("completed_at", { ascending: false }).limit(1).maybeSingle(),
      admin.from("encounter_schedule_batch_runs")
        .select("id,character_ids,started_at,failure_code")
        .eq("actor_user_id", actorUserId)
        .eq("is_manual", true)
        .eq("status", "needs_reconciliation")
        .order("started_at", { ascending: false })
        .limit(20),
    ]);
    if (pendingResult.error || processingResult.error || failedResult.error || reconciliationResult.error ||
        reviewResult.error || lastRunResult.error || reconciliationBatchesResult.error) {
      return json({ enabled: true, test_mode: true, status_available: false });
    }
    const reviewCharacterIds = [...new Set((reviewResult.data || []).map((job: any) => job.character_id).filter(Boolean))];
    const reviewCharactersResult = reviewCharacterIds.length
      ? await admin.from("characters").select("id,name").in("id", reviewCharacterIds).eq("author_id", actorUserId)
      : { data: [], error: null };
    if (reviewCharactersResult.error) return json({ enabled: true, test_mode: true, status_available: false });
    const reviewNames = new Map((reviewCharactersResult.data || []).map((character: any) => [character.id, character.name]));
    const manualReviewJobs = (reviewResult.data || []).map((job: any) => ({
      character_id: job.character_id,
      character_name: reviewNames.get(job.character_id) || "角色",
      reason: job.last_error_code || "worldview_manual_review_required",
      updated_at: job.updated_at || null,
    }));
    const reconciliationBatches = reconciliationBatchesResult.data || [];
    const reconciliationCharacterIds = [...new Set(reconciliationBatches.flatMap((batch: any) =>
      Array.isArray(batch.character_ids) ? batch.character_ids : []
    ))];
    const [reconciliationJobsResult, reconciliationCharactersResult] = await Promise.all([
      reconciliationCharacterIds.length
        ? admin.from("encounter_schedule_generation_jobs")
          .select("character_id,status,last_error_code,attempt_count,updated_at")
          .in("character_id", reconciliationCharacterIds)
          .eq("status", "needs_reconciliation")
          .eq("author_id", actorUserId)
        : Promise.resolve({ data: [], error: null }),
      reconciliationCharacterIds.length
        ? admin.from("characters").select("id,name").in("id", reconciliationCharacterIds).eq("author_id", actorUserId)
        : Promise.resolve({ data: [], error: null }),
    ]);
    if (reconciliationJobsResult.error || reconciliationCharactersResult.error) {
      return json({ enabled: true, test_mode: true, status_available: false });
    }
    const reconciliationNames = new Map((reconciliationCharactersResult.data || [])
      .map((character: any) => [character.id, character.name]));
    const reconciliationBatchByCharacter = new Map<string, any>();
    for (const batch of reconciliationBatches) {
      for (const characterId of Array.isArray(batch.character_ids) ? batch.character_ids : []) {
        reconciliationBatchByCharacter.set(characterId, batch);
      }
    }
    const reconciliationJobs = (reconciliationJobsResult.data || []).map((job: any) => {
      const batch = reconciliationBatchByCharacter.get(job.character_id);
      return {
        batch_id: batch?.id || null,
        character_id: job.character_id,
        character_name: reconciliationNames.get(job.character_id) || "角色",
        failure_code: batch?.failure_code || job.last_error_code || "unknown",
        job_error_code: job.last_error_code || "unknown",
        attempt_count: Number(job.attempt_count || 0),
        started_at: batch?.started_at || job.updated_at || null,
      };
    });
    return json({
      enabled: true,
      test_mode: true,
      pending_character_count: Number(pendingResult.count || 0),
      processing_character_count: Number(processingResult.count || 0),
      failed_character_count: Number(failedResult.count || 0),
      needs_reconciliation_count: Number(reconciliationResult.count || 0),
      needs_review_character_count: manualReviewJobs.length,
      manual_review_jobs: manualReviewJobs,
      reconciliation_jobs: reconciliationJobs,
      last_batch_completed_at: lastRunResult.data?.completed_at || null,
      last_batch_status: lastRunResult.data?.status || null,
    });
  }


  if (mode === "reconcile_confirm") {
    if (env.get("ENCOUNTER_SCHEDULE_TEST_MODE") !== "true" || isServiceRoleRequest) {
      return json({ error: "schedule_reconciliation_disabled" }, 403);
    }
    const userClient = createClient(url, anon, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await userClient.auth.getUser();
    if (authError || !authData?.user) return json({ error: "unauthorized" }, 401);
    actorUserId = authData.user.id;

    const batchId = asText(body.batch_id);
    const characterId = asText(body.character_id);
    if (!/^[0-9a-f-]{36}$/i.test(batchId) || !/^[0-9a-f-]{36}$/i.test(characterId)) {
      return json({ error: "schedule_reconciliation_input_invalid" }, 400);
    }
    const { data: batch, error: batchError } = await admin.from("encounter_schedule_batch_runs")
      .select("id,actor_user_id,is_manual,character_ids,status,failure_code")
      .eq("id", batchId).maybeSingle();
    if (batchError || !batch) return json({ error: "schedule_reconciliation_batch_not_found" }, 404);
    if (batch.actor_user_id !== actorUserId || batch.is_manual !== true ||
        !Array.isArray(batch.character_ids) || !batch.character_ids.includes(characterId)) {
      return json({ error: "schedule_reconciliation_not_authorized" }, 403);
    }
    if (batch.status !== "needs_reconciliation" || batch.failure_code !== "schedule_provider_outcome_unknown") {
      return json({ error: "schedule_reconciliation_batch_not_eligible" }, 409);
    }
    const { data: job, error: jobError } = await admin.from("encounter_schedule_generation_jobs")
      .select("status,last_error_code")
      .eq("character_id", characterId).maybeSingle();
    if (jobError || !job) return json({ error: "schedule_reconciliation_job_unavailable" }, 503);
    if (job.status !== "needs_reconciliation" || job.last_error_code !== "schedule_provider_outcome_unknown") {
      return json({ error: "schedule_reconciliation_job_not_eligible" }, 409);
    }

    const resolvedAt = new Date().toISOString();
    const { data: updatedJob, error: updateJobError } = await admin.from("encounter_schedule_generation_jobs")
      .update({
        status: "failed",
        lease_token: null,
        lease_expires_at: null,
        available_at: resolvedAt,
        updated_at: resolvedAt,
      })
      .eq("character_id", characterId)
      .eq("status", "needs_reconciliation")
      .eq("last_error_code", "schedule_provider_outcome_unknown")
      .select("character_id").maybeSingle();
    if (updateJobError || !updatedJob) {
      return json({ error: "schedule_reconciliation_job_update_failed" }, 503);
    }

    const { data: updatedBatch, error: updateBatchError } = await admin.from("encounter_schedule_batch_runs")
      .update({
        status: "failed",
        failure_code: "schedule_provider_outcome_unknown_acknowledged",
        completed_at: resolvedAt,
        updated_at: resolvedAt,
      })
      .eq("id", batchId)
      .eq("actor_user_id", actorUserId)
      .eq("status", "needs_reconciliation")
      .select("id").maybeSingle();
    if (updateBatchError || !updatedBatch) {
      const { error: rollbackError } = await admin.from("encounter_schedule_generation_jobs")
        .update({ status: "needs_reconciliation", updated_at: new Date().toISOString() })
        .eq("character_id", characterId)
        .eq("status", "failed")
        .eq("last_error_code", "schedule_provider_outcome_unknown");
      if (rollbackError) console.error("Schedule reconciliation rollback failed:", rollbackError.message);
      return json({ error: "schedule_reconciliation_batch_update_failed" }, 503);
    }
    return json({
      status: "resolved_without_retry",
      ai_called: false,
      original_batch_preserved: true,
      provider_outcome_confirmed: false,
    });
  }

  if (mode === "repair_list" || mode === "repair" || mode === "repair_draft" || mode === "repair_hide") {
    if (env.get("ENCOUNTER_SCHEDULE_TEST_MODE") !== "true" || isServiceRoleRequest) {
      return json({ error: "schedule_repair_disabled" }, 403);
    }
    const userClient = createClient(url, anon, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await userClient.auth.getUser();
    if (authError || !authData?.user) return json({ error: "unauthorized" }, 401);
    actorUserId = authData.user.id;

    if (mode === "repair_list") {
      // Expired originals remain stored for audit/history; expiry only removes edit eligibility.
      const { data: outputs, error: outputsError } = await admin.from("encounter_schedule_generation_outputs")
        .select("id,batch_id,character_id,requested_model,provider,response_model,finish_reason,raw_response_text,raw_output_truncated,raw_response_body,response_body_truncated,http_status,status,failure_code,validation_errors,created_at")
        .eq("actor_user_id", actorUserId)
        .is("removed_at", null)
        .in("status", ["failed", "partial", "received", "dismissed"])
        .gt("expires_at", new Date().toISOString())
        .order("created_at", { ascending: false })
        .limit(20);
      if (outputsError) return json({ error: "schedule_repair_list_unavailable" }, 503);
      const outputIds = (outputs || []).map((item: any) => item.id).filter(Boolean);
      const { data: revisions, error: revisionsError } = outputIds.length
        ? await admin.from("encounter_schedule_generation_output_revisions")
          .select("id,output_id,corrected_response_text,status,created_at")
          .in("output_id", outputIds)
          .order("created_at", { ascending: false })
        : { data: [], error: null };
      if (revisionsError) return json({ error: "schedule_repair_revisions_unavailable" }, 503);
      const latestRevisionByOutput = new Map<string, any>();
      for (const revision of revisions || []) {
        if (!latestRevisionByOutput.has(revision.output_id)) latestRevisionByOutput.set(revision.output_id, revision);
      }
      const ids = [...new Set((outputs || []).map((item: any) => item.character_id).filter(Boolean))];
      const [{ data: characters }, { data: jobs, error: jobsError }] = await Promise.all([
        ids.length
          ? admin.from("characters").select("id,name").in("id", ids)
          : Promise.resolve({ data: [] }),
        ids.length
          ? admin.from("encounter_schedule_generation_jobs").select("character_id,status").in("character_id", ids)
          : Promise.resolve({ data: [], error: null }),
      ]);
      if (jobsError) return json({ error: "schedule_repair_job_states_unavailable" }, 503);
      const repairableCharacterIds = new Set((jobs || [])
        .filter((job: any) => job.status === "failed")
        .map((job: any) => job.character_id));
      const names = new Map((characters || []).map((item: any) => [item.id, item.name]));
      return json({
        status: "available",
        outputs: (outputs || []).filter((item: any) => repairableCharacterIds.has(item.character_id)).map((item: any) => ({
          ...item,
          character_name: names.get(item.character_id) || "角色",
          raw_response_text: item.raw_response_text || item.raw_response_body || "",
          latest_revision_text: latestRevisionByOutput.get(item.id)?.corrected_response_text || null,
          latest_revision_status: latestRevisionByOutput.get(item.id)?.status || null,
          latest_revision_at: latestRevisionByOutput.get(item.id)?.created_at || null,
        })),
      });
    }
    if (mode === "repair_hide") return await handleScheduleRepairHide(admin, authData.user.id, body);
    if (mode === "repair_draft") return await handleScheduleRepairDraft(admin, authData.user.id, body);
    return await handleScheduleRepair(admin, authData.user.id, body);
  }

  if (!openRouterKey) return json({ error: "openrouter_not_configured" }, 503);

  if (mode === "manual") {
    // The test-only UI is absent from production builds. Keep a server-side
    // project-mode guard and require a real signed-in user, without a per-user
    // allowlist or unrelated account-state gate in the test environment.
    if (env.get("ENCOUNTER_SCHEDULE_TEST_MODE") !== "true" || isServiceRoleRequest) {
      return json({ error: "manual_schedule_trigger_disabled" }, 403);
    }
    const userClient = createClient(url, anon, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await userClient.auth.getUser();
    if (authError || !authData?.user) return json({ error: "unauthorized" }, 401);
    actorUserId = authData.user.id;
  } else if (!isServiceRoleRequest) {
    return json({ error: "scheduled_trigger_requires_service_role" }, 401);
  }

  let queuedCharacterCount = 0;
  if (mode === "manual") {
    // Manual testing never retries terminal failures. Only pending jobs are
    // eligible below; active leases and uncertain publish outcomes stay blocked.
    const [processingResult, reconciliationResult] = await Promise.all([
      admin.from("encounter_schedule_generation_jobs").select("character_id", { count: "exact", head: true })
        .eq("status", "processing").eq("author_id", actorUserId),
      admin.from("encounter_schedule_generation_jobs").select("character_id", { count: "exact", head: true })
        .eq("status", "needs_reconciliation").eq("author_id", actorUserId),
    ]);
    if (processingResult.error || reconciliationResult.error) {
      return json({ error: "schedule_failure_state_unavailable" }, 503);
    }
    const processingCharacterCount = Number(processingResult.count || 0);
    const needsReconciliationCount = Number(reconciliationResult.count || 0);
    if (processingCharacterCount > 0 || needsReconciliationCount > 0) {
      return json({
        status: "blocked_unresolved_failures",
        processing_character_count: processingCharacterCount,
        needs_reconciliation_count: needsReconciliationCount,
      }, 409);
    }
    // Manual testing consumes only jobs already in the pending queue.
    // Do not rescan/re-enqueue every public character: that could reset a prior
    // failed job after its source changes and makes one-at-a-time verification unclear.
    const { count: pendingCount, error: pendingCountError } = await admin
      .from("encounter_schedule_generation_jobs")
      .select("character_id", { count: "exact", head: true })
      .eq("status", "pending")
      .eq("author_id", actorUserId);
    if (pendingCountError) {
      return json({ error: "schedule_pending_state_unavailable" }, 503);
    }
    queuedCharacterCount = Number(pendingCount || 0);
    if (queuedCharacterCount < 1) {
      return json({
        status: "no_pending_jobs",
        queued_character_count: 0,
        failed_jobs_preserved: true,
      });
    }

    // Do not claim a schedule lease or spend schedule-model tokens until the
    // exact next public character has a source-current, complete AI Profile.
    const { data: nextScheduleJob, error: nextScheduleJobError } = await admin.rpc(
      "get_next_encounter_schedule_character_for_author",
      { p_author_id: actorUserId },
    );
    if (nextScheduleJobError) {
      return json({ error: "character_profile_preflight_unavailable" }, 503);
    }
    if (nextScheduleJob?.character_id) {
      const { data: profileData, error: profileError } = await admin.rpc("get_character_ai_profile_for_chat", {
        p_character_id: nextScheduleJob.character_id,
        p_author_id: actorUserId,
      });
      if (profileError) {
        return json({ error: "character_profile_preflight_unavailable" }, 503);
      }
      const profile = asRow(profileData);
      const lifeContext = asRow(profile.life_context);
      const lifeContextKeys = [
        "work_environment", "residence_environment", "daily_routines", "interests_and_leisure",
        "social_circles", "recurring_places", "environmental_constraints",
      ];
      const lifeContextReady = profile.schema_version === "1.1" &&
        Object.keys(lifeContext).length === lifeContextKeys.length &&
        lifeContextKeys.every((key) => Object.prototype.hasOwnProperty.call(lifeContext, key));
      if (!profileData || !lifeContextReady) {
        return json({
          status: "profile_required",
          error: "character_profile_not_ready",
          character_id: nextScheduleJob.character_id,
          character_name: nextScheduleJob.character_name || "角色",
          ai_called: false,
          schedule_job_claimed: false,
        }, 409);
      }
    }
  }

  const { data: claimData, error: claimError } = await admin.rpc("claim_encounter_schedule_batch", {
    p_limit: ENCOUNTER_SCHEDULE_BATCH_SIZE,
    p_force: mode === "manual",
    p_actor_user_id: actorUserId,
  });
  if (claimError) return json({ error: "schedule_batch_claim_failed" }, 503);
  const claim = Array.isArray(claimData) ? claimData[0] : claimData;
  if (!claim || claim.status !== "claimed") {
    return json({
      status: asText(claim?.status) || "not_ready",
      pending_character_count: Number(claim?.pending_character_count || 0),
      queued_character_count: queuedCharacterCount,
      next_eligible_at: claim?.next_eligible_at || null,
    });
  }

  const batchId = asText(claim.batch_id);
  const leaseToken = asText(claim.lease_token);
  const sources = Array.isArray(claim.characters) ? claim.characters as EncounterScheduleSource[] : [];
  if (!batchId || !leaseToken || sources.length < 1) {
    if (batchId && leaseToken) await failBatch(admin, batchId, leaseToken, "claimed_batch_payload_invalid", false);
    return json({ error: "claimed_batch_payload_invalid" }, 503);
  }

  // Reuse the source-current Character AI Profile. This is a database read only;
  // schedule generation must never trigger a second profile-analysis model call.
  const enrichedSources = await Promise.all(sources.map(async (source) => {
    try {
      const { data: profileData, error: profileError } = await admin.rpc("get_character_ai_profile_for_chat", {
        p_character_id: source.character_id,
        p_author_id: source.author_id,
      });
      if (profileError) {
        console.warn("Character AI Profile read failed:", profileError.message);
        return { ...source, profile_read_error: true };
      }
      const profile = profileData && typeof profileData === "object" && !Array.isArray(profileData)
        ? profileData as Record<string, unknown> : {};
      const lifeContext = profile.life_context && typeof profile.life_context === "object" && !Array.isArray(profile.life_context)
        ? profile.life_context : null;
      const lifeContextKeys = [
        "work_environment", "residence_environment", "daily_routines", "interests_and_leisure",
        "social_circles", "recurring_places", "environmental_constraints",
      ];
      const lifeContextReady = profile.schema_version === "1.1" && !!lifeContext &&
        Object.keys(asRow(lifeContext)).length === lifeContextKeys.length &&
        lifeContextKeys.every((key) => Object.prototype.hasOwnProperty.call(asRow(lifeContext), key));
      if (!profileData || !lifeContextReady) {
        return mode === "manual" ? { ...source, profile_read_error: true } : source;
      }
      const profileSections = [
        "identity_background", "core_personality", "inner_motivations",
        "emotional_response_patterns", "relationship_dynamics", "behavior_and_agency",
        "knowledge_boundaries", "speech_style", "ooc_rules", "unknowns", "source_conflicts",
      ];
      const derivedCharacterProfile = Object.fromEntries(
        profileSections
          .filter((key) => profile[key] !== undefined)
          .map((key) => [key, profile[key]]),
      );
      return {
        ...source,
        derived_life_context: lifeContext,
        derived_character_profile: derivedCharacterProfile,
      };
    } catch (error) {
      console.warn("Character AI Profile read failed:",
        error instanceof Error ? error.message : "unknown_error");
      return mode === "manual" ? { ...source, profile_read_error: true } : source;
    }
  }));

  if (enrichedSources.some((source) => source.profile_read_error === true)) {
    const released = await failBatch(admin, batchId, leaseToken, "character_profile_not_ready", true);
    if (!released) {
      return json({ error: "schedule_profile_gate_release_failed", ai_called: false }, 503);
    }
    return json({
      status: "profile_required",
      error: "character_profile_not_ready",
      ai_called: false,
      schedule_job_released: true,
    }, 409);
  }

  const { data: sceneCatalogData, error: sceneCatalogError } = await admin.rpc("get_encounter_scene_catalog");
  // Scene metadata is only an optional exact-name hint. A catalog read failure
  // must not prevent the model call or discard natural-language locations:
  // the publisher persists location_description and can resolve it later.
  const sceneCatalog = sceneCatalogError
    ? []
    : (Array.isArray(sceneCatalogData) ? sceneCatalogData : []) as EncounterSceneCatalogEntry[];
  if (sceneCatalogError) {
    console.warn("Encounter scene catalog unavailable; preserving natural locations:", sceneCatalogError.message);
  }

  const protectedContextByCharacter: Record<string, string[]> = {};
  const rawCharacters: unknown[] = [];
  const rawScenesByKey = new Map<string, unknown>();
  const providerResponses: Array<{ sourceId: string; providerResponse: Awaited<ReturnType<typeof requestOpenRouterChatCompletion>> }> = [];
  const failedCharacterIds = new Set<string>();
  const reviewRequiredCharacterIds = new Set<string>();
  const validationErrors: string[] = [];
  const characterDiagnosticsById = new Map<string, Record<string, unknown>>();
  const rawOutputIdByCharacter = new Map<string, string>();
  let retryableProviderFailure = false;
  let ambiguousProviderFailure = false;

  // Worldview is classified locally before any provider call. Known non-modern
  // roles are marked not applicable; unknown roles are held for manual review.
  // Neither group is sent to AI, and review-required roles are not published as unplaced.
  const generationSources = enrichedSources.filter((source) => {
    const classification = classifyEncounterWorldview(source);
    const disposition = getEncounterWorldviewScheduleDisposition(
      classification,
      source.worldview_review_decision,
    );
    if (disposition === "generate") return true;
    if (disposition === "needs_review") {
      // Review-only roles are deliberately not represented as parser output.
      // They are moved to the durable needs_review queue state after any
      // publishable characters in this lease have been committed.
      reviewRequiredCharacterIds.add(source.character_id);
    } else {
      // Known non-modern roles are completed as unplaced without an AI call.
      rawCharacters.push({
        character_id: source.character_id,
        placement: "no_matching_location",
        variants: { weekday: [], holiday: [] },
        special_events: [],
      });
    }
    characterDiagnosticsById.set(source.character_id, {
      worldview_category: classification.category,
      worldview_confidence: classification.confidence,
      modern_map_compatible: false,
      ai_generation_skipped: true,
      manual_review_required: disposition === "needs_review",
      manual_review_decision: asText(source.worldview_review_decision) || null,
    });
    return false;
  });

  // One character per request isolates provider output and keeps the next test batch minimal.
  const generationResults = await Promise.all(generationSources.map(async (source) => {
    let characterPrompt;
    try {
      characterPrompt = buildEncounterScheduleBatchMessages([source], sceneCatalog);
      protectedContextByCharacter[source.character_id] =
        characterPrompt.protectedContextByCharacter[source.character_id] || [];
    } catch (error) {
      return { sourceId: source.character_id, failureCode: asText(error instanceof Error ? error.message : "schedule_prompt_invalid"), retryable: false, ambiguous: false };
    }
    let rawOutputId: string | null = null;
    let diagnosticId: string | null = null;
    let providerDurationMs = 0;
    const providerStartedAt = Date.now();
    try {
      const providerResponse = await requestProvider({
        messages: characterPrompt.messages, apiKey: openRouterKey, model: POYOZZ_DEFAULT_CHAT_MODEL,
        timeoutMs: ENCOUNTER_SCHEDULE_PROVIDER_TIMEOUT_MS, temperature: 0.35, responseFormat: { type: "json_object" },
      });
      providerDurationMs = providerResponse.durationMs;
      diagnosticId = await recordDiagnostic(admin, {
        generationType: "encounter_schedule", userId: actorUserId, characterId: source.character_id,
        sourceRef: batchId, model: providerResponse.model, provider: providerResponse.provider,
        requestId: providerResponse.requestId, httpStatus: providerResponse.httpStatus,
        finishReason: providerResponse.finishReason, responseContentType: providerResponse.responseContentType,
        responseBodyLength: providerResponse.responseBodyLength, responseParsed: providerResponse.responseParsed,
        rawOutputText: providerResponse.rawOutputText || (providerResponse.result.kind === "generated" ? providerResponse.result.text : ""),
    rawResponseBody: providerResponse.rawResponseBody,
        refusalText: providerResponse.rawRefusalText, usage: providerResponse.usage,
        status: providerResponse.result.kind === "generated" ? "received" : "failed",
        failureStage: providerResponse.result.kind === "generated" ? null : "provider_response",
        failureCode: providerResponse.result.kind === "provider_error" ? providerResponse.result.code :
          providerResponse.result.kind === "content_rejected" ? "schedule_content_rejected" :
          providerResponse.result.kind === "empty_output" ? "schedule_empty_output" : null,
      });
      rawOutputId = await recordRawGenerationOutput(
        admin, batchId, source.character_id, actorUserId, providerResponse,
      );
      if (!rawOutputId) {
        await updateDiagnostic(admin, diagnosticId, { status: "failed", failureStage: "diagnostic_persistence", failureCode: "schedule_raw_output_persist_failed" });
        return { sourceId: source.character_id, failureCode: "schedule_raw_output_persist_failed", retryable: false, ambiguous: false };
      }
      if (providerResponse.result.kind !== "generated") {
        const result = providerResponse.result;
        await updateDiagnostic(admin, diagnosticId, { status: "failed", failureStage: "provider_response", failureCode: result.kind === "provider_error" ? result.code : result.kind === "content_rejected" ? "schedule_content_rejected" : "schedule_empty_output" });
        const failureCode = result.kind === "provider_error" ? result.code :
          result.kind === "content_rejected" ? "schedule_content_rejected" : "schedule_empty_output";
        await updateRawGenerationOutput(admin, rawOutputId, "failed", failureCode);
        await recordBatchUsage(admin, batchId, providerResponse, "failed", failureCode, source.character_id);
        const ambiguous = providerResponse.responseParsed === false ||
          providerResponse.httpStatus === 408 || providerResponse.httpStatus >= 500;
        return { sourceId: source.character_id, failureCode,
          retryable: !ambiguous && result.kind === "provider_error" ? result.retryable === true : false,
          ambiguous };
      }
      let decodedValue: unknown;
      try { decodedValue = JSON.parse(providerResponse.result.text); }
      catch {
        await updateDiagnostic(admin, diagnosticId, { status: "failed", failureStage: "output_parsing", failureCode: "schedule_output_json_invalid", validationErrors: ["invalid_json"] });
        await updateRawGenerationOutput(admin, rawOutputId, "failed", "schedule_output_json_invalid", ["invalid_json"]);
        await recordBatchUsage(admin, batchId, providerResponse, "failed", "schedule_output_json_invalid", source.character_id, {
          output_shape_error: "invalid_json",
        });
        return { sourceId: source.character_id, failureCode: "schedule_output_json_invalid", retryable: false, ambiguous: false };
      }
      if (!decodedValue || typeof decodedValue !== "object" || Array.isArray(decodedValue)) {
        await updateDiagnostic(admin, diagnosticId, { status: "failed", failureStage: "output_validation", failureCode: "schedule_output_root_invalid", validationErrors: ["schedule_output_root_invalid"] });
        await updateRawGenerationOutput(admin, rawOutputId, "failed", "schedule_output_root_invalid", ["schedule_output_root_invalid"]);
        await recordBatchUsage(admin, batchId, providerResponse, "failed", "schedule_output_root_invalid", source.character_id, {
          output_root_type: Array.isArray(decodedValue) ? "array" : decodedValue === null ? "null" : typeof decodedValue,
        });
        return { sourceId: source.character_id, failureCode: "schedule_output_root_invalid", retryable: false, ambiguous: false };
      }
      const decoded = asRow(decodedValue);
      const characters = decoded.characters;
      const scenes = decoded.scenes == null ? [] : decoded.scenes;
      const rootKeys = Object.keys(decoded).sort();
      const unknownRootKeys = rootKeys.filter((key) => !["characters", "scenes", "diagnostics"].includes(key));
      const outputDiagnostics = {
        output_root_keys: rootKeys.slice(0, 12),
        output_characters_count: Array.isArray(characters) ? characters.length : null,
        output_scenes_type: scenes === null ? "null" : Array.isArray(scenes) ? "array" : typeof scenes,
        output_unknown_root_keys: unknownRootKeys.slice(0, 8),
      };
      if (!Array.isArray(characters) || characters.length !== 1 || !Array.isArray(scenes) || unknownRootKeys.length > 0) {
        const failureCode = !Array.isArray(characters) ? "schedule_output_characters_invalid" :
          characters.length !== 1 ? "schedule_single_character_count_invalid" :
          !Array.isArray(scenes) ? "schedule_output_scenes_invalid" : "schedule_output_unknown_root_fields";
        await updateDiagnostic(admin, diagnosticId, { status: "failed", failureStage: "output_validation", failureCode, validationErrors: [failureCode], metadata: outputDiagnostics });
        await updateRawGenerationOutput(admin, rawOutputId, "failed", failureCode, [failureCode]);
        await recordBatchUsage(admin, batchId, providerResponse, "failed", failureCode, source.character_id, {
          ...outputDiagnostics,
          output_shape_error: failureCode,
        });
        return { sourceId: source.character_id, failureCode, retryable: false, ambiguous: false };
      }
      const character = asRow(characters[0]);
      if (asText(character.character_id) !== source.character_id) {
        await updateDiagnostic(admin, diagnosticId, { status: "failed", failureStage: "output_validation", failureCode: "schedule_character_identity_mismatch", validationErrors: ["character_identity_mismatch"] });
        await updateRawGenerationOutput(admin, rawOutputId, "failed", "schedule_character_identity_mismatch", ["character_identity_mismatch"]);
        await recordBatchUsage(admin, batchId, providerResponse, "failed", "schedule_character_identity_mismatch", source.character_id);
        return { sourceId: source.character_id, failureCode: "schedule_character_identity_mismatch", retryable: false, ambiguous: false };
      }
      await updateDiagnostic(admin, diagnosticId, { status: "completed", failureStage: null, failureCode: null, metadata: { validated_character_count: 1, scene_count: scenes.length } });
      return { sourceId: source.character_id, providerResponse, rawOutputId, character, scenes };
    } catch (error) {
      const measuredProviderDurationMs = providerDurationMs || Date.now() - providerStartedAt;
      const failureCode = error instanceof Error && error.name === "AbortError"
        ? "schedule_provider_timeout" : "schedule_provider_outcome_unknown";
      await updateDiagnostic(admin, diagnosticId, { status: "failed", failureStage: "provider_request", failureCode });
      await updateRawGenerationOutput(admin, rawOutputId, "failed", failureCode, [failureCode]);
      await recordBatchUsage(admin, batchId, {
        provider: "openrouter", requestId: "", usage: {}, httpStatus: 0,
        responseContentType: "", responseBodyLength: 0, responseParsed: false,
      }, "failed", failureCode, source.character_id, {
        provider_duration_ms: measuredProviderDurationMs,
      });
      return { sourceId: source.character_id, failureCode, retryable: false, ambiguous: true };
    }
  }));
  for (const result of generationResults) {
    if ("failureCode" in result) {
      failedCharacterIds.add(result.sourceId);
      validationErrors.push(result.sourceId + ":" + result.failureCode);
      retryableProviderFailure ||= result.retryable === true;
      ambiguousProviderFailure ||= result.ambiguous === true;
      continue;
    }
    providerResponses.push({ sourceId: result.sourceId, providerResponse: result.providerResponse });
    rawOutputIdByCharacter.set(result.sourceId, result.rawOutputId);
    rawCharacters.push(result.character);
    for (const scene of result.scenes) {
      const key = normalizeEncounterSceneKey(asRow(scene).location_key);
      if (key && !rawScenesByKey.has(key)) rawScenesByKey.set(key, scene);
    }
  }
  const rawScenes = [...rawScenesByKey.values()];
  const validCharacters: Array<{
    sourceId: string;
    character: Record<string, unknown>;
    scenes: Array<Record<string, unknown>>;
  }> = [];
  for (const source of enrichedSources) {
    if (failedCharacterIds.has(source.character_id) || reviewRequiredCharacterIds.has(source.character_id)) continue;
    const matches = rawCharacters.filter((item) => asText(asRow(item).character_id) === source.character_id);
    if (matches.length !== 1) {
      failedCharacterIds.add(source.character_id);
      validationErrors.push(source.character_id + (matches.length ? "_duplicate_output" : "_missing_output"));
      continue;
    }

    const rawCharacter = asRow(matches[0]);
    const parsed = parseEncounterScheduleBatchOutput(
      JSON.stringify({ characters: [rawCharacter], scenes: rawScenes }),
      [source],
      sceneCatalog,
    );
    if (!parsed.ok || parsed.characters.length !== 1) {
      failedCharacterIds.add(source.character_id);
      const safeErrors = parsed.errors.slice(0, 20);
      validationErrors.push(...safeErrors.map((error) => source.character_id + ":" + error));
      characterDiagnosticsById.set(source.character_id, {
        validation_errors: safeErrors,
        validation_error_count: parsed.errors.length,
      });
      await updateRawGenerationOutput(admin, rawOutputIdByCharacter.get(source.character_id) || null,
        "failed", "schedule_character_validation_failed", safeErrors);
      continue;
    }

    const protectedValues = protectedContextByCharacter[source.character_id] || [];
    if (findPrivateContextLeak(JSON.stringify(parsed.characters[0]), protectedValues, [])) {
      failedCharacterIds.add(source.character_id);
      validationErrors.push(source.character_id + "_private_context_output_blocked");
      characterDiagnosticsById.set(source.character_id, {
        validation_errors: ["private_context_output_blocked"],
      });
      await updateRawGenerationOutput(admin, rawOutputIdByCharacter.get(source.character_id) || null,
        "failed", "private_context_output_blocked", ["private_context_output_blocked"]);
      continue;
    }
    validCharacters.push({
      sourceId: source.character_id,
      character: parsed.characters[0] as unknown as Record<string, unknown>,
      scenes: parsed.scenes as unknown as Array<Record<string, unknown>>,
    });
  }

  let publishedCharacterCount = 0;
  let unplacedCharacterCount = 0;
  let skippedCharacterCount = 0;
  let ambiguousPublishFailure = false;
  const committedCharacterIds = new Set<string>();
  const scenesByKey = new Map<string, Record<string, unknown>>();

  // Persist each validated character in its own database transaction. A bad
  // schedule or a transient write failure therefore cannot roll back other
  // characters that were already completed in this same AI response.
  for (const item of validCharacters) {
    const { data: published, error: publishError } = await admin.rpc("publish_encounter_schedule_batch", {
      p_batch_id: batchId,
      p_lease_token: leaseToken,
      p_characters: [item.character],
    });
    if (publishError) {
      const { data: job, error: jobError } = await admin.from("encounter_schedule_generation_jobs")
        .select("status").eq("character_id", item.sourceId).maybeSingle();
      if (jobError) {
        ambiguousPublishFailure = true;
        failedCharacterIds.add(item.sourceId);
        continue;
      }
      if (job?.status === "completed") {
        committedCharacterIds.add(item.sourceId);
        await updateRawGenerationOutput(admin, rawOutputIdByCharacter.get(item.sourceId) || null, "completed");
        publishedCharacterCount += 1;
      } else if (job?.status === "cancelled") {
        committedCharacterIds.add(item.sourceId);
        await updateRawGenerationOutput(admin, rawOutputIdByCharacter.get(item.sourceId) || null, "cancelled");
        skippedCharacterCount += 1;
      } else {
        failedCharacterIds.add(item.sourceId);
        characterDiagnosticsById.set(item.sourceId, {
          publish_error: "publish_rpc_failed",
          job_status_after_error: asText(job?.status) || "unknown",
        });
        await updateRawGenerationOutput(admin, rawOutputIdByCharacter.get(item.sourceId) || null,
          "failed", "publish_rpc_failed");
      }
      console.warn("Encounter schedule character publish failed:", item.sourceId, publishError.message);
      continue;
    }
    const publishRow = Array.isArray(published) ? published[0] : published;
    if (!publishRow || !["partial", "completed"].includes(asText(publishRow.status))) {
      failedCharacterIds.add(item.sourceId);
      characterDiagnosticsById.set(item.sourceId, {
        publish_status: asText(publishRow?.status) || "missing",
      });
      await updateRawGenerationOutput(admin, rawOutputIdByCharacter.get(item.sourceId) || null,
        "failed", "schedule_publish_status_invalid");
      continue;
    }
    committedCharacterIds.add(item.sourceId);
    await updateRawGenerationOutput(admin, rawOutputIdByCharacter.get(item.sourceId) || null, "completed");
    publishedCharacterCount += Number(publishRow.published_character_count || 0);
    unplacedCharacterCount += Number(publishRow.unplaced_character_count || 0);
    skippedCharacterCount += Number(publishRow.skipped_private_character_count || 0);
  }

  for (const item of validCharacters) {
    if (!committedCharacterIds.has(item.sourceId)) continue;
    for (const scene of item.scenes) {
      const key = asText(scene.location_key);
      if (key && !scenesByKey.has(key)) scenesByKey.set(key, scene);
    }
  }

  // Scene metadata is published only after schedule rows are committed, so the
  // database can verify shared-character counts and available marker slots.
  let scenePublishStatus = "no_scene_metadata";
  let publishedSceneCount = 0;
  let skippedSceneCount = 0;
  const scenePayload = [...scenesByKey.values()];
  if (scenePayload.length > 0) {
    const { data: sceneResult, error: sceneError } = await admin.rpc("publish_encounter_scene_metadata", {
      p_scenes: scenePayload,
    });
    if (sceneError) {
      scenePublishStatus = "failed";
      console.warn("Encounter scene metadata publish failed:", sceneError.message);
    } else {
      const sceneRow = Array.isArray(sceneResult) ? sceneResult[0] : sceneResult;
      publishedSceneCount = Number(sceneRow?.published_scene_count || 0);
      skippedSceneCount = Number(sceneRow?.skipped_scene_count || 0);
      scenePublishStatus = skippedSceneCount > 0 ? "partial" : "completed";
    }
  }

  if (reviewRequiredCharacterIds.size > 0) {
    const reviewIds = [...reviewRequiredCharacterIds];
    const reviewedAt = new Date().toISOString();
    const { error: reviewUpdateError } = await admin
      .from("encounter_schedule_generation_jobs")
      .update({
        status: "needs_review",
        lease_token: null,
        lease_expires_at: null,
        last_error_code: "worldview_manual_review_required",
        updated_at: reviewedAt,
      })
      .eq("lease_token", leaseToken)
      .eq("status", "processing")
      .in("character_id", reviewIds);
    if (reviewUpdateError) {
      for (const characterId of reviewIds) {
        failedCharacterIds.add(characterId);
        validationErrors.push(characterId + ":worldview_review_state_persist_failed");
      }
      console.warn("Encounter worldview review state update failed:", reviewUpdateError.message);
    }
  }

  const { count: remainingCount, error: remainingError } = await admin
    .from("encounter_schedule_generation_jobs")
    .select("character_id", { count: "exact", head: true })
    .eq("lease_token", leaseToken)
    .eq("status", "processing");
  if (remainingError) ambiguousPublishFailure = true;
  const remaining = Number(remainingCount || 0);
  // A review-only batch has no publisher call to close its batch ledger.
  // Once all review jobs have left the processing lease, close the batch
  // explicitly without marking the reviewed characters as failed.
  if (remaining === 0 && reviewRequiredCharacterIds.size > 0 &&
      failedCharacterIds.size === 0 && !ambiguousPublishFailure && !ambiguousProviderFailure) {
    const completedAt = new Date().toISOString();
    const { data: completedBatch, error: completeBatchError } = await admin
      .from("encounter_schedule_batch_runs")
      .update({ status: "completed", completed_at: completedAt, updated_at: completedAt })
      .eq("id", batchId)
      .eq("lease_token", leaseToken)
      .eq("status", "processing")
      .select("id")
      .maybeSingle();
    if (completeBatchError || !completedBatch) {
      ambiguousPublishFailure = true;
      console.warn("Encounter review-only batch finalization failed:",
        completeBatchError?.message || "batch_not_updated");
    }
  }
  if (remaining > 0 || ambiguousPublishFailure || failedCharacterIds.size > 0) {
    const failed = await failBatch(
      admin,
      batchId,
      leaseToken,
      ambiguousProviderFailure ? "schedule_provider_outcome_unknown" :
        retryableProviderFailure ? "schedule_provider_retryable_failure" : "schedule_partial_character_failure",
      retryableProviderFailure,
      ambiguousPublishFailure || ambiguousProviderFailure,
    );
    if (!failed) {
      for (const item of providerResponses) {
        await recordBatchUsage(admin, batchId, item.providerResponse, "failed", "schedule_partial_failure_unconfirmed", item.sourceId);
      }
      return json({ status: "batch_failure_unconfirmed", error: "schedule_partial_character_failure" }, 503);
    }
  }

  const partial = remaining > 0 || ambiguousPublishFailure || ambiguousProviderFailure || failedCharacterIds.size > 0;
  for (const item of providerResponses) {
    const characterDiagnostics = characterDiagnosticsById.get(item.sourceId) || {};
    const characterFailureCode = typeof characterDiagnostics.validation_errors === "object"
      ? "schedule_character_validation_failed"
      : typeof characterDiagnostics.publish_error === "string" || typeof characterDiagnostics.publish_status === "string"
        ? "schedule_character_publish_failed"
        : partial ? "schedule_partial_character_failure" : null;
    await recordBatchUsage(admin, batchId, item.providerResponse, partial ? "partial" : "completed",
      characterFailureCode, item.sourceId, characterDiagnostics);
  }
  return json({
    status: partial ? "partial" : "completed",
    batch_id: batchId,
    queued_character_count: queuedCharacterCount,
    published_character_count: publishedCharacterCount,
    unplaced_character_count: unplacedCharacterCount,
    skipped_private_character_count: skippedCharacterCount,
    needs_review_character_count: reviewRequiredCharacterIds.size,
    failed_character_count: partial ? Math.max(remaining, failedCharacterIds.size) : 0,
    validation_errors: validationErrors.slice(0, 30),
    scene_publish_status: scenePublishStatus,
    published_scene_count: publishedSceneCount,
    skipped_scene_count: skippedSceneCount,
  });
}
