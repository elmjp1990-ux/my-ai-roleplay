import { withSupabase } from "npm:@supabase/server@1";
import {
  APPROVED_OPENROUTER_PROVIDERS,
  buildOpenRouterProviderOptions,
} from "../_shared/openrouter-provider-policy.ts";
import {
  buildCharacterProfileMessages,
  CHARACTER_PROFILE_MODEL,
  validateCharacterAiProfile,
  validateCharacterProfileSourcePayload,
  type CharacterProfileSourcePayload,
} from "../_shared/character-profile-organization.ts";
import { recordAiGenerationDiagnostic } from "../_shared/ai-generation-diagnostics.ts";

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const MAX_BATCH = 1;
const REQUEST_TIMEOUT_MS = 90_000;
const MAX_PROVIDER_RESPONSE_BYTES = 64 * 1024;

type WorkItem = {
  character_id: string;
  author_id: string;
  source_hash: string;
  lease_token: string;
  lease_generation: number;
  lease_expires_at: string;
  source_payload: CharacterProfileSourcePayload;
};

const safeCode = (value: unknown, fallback: string): string => {
  if (value && typeof value === "object" && "message" in value) {
    const message = (value as { message?: unknown }).message;
    if (typeof message === "string" && /^[a-zA-Z0-9:_-]{1,80}$/.test(message)) return message;
  }
  const raw = value && typeof value === "object" && "code" in value
    ? (value as { code?: unknown }).code
    : value && typeof value === "object" && "name" in value
    ? (value as { name?: unknown }).name
    : value;
  return typeof raw === "string"
    ? raw.replace(/[^a-zA-Z0-9:_-]/g, "").slice(0, 80) || fallback
    : fallback;
};

type ProfileUsageMetadata = {
  model: string;
  provider: string;
  requestId: string | null;
  usage: Record<string, unknown>;
  rawOutputText?: string | null;
  rawResponseBody?: string | null;
  refusalText?: string | null;
  httpStatus?: number | null;
  finishReason?: string | null;
  responseContentType?: string | null;
  responseBodyLength?: number | null;
  responseParsed?: boolean | null;
};

type GeneratedProfile = ProfileUsageMetadata & {
  profile: Record<string, unknown>;
};

class ProfileGenerationError extends Error {
  metadata: ProfileUsageMetadata;
  constructor(code: string, metadata: ProfileUsageMetadata) {
    super(code);
    this.name = "ProfileGenerationError";
    this.metadata = metadata;
  }
}

async function readBoundedResponseText(response: Response): Promise<string> {
  const declaredLength = Number(response.headers.get("content-length") || 0);
  if (declaredLength > MAX_PROVIDER_RESPONSE_BYTES) {
    await response.body?.cancel();
    throw new Error("provider_response_too_large");
  }
  if (!response.body) return "";
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let total = 0;
  let text = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_PROVIDER_RESPONSE_BYTES) {
      await reader.cancel();
      throw new Error("provider_response_too_large");
    }
    text += decoder.decode(value, { stream: true });
  }
  return text + decoder.decode();
}

async function completeProfileWithRetry(
  supabase: any,
  item: WorkItem,
  profile: Record<string, unknown>,
): Promise<string> {
  let lastError: unknown = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const { data, error } = await supabase.rpc(
        "complete_character_profile_organization_job",
        {
          p_character_id: item.character_id,
          p_lease_token: item.lease_token,
          p_lease_generation: item.lease_generation,
          p_source_hash: item.source_hash,
          p_profile: profile,
        },
      );
      if (error) throw error;
      return String(data ?? "");
    } catch (error) {
      lastError = error;
      if (attempt < 2) await new Promise((resolve) => setTimeout(resolve, 300 * (attempt + 1)));
    }
  }
  console.error("character_profile_persistence_retry_exhausted", {
    code: safeCode(lastError, "profile_persistence_failed"),
  });
  throw new Error("profile_persistence_failed_after_generation");
}

async function generateProfile(
  item: WorkItem,
  apiKey: string,
): Promise<GeneratedProfile> {
  const messages = buildCharacterProfileMessages(item.source_payload);
  for (const provider of APPROVED_OPENROUTER_PROVIDERS) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    try {
      let response: Response;
      try {
        response = await fetch(OPENROUTER_URL, {
          method: "POST",
          signal: controller.signal,
          headers: {
            Authorization: `Bearer ${apiKey}`,
            "Content-Type": "application/json",
            "HTTP-Referer": "https://poyozz.com",
            "X-Title": "POYOZZ Character Profile Organization",
          },
          body: JSON.stringify({
            model: CHARACTER_PROFILE_MODEL,
            messages,
            response_format: { type: "json_object" },
            temperature: 0.2,
            // Pin each attempt to one approved non-training provider. The
            // application controls failover; OpenRouter fallback stays off.
            provider: buildOpenRouterProviderOptions(provider),
          }),
        });
      } catch (error) {
        // A network/timeout failure has an ambiguous billing outcome. Do not
        // send the same private character source to another provider.
        const code = error instanceof Error && error.name === "AbortError"
          ? "provider_request_timeout"
          : "provider_outcome_unknown";
        throw new ProfileGenerationError(code, {
          model: CHARACTER_PROFILE_MODEL,
          provider,
          requestId: null,
          usage: {},
        });
      }

      // A rate-limit response is an explicit non-generation failure and may
      // safely use the next approved provider once. Generic 5xx responses are
      // treated as ambiguous and are not retried.
      if (response.status === 429 && provider === APPROVED_OPENROUTER_PROVIDERS[0]) {
        await response.body?.cancel();
        continue;
      }
      if (!response.ok) {
        await response.body?.cancel();
        if (response.status >= 500) {
          throw new ProfileGenerationError("provider_outcome_unknown", {
            model: CHARACTER_PROFILE_MODEL,
            provider,
            requestId: response.headers.get("x-request-id"),
            usage: {},
          });
        }
        throw new ProfileGenerationError("openrouter_http_" + response.status, {
          model: CHARACTER_PROFILE_MODEL,
          provider,
          requestId: response.headers.get("x-request-id"),
          usage: {},
        });
      }

      let result: any;
      let responseText: string;
      try {
        responseText = await readBoundedResponseText(response);
        result = JSON.parse(responseText);
      } catch (error) {
        if (error instanceof Error && error.message === "provider_response_too_large") {
          throw new ProfileGenerationError("provider_response_too_large", {
            model: CHARACTER_PROFILE_MODEL,
            provider,
            requestId: response.headers.get("x-request-id"),
            usage: {},
          });
        }
        throw new ProfileGenerationError("provider_outcome_unknown", {
          model: CHARACTER_PROFILE_MODEL,
          provider,
          requestId: response.headers.get("x-request-id"),
          usage: {},
        });
      }

      const errorCode = typeof result?.error?.code === "string"
        ? result.error.code.toLowerCase().replace(/[\s-]+/g, "_")
        : "";
      const isExplicitOverload = [
        "engine_overloaded",
        "upstream_overloaded",
        "upstream_unavailable",
        "provider_overloaded",
        "capacity_exceeded",
        "rate_limit",
        "temporarily_unavailable",
        "upstream_busy",
      ].some((code) => errorCode.includes(code));
      if (isExplicitOverload && provider === APPROVED_OPENROUTER_PROVIDERS[0]) {
        continue;
      }
      if (result?.error != null) {
        throw new ProfileGenerationError("provider_" + safeCode(result.error, "generation_failed"), {
          model: CHARACTER_PROFILE_MODEL,
          provider,
          requestId: response.headers.get("x-request-id") ||
            (typeof result?.id === "string" ? result.id : null),
          usage: result?.usage && typeof result.usage === "object" && !Array.isArray(result.usage)
            ? result.usage as Record<string, unknown>
            : {},
          rawOutputText: typeof result?.choices?.[0]?.message?.content === "string" ? result.choices[0].message.content : null,
          rawResponseBody: responseText,
          refusalText: typeof result?.choices?.[0]?.message?.refusal === "string" ? result.choices[0].message.refusal : null,
          httpStatus: response.status,
          finishReason: typeof result?.choices?.[0]?.finish_reason === "string" ? result.choices[0].finish_reason : null,
          responseContentType: response.headers.get("content-type") || "",
          responseBodyLength: responseText.length,
          responseParsed: true,
        });
      }

      const usage = result?.usage && typeof result.usage === "object" && !Array.isArray(result.usage)
        ? result.usage as Record<string, unknown>
        : {};
      const responseProvider = typeof result?.provider === "string" ? result.provider : provider;
      const requestIdValue = response.headers.get("x-request-id") ||
        (typeof result?.id === "string" ? result.id : null);
      const content = result?.choices?.[0]?.message?.content;
      const metadata: ProfileUsageMetadata = {
        model: CHARACTER_PROFILE_MODEL,
        provider: responseProvider.slice(0, 100),
        requestId: typeof requestIdValue === "string" &&
          /^[A-Za-z0-9._:-]{1,128}$/.test(requestIdValue) ? requestIdValue : null,
        usage,
        rawOutputText: typeof content === "string" ? content : null,
        rawResponseBody: responseText,
        refusalText: typeof result?.choices?.[0]?.message?.refusal === "string" ? result.choices[0].message.refusal : null,
        httpStatus: response.status,
        finishReason: typeof result?.choices?.[0]?.finish_reason === "string" ? result.choices[0].finish_reason : null,
        responseContentType: response.headers.get("content-type") || "",
        responseBodyLength: responseText.length,
        responseParsed: true,
      };
      if (typeof content !== "string" || !content.trim()) {
        throw new ProfileGenerationError("model_content_missing", metadata);
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(content);
      } catch {
        throw new ProfileGenerationError("model_json_invalid", metadata);
      }
      const validation = validateCharacterAiProfile(parsed, item.source_payload);
      if (!validation.ok) {
        throw new ProfileGenerationError("profile_schema_invalid_" + validation.errors[0], metadata);
      }
      return { ...metadata, profile: parsed as Record<string, unknown> };
    } finally {
      clearTimeout(timeout);
    }
  }
  throw new ProfileGenerationError("provider_fallback_exhausted", {
    model: CHARACTER_PROFILE_MODEL,
    provider: APPROVED_OPENROUTER_PROVIDERS[APPROVED_OPENROUTER_PROVIDERS.length - 1],
    requestId: null,
    usage: {},
  });
}
const safeUsageInteger = (value: unknown): number | null => {
  if (value === null || value === undefined || value === "") return null;
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? Math.min(2_147_483_647, Math.trunc(parsed)) : null;
};

const safeUsageCost = (usage: Record<string, unknown>): number | null => {
  const raw = usage.cost ?? usage.total_cost;
  if (raw === null || raw === undefined || raw === "") return null;
  const parsed = typeof raw === "number" ? raw : Number(raw);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
};

async function recordProfileUsage(
  supabase: any,
  item: WorkItem,
  generated: ProfileUsageMetadata | null,
  status: "generated" | "failed",
  errorCode: string | null = null,
): Promise<void> {
  const usage = generated?.usage ?? {};
  try {
    const { error } = await supabase.from("character_profile_organization_usage").insert({
      character_id: item.character_id,
      author_id: item.author_id,
      source_hash: item.source_hash,
      model: generated?.model || CHARACTER_PROFILE_MODEL,
      provider: generated?.provider || "deepinfra",
      gateway_request_id: generated?.requestId || null,
      prompt_tokens: safeUsageInteger(usage.prompt_tokens),
      completion_tokens: safeUsageInteger(usage.completion_tokens),
      total_tokens: safeUsageInteger(usage.total_tokens),
      cost_usd: safeUsageCost(usage),
      status,
      error_code: errorCode,
      processed_at: new Date().toISOString(),
    });
    if (error) {
      console.error("character_profile_usage_write_failed", {
        code: safeCode(error, "usage_write_failed"),
      });
    }
  } catch (error) {
    // Usage-ledger outages must never strand a valid profile job.
    console.error("character_profile_usage_write_failed", {
      code: safeCode(error, "usage_write_failed"),
    });
  }
}

export default {
  fetch: withSupabase({ auth: ["user", "secret:default"] }, async (request, ctx) => {
    if (request.method !== "POST") {
      return Response.json({ error: "method_not_allowed" }, { status: 405 });
    }
    const supabase = ctx.supabaseAdmin;
    if (!supabase) {
      return Response.json({ error: "worker_admin_context_missing" }, { status: 500 });
    }

    let body: Record<string, unknown> = {};
    try {
      const parsed = await request.json();
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) body = parsed;
    } catch {
      return Response.json({ error: "invalid_json" }, { status: 400 });
    }
    const mode = typeof body.mode === "string" ? body.mode : "scheduled";
    const isManualUser = ctx.authMode === "user";
    const authorId = isManualUser
      ? String((ctx.userClaims as any)?.id || (ctx.userClaims as any)?.sub || "")
      : "";

    if (isManualUser) {
      if (Deno.env.get("ENCOUNTER_SCHEDULE_TEST_MODE") !== "true" || !authorId) {
        return Response.json({ error: "manual_profile_trigger_disabled" }, { status: 403 });
      }
      if (mode === "status") {
        const { data: pendingJobs, error: nextError } = await supabase
          .from("encounter_schedule_generation_jobs")
          .select("character_id")
          .eq("author_id", authorId)
          .eq("status", "pending")
          .order("queued_at", { ascending: true })
          .order("character_id", { ascending: true })
          .limit(50);
        if (nextError) return Response.json({ error: "profile_status_unavailable" }, { status: 503 });
        const pendingIds = (pendingJobs || []).map((job: any) => job.character_id).filter(Boolean);
        if (!pendingIds.length) {
          return Response.json({ status: "no_pending_schedule_jobs", profile_ready: false });
        }
        const { data: eligibleCharacters, error: eligibleError } = await supabase
          .from("characters")
          .select("id,name")
          .in("id", pendingIds)
          .eq("author_id", authorId)
          .eq("visibility", "public")
          .eq("review_status", "approved")
          .eq("rights_confirmed", true)
          .is("deleted_at", null);
        if (eligibleError) return Response.json({ error: "profile_status_unavailable" }, { status: 503 });
        const eligibleById = new Map((eligibleCharacters || []).map((character: any) => [character.id, character]));
        const nextJob = (pendingJobs || []).find((job: any) => eligibleById.has(job.character_id));
        if (!nextJob?.character_id) {
          return Response.json({ status: "no_pending_schedule_jobs", profile_ready: false });
        }
        const nextCharacter = eligibleById.get(nextJob.character_id);
        const [profileResult, jobResult] = await Promise.all([
          supabase.rpc("get_character_ai_profile_for_chat", {
            p_character_id: nextJob.character_id,
            p_author_id: authorId,
          }),
          supabase.from("character_profile_organization_jobs")
            .select("status,last_error_code,updated_at")
            .eq("character_id", nextJob.character_id).eq("author_id", authorId).maybeSingle(),
        ]);
        if (profileResult.error || jobResult.error) {
          return Response.json({ error: "profile_status_unavailable" }, { status: 503 });
        }
        const profile = profileResult.data && typeof profileResult.data === "object" &&
          !Array.isArray(profileResult.data) ? profileResult.data as Record<string, unknown> : null;
        const lifeContext = profile?.life_context && typeof profile.life_context === "object" &&
          !Array.isArray(profile.life_context) ? profile.life_context as Record<string, unknown> : null;
        const lifeContextKeys = [
          "work_environment", "residence_environment", "daily_routines", "interests_and_leisure",
          "social_circles", "recurring_places", "environmental_constraints",
        ];
        const profileReady = !!profile && profile.schema_version === "1.1" && !!lifeContext &&
          Object.keys(lifeContext).length === lifeContextKeys.length &&
          lifeContextKeys.every((key) => Object.prototype.hasOwnProperty.call(lifeContext, key));
        return Response.json({
          status: "available",
          next_character_id: nextJob.character_id,
          next_character_name: nextCharacter?.name || "角色",
          profile_ready: profileReady,
          profile_job_status: jobResult.data?.status || "missing",
          profile_error_code: jobResult.data?.last_error_code || null,
          profile_updated_at: jobResult.data?.updated_at || null,
          profile_preview: profileReady ? profile : null,
          model: CHARACTER_PROFILE_MODEL,
        });
      }
      if (mode !== "manual") {
        return Response.json({ error: "manual_profile_mode_only" }, { status: 403 });
      }
    } else if (mode !== "scheduled") {
      return Response.json({ error: "scheduled_profile_worker_only" }, { status: 403 });
    }

    const apiKey = Deno.env.get("OPENROUTER_API_KEY");
    if (!apiKey) {
      return Response.json({ error: "profile_worker_provider_key_missing" }, { status: 503 });
    }

    let items: WorkItem[] = [];
    let manualCharacterName = "";
    if (isManualUser) {
      const { data: claim, error } = await supabase.rpc("claim_next_encounter_character_profile_job", {
        p_author_id: authorId,
      });
      if (error) {
        return Response.json({
          error: "profile_job_claim_failed",
          code: safeCode(error, "claim_failed"),
        }, { status: 500 });
      }
      const claimRow = claim && typeof claim === "object" ? claim as Record<string, unknown> : {};
      const claimStatus = String(claimRow.status || "not_ready");
      if (claimStatus === "already_completed") {
        return Response.json({
          status: "already_completed",
          character_id: claimRow.character_id || null,
          character_name: claimRow.character_name || "角色",
          profile_preview: claimRow.profile || null,
          model: CHARACTER_PROFILE_MODEL,
          ai_called: false,
        });
      }
      if (claimStatus !== "claimed") {
        return Response.json({
          status: claimStatus,
          character_id: claimRow.character_id || null,
          character_name: claimRow.character_name || null,
          error_code: claimRow.error_code || null,
          job_status: claimRow.job_status || null,
          available_at: claimRow.available_at || null,
          ai_called: false,
        }, { status: claimStatus === "no_pending_schedule_jobs" ? 200 : 409 });
      }
      const item = claimRow.item && typeof claimRow.item === "object"
        ? claimRow.item as WorkItem : null;
      if (!item) return Response.json({ error: "claimed_job_invalid" }, { status: 503 });
      items = [item];
      manualCharacterName = String(claimRow.character_name || "角色");
    } else {
      const { data, error } = await supabase.rpc("claim_character_profile_organization_jobs", {
        p_limit: MAX_BATCH,
      });
      if (error) {
        return Response.json({
          error: "profile_job_claim_failed",
          code: safeCode(error, "claim_failed"),
        }, { status: 500 });
      }
      items = (Array.isArray(data) ? data : []).slice(0, MAX_BATCH) as WorkItem[];
    }

    const summary = { claimed: items.length, completed: 0, retried: 0, failed: 0, stale: 0 };
    let manualProfilePreview: Record<string, unknown> | null = null;
    let manualFailureCode: string | null = null;

    for (const item of items) {
      let usageRecorded = false;
      try {
        if (!item.character_id || !item.author_id || !item.source_hash ||
          !item.lease_token || !Number.isSafeInteger(item.lease_generation) ||
          !item.source_payload || typeof item.source_payload !== "object") {
          throw new Error("claimed_job_invalid");
        }
        if (isManualUser && item.author_id !== authorId) {
          throw new Error("manual_profile_author_mismatch");
        }
        const sourceValidation = validateCharacterProfileSourcePayload(item.source_payload);
        if (!sourceValidation.ok) throw new Error(sourceValidation.errors[0] || "source_payload_invalid");
        const generated = await generateProfile(item, apiKey);
        await recordAiGenerationDiagnostic(supabase, {
          generationType: "character_profile", userId: item.author_id, characterId: item.character_id,
          sourceRef: item.source_hash, model: generated.model, provider: generated.provider,
          requestId: generated.requestId, httpStatus: generated.httpStatus, finishReason: generated.finishReason,
          responseContentType: generated.responseContentType, responseBodyLength: generated.responseBodyLength,
          rawResponseBody: generated.rawResponseBody, responseParsed: generated.responseParsed, rawOutputText: generated.rawOutputText || JSON.stringify(generated.profile),
          refusalText: generated.refusalText, usage: generated.usage, status: "completed",
        });
        await recordProfileUsage(supabase, item, generated, "generated");
        usageRecorded = true;
        // The provider has already completed and may have billed this request.
        // Retry persistence with the same in-memory profile; never regenerate here.
        const status = await completeProfileWithRetry(supabase, item, generated.profile);
        if (status === "completed") {
          summary.completed++;
          if (isManualUser) manualProfilePreview = generated.profile;
        } else if (status === "stale_source") summary.stale++;
        else summary.stale++;
      } catch (error) {
        const code = safeCode(error, "profile_generation_failed");
        if (isManualUser) manualFailureCode = code;
        if (!usageRecorded && item.character_id && item.author_id && item.source_hash) {
          const failedUsage = error instanceof ProfileGenerationError ? error.metadata : null;
          if (failedUsage) await recordAiGenerationDiagnostic(supabase, {
            generationType: "character_profile", userId: item.author_id, characterId: item.character_id,
            sourceRef: item.source_hash, model: failedUsage.model, provider: failedUsage.provider,
            requestId: failedUsage.requestId, httpStatus: failedUsage.httpStatus,
            finishReason: failedUsage.finishReason, responseContentType: failedUsage.responseContentType,
            responseBodyLength: failedUsage.responseBodyLength, rawResponseBody: failedUsage.rawResponseBody,
            responseParsed: failedUsage.responseParsed, rawOutputText: failedUsage.rawOutputText, refusalText: failedUsage.refusalText,
            usage: failedUsage.usage, status: "failed", failureStage: "profile_output_validation", failureCode: code,
            validationErrors: code.startsWith("profile_schema_invalid_") ? [code] : code === "model_json_invalid" ? ["model_json_invalid"] : [],
          });
          await recordProfileUsage(supabase, item, failedUsage, "failed", code);
          usageRecorded = true;
        }
        const { data: failureStatus, error: failureError } = await supabase.rpc(
          "fail_character_profile_organization_job",
          {
            p_character_id: item.character_id,
            p_lease_token: item.lease_token,
            p_lease_generation: item.lease_generation,
            p_error_code: code,
          },
        );
        if (failureError) {
          summary.failed++;
          console.error("character_profile_failure_reporting_failed", {
            code: safeCode(failureError, "failure_rpc_failed"),
          });
        } else if (failureStatus === "retry_scheduled") {
          summary.retried++;
        } else {
          summary.failed++;
        }
      }
    }

    if (isManualUser) {
      const completed = summary.completed === 1 && !!manualProfilePreview;
      return Response.json({
        status: completed ? "completed" : summary.failed ? "failed" : summary.stale ? "stale_source" : "not_completed",
        ok: completed,
        character_id: items[0]?.character_id || null,
        character_name: manualCharacterName || "角色",
        model: CHARACTER_PROFILE_MODEL,
        profile_preview: manualProfilePreview,
        error_code: manualFailureCode,
        ai_called: items.length === 1,
        summary,
      }, { status: summary.failed === 0 ? 200 : 207 });
    }

    return Response.json({ ok: summary.failed === 0, summary }, {
      status: summary.failed === 0 ? 200 : 207,
    });
  }),
};
