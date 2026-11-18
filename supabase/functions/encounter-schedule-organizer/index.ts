import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requestOpenRouterChatCompletion, POYOZZ_DEFAULT_CHAT_MODEL } from "../_shared/openrouter-chat-completions.ts";
import { findPrivateContextLeak } from "../_shared/private-context-guard.ts";
import {
  buildEncounterScheduleBatchMessages,
  parseEncounterScheduleBatchOutput,
  normalizeEncounterSceneKey,
  type EncounterScheduleSource,
  type EncounterSceneCatalogEntry,
} from "../_shared/encounter-schedule-generation.ts";

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

async function handleScheduleRepair(admin: any, actorUserId: string, body: Record<string, unknown>) {
  const outputId = asText(body.output_id);
  const correctedText = typeof body.corrected_response === "string" ? body.corrected_response : "";
  if (!/^[0-9a-f-]{36}$/i.test(outputId) || correctedText.length < 2 || correctedText.length > 500000) {
    return json({ error: "schedule_repair_input_invalid" }, 400);
  }

  const { data: output, error: outputError } = await admin.from("encounter_schedule_generation_outputs")
    .select("*").eq("id", outputId).eq("actor_user_id", actorUserId)
    .gt("expires_at", new Date().toISOString()).maybeSingle();
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

  let promptContext;
  try {
    promptContext = buildEncounterScheduleBatchMessages([source as EncounterScheduleSource]);
  } catch (error) {
    return json({ error: asText(error instanceof Error ? error.message : "schedule_repair_context_invalid") }, 409);
  }

  const { data: sceneCatalogData, error: sceneCatalogError } = await admin.rpc("get_encounter_scene_catalog");
  const sceneCatalog = sceneCatalogError
    ? []
    : (Array.isArray(sceneCatalogData) ? sceneCatalogData : []) as EncounterSceneCatalogEntry[];
  if (sceneCatalogError) {
    console.warn("Encounter repair scene catalog unavailable; validating natural locations:", sceneCatalogError.message);
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

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const openRouterKey = Deno.env.get("OPENROUTER_API_KEY")?.trim();
  const authorization = request.headers.get("Authorization") || "";
  if (!url || !anon || !service) return json({ error: "server_not_configured" }, 503);

  let body: Record<string, unknown> = {};
  try { body = asRow(await request.json()); } catch { return json({ error: "invalid_json" }, 400); }
  const mode = ["manual", "status", "repair_list", "repair"].includes(asText(body.mode))
    ? asText(body.mode)
    : "scheduled";
  const isServiceRoleRequest = authorization === "Bearer " + service;
  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
  let actorUserId: string | null = null;

  if (mode === "status") {
    if (Deno.env.get("ENCOUNTER_SCHEDULE_TEST_MODE") !== "true") {
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
    const [pendingResult, processingResult, failedResult, reconciliationResult, lastRunResult] = await Promise.all([
      admin.from("encounter_schedule_generation_jobs").select("character_id", { count: "exact", head: true })
        .eq("status", "pending"),
      admin.from("encounter_schedule_generation_jobs").select("character_id", { count: "exact", head: true })
        .eq("status", "processing"),
      admin.from("encounter_schedule_generation_jobs").select("character_id", { count: "exact", head: true })
        .eq("status", "failed"),
      admin.from("encounter_schedule_generation_jobs").select("character_id", { count: "exact", head: true })
        .eq("status", "needs_reconciliation"),
      admin.from("encounter_schedule_batch_runs").select("completed_at,status")
        .eq("status", "completed").not("completed_at", "is", null)
        .order("completed_at", { ascending: false }).limit(1).maybeSingle(),
    ]);
    if (pendingResult.error || processingResult.error || failedResult.error || reconciliationResult.error || lastRunResult.error) {
      return json({ enabled: true, test_mode: true, status_available: false });
    }
    return json({
      enabled: true,
      test_mode: true,
      pending_character_count: Number(pendingResult.count || 0),
      processing_character_count: Number(processingResult.count || 0),
      failed_character_count: Number(failedResult.count || 0),
      needs_reconciliation_count: Number(reconciliationResult.count || 0),
      last_batch_completed_at: lastRunResult.data?.completed_at || null,
      last_batch_status: lastRunResult.data?.status || null,
    });
  }


  if (mode === "repair_list" || mode === "repair") {
    if (Deno.env.get("ENCOUNTER_SCHEDULE_TEST_MODE") !== "true" || isServiceRoleRequest) {
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
      await admin.from("encounter_schedule_generation_outputs")
        .delete().lt("expires_at", new Date().toISOString());
      const { data: outputs, error: outputsError } = await admin.from("encounter_schedule_generation_outputs")
        .select("id,batch_id,character_id,requested_model,provider,response_model,finish_reason,raw_response_text,raw_output_truncated,raw_response_body,response_body_truncated,http_status,status,failure_code,validation_errors,created_at")
        .eq("actor_user_id", actorUserId)
        .in("status", ["failed", "partial", "received"])
        .gt("expires_at", new Date().toISOString())
        .order("created_at", { ascending: false })
        .limit(20);
      if (outputsError) return json({ error: "schedule_repair_list_unavailable" }, 503);
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
        })),
      });
    }
    return await handleScheduleRepair(admin, actorUserId, body);
  }

  if (!openRouterKey) return json({ error: "openrouter_not_configured" }, 503);

  if (mode === "manual") {
    // The test-only UI is absent from production builds. Keep a server-side
    // project-mode guard and require a real signed-in user, without a per-user
    // allowlist or unrelated account-state gate in the test environment.
    if (Deno.env.get("ENCOUNTER_SCHEDULE_TEST_MODE") !== "true" || isServiceRoleRequest) {
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
    // A deliberate test-mode manual click may retry terminal failed jobs:
    // those jobs have no ambiguous publish outcome. Keep active leases and
    // needs_reconciliation blocked so an uncertain write is never duplicated.
    const [processingResult, reconciliationResult] = await Promise.all([
      admin.from("encounter_schedule_generation_jobs").select("character_id", { count: "exact", head: true })
        .eq("status", "processing"),
      admin.from("encounter_schedule_generation_jobs").select("character_id", { count: "exact", head: true })
        .eq("status", "needs_reconciliation"),
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
    const { data: enqueueData, error: enqueueError } = await admin.rpc(
      "enqueue_encounter_schedule_generation_test_batch",
      { p_limit: 2147483647 },
    );
    if (enqueueError) {
      console.error("Encounter manual enqueue failed:", enqueueError.message);
      return json({ error: "schedule_manual_enqueue_failed" }, 503);
    }
    const enqueueRow = Array.isArray(enqueueData) ? enqueueData[0] : enqueueData;
    queuedCharacterCount = Number(enqueueRow?.pending_character_count || 0);
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
  const validationErrors: string[] = [];
  const characterDiagnosticsById = new Map<string, Record<string, unknown>>();
  const rawOutputIdByCharacter = new Map<string, string>();
  let retryableProviderFailure = false;
  let ambiguousProviderFailure = false;

  // One character per request isolates provider output and keeps the next test batch minimal.
  const generationResults = await Promise.all(sources.map(async (source) => {
    let characterPrompt;
    try {
      characterPrompt = buildEncounterScheduleBatchMessages([source]);
      protectedContextByCharacter[source.character_id] =
        characterPrompt.protectedContextByCharacter[source.character_id] || [];
    } catch (error) {
      return { sourceId: source.character_id, failureCode: asText(error instanceof Error ? error.message : "schedule_prompt_invalid"), retryable: false, ambiguous: false };
    }
    let rawOutputId: string | null = null;
    try {
      const providerResponse = await requestOpenRouterChatCompletion({
        messages: characterPrompt.messages, apiKey: openRouterKey, model: POYOZZ_DEFAULT_CHAT_MODEL,
        timeoutMs: 42_000, temperature: 0.35, responseFormat: { type: "json_object" },
      });
      rawOutputId = await recordRawGenerationOutput(
        admin, batchId, source.character_id, actorUserId, providerResponse,
      );
      if (!rawOutputId) {
        return { sourceId: source.character_id, failureCode: "schedule_raw_output_persist_failed", retryable: false, ambiguous: false };
      }
      if (providerResponse.result.kind !== "generated") {
        const result = providerResponse.result;
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
        await updateRawGenerationOutput(admin, rawOutputId, "failed", "schedule_output_json_invalid", ["invalid_json"]);
        await recordBatchUsage(admin, batchId, providerResponse, "failed", "schedule_output_json_invalid", source.character_id, {
          output_shape_error: "invalid_json",
        });
        return { sourceId: source.character_id, failureCode: "schedule_output_json_invalid", retryable: false, ambiguous: false };
      }
      if (!decodedValue || typeof decodedValue !== "object" || Array.isArray(decodedValue)) {
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
        await updateRawGenerationOutput(admin, rawOutputId, "failed", failureCode, [failureCode]);
        await recordBatchUsage(admin, batchId, providerResponse, "failed", failureCode, source.character_id, {
          ...outputDiagnostics,
          output_shape_error: failureCode,
        });
        return { sourceId: source.character_id, failureCode, retryable: false, ambiguous: false };
      }
      const character = asRow(characters[0]);
      if (asText(character.character_id) !== source.character_id) {
        await updateRawGenerationOutput(admin, rawOutputId, "failed", "schedule_character_identity_mismatch", ["character_identity_mismatch"]);
        await recordBatchUsage(admin, batchId, providerResponse, "failed", "schedule_character_identity_mismatch", source.character_id);
        return { sourceId: source.character_id, failureCode: "schedule_character_identity_mismatch", retryable: false, ambiguous: false };
      }
      return { sourceId: source.character_id, providerResponse, rawOutputId, character, scenes };
    } catch (error) {
      const failureCode = error instanceof Error && error.name === "AbortError"
        ? "schedule_provider_timeout" : "schedule_provider_outcome_unknown";
      await updateRawGenerationOutput(admin, rawOutputId, "failed", failureCode, [failureCode]);
      await recordBatchUsage(admin, batchId, {
        provider: "openrouter", requestId: "", usage: {}, httpStatus: 0,
        responseContentType: "", responseBodyLength: 0, responseParsed: false,
      }, "failed", failureCode, source.character_id);
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
  for (const source of sources) {
    if (failedCharacterIds.has(source.character_id)) continue;
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

  const { count: remainingCount, error: remainingError } = await admin
    .from("encounter_schedule_generation_jobs")
    .select("character_id", { count: "exact", head: true })
    .eq("lease_token", leaseToken)
    .eq("status", "processing");
  if (remainingError) ambiguousPublishFailure = true;
  const remaining = Number(remainingCount || 0);
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
    failed_character_count: partial ? Math.max(remaining, failedCharacterIds.size) : 0,
    validation_errors: validationErrors.slice(0, 30),
    scene_publish_status: scenePublishStatus,
    published_scene_count: publishedSceneCount,
    skipped_scene_count: skippedSceneCount,
  });
});
