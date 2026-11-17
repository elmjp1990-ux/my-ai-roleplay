import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requestOpenRouterChatCompletion, POYOZZ_DEFAULT_CHAT_MODEL } from "../_shared/openrouter-chat-completions.ts";
import { findPrivateContextLeak } from "../_shared/private-context-guard.ts";
import {
  buildEncounterScheduleBatchMessages,
  parseEncounterScheduleBatchOutput,
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

async function recordBatchUsage(admin: any, batchId: string, providerResponse: any, status: string, failureCode: string | null = null) {
  const { error } = await admin.from("encounter_schedule_generation_usage").insert({
    batch_id: batchId,
    requested_model: POYOZZ_DEFAULT_CHAT_MODEL,
    provider: asText(providerResponse?.provider) || "openrouter",
    status,
    usage: providerResponse?.usage && typeof providerResponse.usage === "object" ? providerResponse.usage : {},
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
  const mode = body.mode === "manual" ? "manual" : body.mode === "status" ? "status" : "scheduled";
  const isServiceRoleRequest = authorization === "Bearer " + service;
  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
  let actorUserId: string | null = null;

  if (mode === "status") {
    if (Deno.env.get("ENCOUNTER_SCHEDULE_TEST_MODE") !== "true" || isServiceRoleRequest) {
      return json({ enabled: false });
    }
    const userClient = createClient(url, anon, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await userClient.auth.getUser();
    if (authError || !authData?.user) return json({ enabled: false });
    actorUserId = authData.user.id;
    const allowed = (Deno.env.get("ENCOUNTER_SCHEDULE_TEST_USER_IDS") || "")
      .split(",").map((value) => value.trim()).filter(Boolean);
    if (!allowed.includes(actorUserId)) return json({ enabled: false });
    const { data: active, error: activeError } = await userClient.rpc("account_is_active");
    if (activeError || active !== true) return json({ enabled: false });

    const [pendingResult, lastRunResult] = await Promise.all([
      admin.from("encounter_schedule_generation_jobs").select("character_id", { count: "exact", head: true })
        .in("status", ["pending", "failed", "needs_reconciliation"]),
      admin.from("encounter_schedule_batch_runs").select("started_at,status")
        .order("started_at", { ascending: false }).limit(1).maybeSingle(),
    ]);
    if (pendingResult.error || lastRunResult.error) return json({ enabled: true, status_available: false });
    return json({
      enabled: true,
      pending_character_count: Number(pendingResult.count || 0),
      last_batch_started_at: lastRunResult.data?.started_at || null,
      last_batch_status: lastRunResult.data?.status || null,
    });
  }

  if (!openRouterKey) return json({ error: "openrouter_not_configured" }, 503);

  if (mode === "manual") {
    // Manual bypass exists only in the test project and only for explicitly allowlisted users.
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
    const allowed = (Deno.env.get("ENCOUNTER_SCHEDULE_TEST_USER_IDS") || "")
      .split(",").map((value) => value.trim()).filter(Boolean);
    if (!allowed.includes(actorUserId)) return json({ error: "manual_schedule_trigger_forbidden" }, 403);
    const { data: active, error: activeError } = await userClient.rpc("account_is_active");
    if (activeError || active !== true) return json({ error: "account_not_active" }, 403);
  } else if (!isServiceRoleRequest) {
    return json({ error: "scheduled_trigger_requires_service_role" }, 401);
  }

  let queuedCharacterCount = 0;
  if (mode === "manual") {
    const { data: enqueueData, error: enqueueError } = await admin.rpc(
      "enqueue_encounter_schedule_generation_test_batch",
      { p_limit: 500 },
    );
    if (enqueueError) {
      console.error("Encounter manual enqueue failed:", enqueueError.message);
      return json({ error: "schedule_manual_enqueue_failed" }, 503);
    }
    const enqueueRow = Array.isArray(enqueueData) ? enqueueData[0] : enqueueData;
    queuedCharacterCount = Number(enqueueRow?.pending_character_count || 0);
  }

  const { data: claimData, error: claimError } = await admin.rpc("claim_encounter_schedule_batch", {
    p_limit: 10,
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
  if (!batchId || !leaseToken || sources.length < 1 || sources.length > 10) {
    if (batchId && leaseToken) await failBatch(admin, batchId, leaseToken, "claimed_batch_payload_invalid", false);
    return json({ error: "claimed_batch_payload_invalid" }, 503);
  }

  const { data: sceneCatalogData, error: sceneCatalogError } = await admin.rpc("get_encounter_scene_catalog");
  if (sceneCatalogError) {
    await failBatch(admin, batchId, leaseToken, "scene_catalog_load_failed", false);
    return json({ error: "scene_catalog_unavailable" }, 503);
  }
  const sceneCatalog = (Array.isArray(sceneCatalogData) ? sceneCatalogData : []) as EncounterSceneCatalogEntry[];

  let prompt;
  try {
    prompt = buildEncounterScheduleBatchMessages(sources, sceneCatalog);
  } catch (error) {
    const code = asText(error instanceof Error ? error.message : "schedule_prompt_invalid");
    await failBatch(admin, batchId, leaseToken, code, false);
    return json({ error: "schedule_source_validation_failed" }, 422);
  }

  let providerResponse: Awaited<ReturnType<typeof requestOpenRouterChatCompletion>>;
  try {
    providerResponse = await requestOpenRouterChatCompletion({
      messages: prompt.messages,
      apiKey: openRouterKey,
      model: POYOZZ_DEFAULT_CHAT_MODEL,
      timeoutMs: 55_000,
      temperature: 0.35,
      responseFormat: { type: "json_object" },
    });
  } catch (error) {
    const code = error instanceof Error && error.name === "AbortError"
      ? "schedule_provider_timeout" : "schedule_provider_outcome_unknown";
    const failed = await failBatch(admin, batchId, leaseToken, code, false, true);
    return json({ status: failed ? "needs_reconciliation" : "batch_failure_unconfirmed", error: code }, 503);
  }

  if (providerResponse.result.kind !== "generated") {
    const result = providerResponse.result;
    const failureCode = result.kind === "provider_error" ? result.code :
      result.kind === "content_rejected" ? "schedule_content_rejected" : "schedule_empty_output";
    await recordBatchUsage(admin, batchId, providerResponse, "failed", failureCode);
    const retryable = result.kind === "provider_error" ? result.retryable : false;
    const failed = await failBatch(admin, batchId, leaseToken, failureCode, retryable, false);
    return json({ status: failed ? "generation_failed" : "batch_failure_unconfirmed", error: failureCode }, 503);
  }

  const parsed = parseEncounterScheduleBatchOutput(providerResponse.result.text, sources, sceneCatalog);
  if (!parsed.ok) {
    await recordBatchUsage(admin, batchId, providerResponse, "failed", "schedule_output_validation_failed");
    const failed = await failBatch(admin, batchId, leaseToken, "schedule_output_validation_failed", true, false);
    return json({
      status: failed ? "generation_invalid" : "batch_failure_unconfirmed",
      validation_errors: parsed.errors.slice(0, 20),
    }, 422);
  }

  const leakedCharacters = parsed.characters.filter((character) => {
    const protectedValues = prompt.protectedContextByCharacter[character.character_id] || [];
    return findPrivateContextLeak(JSON.stringify(character), protectedValues, []);
  }).map((character) => character.character_id);
  if (leakedCharacters.length) {
    await recordBatchUsage(admin, batchId, providerResponse, "failed", "schedule_private_context_output_blocked");
    const failed = await failBatch(admin, batchId, leaseToken, "schedule_private_context_output_blocked", true, false);
    return json({
      status: failed ? "generation_blocked" : "batch_failure_unconfirmed",
      blocked_character_count: leakedCharacters.length,
    }, 422);
  }

  const { data: published, error: publishError } = await admin.rpc("publish_encounter_schedule_batch", {
    p_batch_id: batchId,
    p_lease_token: leaseToken,
    p_characters: parsed.characters,
  });
  if (publishError) {
    await recordBatchUsage(admin, batchId, providerResponse, "failed", "schedule_publish_failed");
    const failed = await failBatch(admin, batchId, leaseToken, "schedule_publish_failed", true, true);
    return json({ status: failed ? "needs_reconciliation" : "batch_failure_unconfirmed" }, 503);
  }

  // Scene metadata is published only after schedule rows are committed, so the
  // database can verify cross-batch character counts before creating a marker.
  let scenePublishStatus = "no_scene_metadata";
  let publishedSceneCount = 0;
  if (parsed.scenes.length > 0) {
    const { data: sceneResult, error: sceneError } = await admin.rpc("publish_encounter_scene_metadata", {
      p_scenes: parsed.scenes,
    });
    if (sceneError) {
      scenePublishStatus = "failed";
      console.warn("Encounter scene metadata publish failed:", sceneError.message);
    } else {
      const sceneRow = Array.isArray(sceneResult) ? sceneResult[0] : sceneResult;
      scenePublishStatus = "completed";
      publishedSceneCount = Number(sceneRow?.published_scene_count || 0);
    }
  }

  await recordBatchUsage(admin, batchId, providerResponse, "completed");
  const result = Array.isArray(published) ? published[0] : published;
  return json({
    status: "completed",
    batch_id: batchId,
    queued_character_count: queuedCharacterCount,
    published_character_count: Number(result?.published_character_count || 0),
    unplaced_character_count: Number(result?.unplaced_character_count || 0),
    skipped_private_character_count: Number(result?.skipped_private_character_count || 0),
    scene_publish_status: scenePublishStatus,
    published_scene_count: publishedSceneCount,
  });
});
