import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requestOpenRouterChatCompletion, POYOZZ_DEFAULT_CHAT_MODEL } from "../_shared/openrouter-chat-completions.ts";
import { findPrivateContextLeak } from "../_shared/private-context-guard.ts";
import {
  buildEncounterScheduleBatchMessages,
  parseEncounterScheduleBatchOutput,
  ENCOUNTER_DYNAMIC_SCENE_KEYS,
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
      admin.from("encounter_schedule_batch_runs").select("completed_at,status")
        .eq("status", "completed").not("completed_at", "is", null)
        .order("completed_at", { ascending: false }).limit(1).maybeSingle(),
    ]);
    if (pendingResult.error || lastRunResult.error) return json({ enabled: true, status_available: false });
    return json({
      enabled: true,
      pending_character_count: Number(pendingResult.count || 0),
      last_batch_completed_at: lastRunResult.data?.completed_at || null,
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
    p_limit: 2147483647,
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

  let decodedOutput: Record<string, unknown>;
  try {
    decodedOutput = asRow(JSON.parse(providerResponse.result.text));
  } catch {
    await recordBatchUsage(admin, batchId, providerResponse, "failed", "schedule_output_json_invalid");
    const failed = await failBatch(admin, batchId, leaseToken, "schedule_output_json_invalid", true, false);
    return json({ status: failed ? "generation_invalid" : "batch_failure_unconfirmed" }, 422);
  }
  if (!Array.isArray(decodedOutput.characters) ||
      Object.keys(decodedOutput).some((key) => !["characters", "scenes"].includes(key))) {
    await recordBatchUsage(admin, batchId, providerResponse, "failed", "schedule_output_root_invalid");
    const failed = await failBatch(admin, batchId, leaseToken, "schedule_output_root_invalid", true, false);
    return json({ status: failed ? "generation_invalid" : "batch_failure_unconfirmed" }, 422);
  }

  const rawCharacters = decodedOutput.characters as unknown[];
  const rawScenes = Array.isArray(decodedOutput.scenes) ? decodedOutput.scenes : [];
  const sourceIds = new Set(sources.map((source) => source.character_id));
  const collectLocationKeys = (value: unknown): Set<string> => {
    const character = asRow(value);
    const keys = new Set<string>();
    const variants = asRow(character.variants);
    for (const dayType of ["weekday", "holiday"]) {
      const dayVariants = variants[dayType];
      if (!Array.isArray(dayVariants)) continue;
      for (const variant of dayVariants) {
        const slots = asRow(variant).slots;
        if (!Array.isArray(slots)) continue;
        for (const slot of slots) {
          const key = normalizeEncounterSceneKey(asRow(slot).location_key);
          if (key) keys.add(key);
        }
      }
    }
    if (Array.isArray(character.special_events)) {
      for (const event of character.special_events) {
        const slots = asRow(event).slots;
        if (!Array.isArray(slots)) continue;
        for (const slot of slots) {
          const key = normalizeEncounterSceneKey(asRow(slot).location_key);
          if (key) keys.add(key);
        }
      }
    }
    return keys;
  };

  // A new dynamic landmark is eligible only when at least two distinct claimed
  // characters use it. Reserve no more than the three server-owned map slots.
  const existingDynamicKeys = new Set(
    sceneCatalog.filter((scene) => scene?.is_dynamic === true)
      .map((scene) => normalizeEncounterSceneKey(scene.location_key))
      .filter((key): key is string => key !== null),
  );
  const dynamicUsers = new Map<string, Set<string>>();
  for (const rawCharacter of rawCharacters) {
    const id = asText(asRow(rawCharacter).character_id);
    if (!sourceIds.has(id)) continue;
    for (const key of collectLocationKeys(rawCharacter)) {
      if (!(ENCOUNTER_DYNAMIC_SCENE_KEYS as readonly string[]).includes(key) || existingDynamicKeys.has(key)) continue;
      const users = dynamicUsers.get(key) || new Set<string>();
      users.add(id);
      dynamicUsers.set(key, users);
    }
  }
  const dynamicCandidates = [...dynamicUsers.entries()]
    .filter(([, users]) => users.size >= 2)
    .sort((a, b) => b[1].size - a[1].size || a[0].localeCompare(b[0]));
  const availableDynamicSlots = Math.max(0, 3 - existingDynamicKeys.size);
  const selectedNewDynamicKeys = new Set(
    dynamicCandidates.slice(0, availableDynamicSlots).map(([key]) => key),
  );

  const failedCharacterIds = new Set<string>();
  const validationErrors: string[] = [];
  const validCharacters: Array<{
    sourceId: string;
    character: Record<string, unknown>;
    scenes: Array<Record<string, unknown>>;
  }> = [];
  for (const source of sources) {
    const matches = rawCharacters.filter((item) => asText(asRow(item).character_id) === source.character_id);
    if (matches.length !== 1) {
      failedCharacterIds.add(source.character_id);
      validationErrors.push(source.character_id + (matches.length ? "_duplicate_output" : "_missing_output"));
      continue;
    }

    const rawCharacter = asRow(matches[0]);
    const usedKeys = collectLocationKeys(rawCharacter);
    const blockedDynamicKeys = [...usedKeys].filter((key) =>
      (ENCOUNTER_DYNAMIC_SCENE_KEYS as readonly string[]).includes(key) &&
      !existingDynamicKeys.has(key) && !selectedNewDynamicKeys.has(key)
    );
    if (blockedDynamicKeys.length) {
      failedCharacterIds.add(source.character_id);
      validationErrors.push(source.character_id + "_dynamic_scene_limit_or_sharing_invalid");
      continue;
    }

    const candidateScenes = rawScenes.filter((item) => {
      const key = normalizeEncounterSceneKey(asRow(item).location_key);
      return key !== null && usedKeys.has(key);
    });
    const candidateCatalog: EncounterSceneCatalogEntry[] = [
      ...sceneCatalog,
      ...[...usedKeys].filter((key) => selectedNewDynamicKeys.has(key) && !existingDynamicKeys.has(key))
        .map((key) => ({
          location_key: key,
          display_name: asText(asRow(candidateScenes.find((item) =>
            normalizeEncounterSceneKey(asRow(item).location_key) === key
          )).display_name) || key,
          is_dynamic: true,
        })),
    ];
    const parsed = parseEncounterScheduleBatchOutput(
      JSON.stringify({ characters: [rawCharacter], scenes: candidateScenes }),
      [source],
      candidateCatalog,
    );
    if (!parsed.ok || parsed.characters.length !== 1) {
      failedCharacterIds.add(source.character_id);
      validationErrors.push(...parsed.errors.slice(0, 20).map((error) => source.character_id + ":" + error));
      continue;
    }

    const protectedValues = prompt.protectedContextByCharacter[source.character_id] || [];
    if (findPrivateContextLeak(JSON.stringify(parsed.characters[0]), protectedValues, [])) {
      failedCharacterIds.add(source.character_id);
      validationErrors.push(source.character_id + "_private_context_output_blocked");
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
        publishedCharacterCount += 1;
      } else if (job?.status === "cancelled") {
        committedCharacterIds.add(item.sourceId);
        skippedCharacterCount += 1;
      } else {
        failedCharacterIds.add(item.sourceId);
      }
      console.warn("Encounter schedule character publish failed:", item.sourceId, publishError.message);
      continue;
    }
    const publishRow = Array.isArray(published) ? published[0] : published;
    if (!publishRow || !["partial", "completed"].includes(asText(publishRow.status))) {
      failedCharacterIds.add(item.sourceId);
      continue;
    }
    committedCharacterIds.add(item.sourceId);
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
  if (remaining > 0 || ambiguousPublishFailure) {
    const failed = await failBatch(
      admin,
      batchId,
      leaseToken,
      "schedule_partial_character_failure",
      true,
      ambiguousPublishFailure,
    );
    if (!failed) {
      await recordBatchUsage(admin, batchId, providerResponse, "failed", "schedule_partial_failure_unconfirmed");
      return json({ status: "batch_failure_unconfirmed", error: "schedule_partial_character_failure" }, 503);
    }
  }

  const partial = remaining > 0 || ambiguousPublishFailure;
  await recordBatchUsage(admin, batchId, providerResponse, partial ? "partial" : "completed",
    partial ? "schedule_partial_character_failure" : null);
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
