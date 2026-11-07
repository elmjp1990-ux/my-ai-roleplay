import { withSupabase } from "npm:@supabase/server@1";
import {
  buildCharacterProfileMessages,
  CHARACTER_PROFILE_MODEL,
  validateCharacterAiProfile,
  type CharacterProfileSourcePayload,
} from "../_shared/character-profile-organization.ts";

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const MAX_BATCH = 1;
const REQUEST_TIMEOUT_MS = 90_000;

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

async function generateProfile(
  item: WorkItem,
  apiKey: string,
): Promise<GeneratedProfile> {
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
          messages: buildCharacterProfileMessages(item.source_payload),
          response_format: { type: "json_object" },
          temperature: 0.2,
          // Match POYOZZ's selected OpenRouter privacy policy: no fallback route
          // and no provider-side data collection for author-only character sources.
          provider: {
            only: ["deepinfra"],
            allow_fallbacks: false,
            data_collection: "deny",
          },
        }),
      });
    } catch (error) {
      // A timeout/network failure has an ambiguous billing outcome. Do not
      // automatically retry it; require an explicit author save to retry later.
      const code = error instanceof Error && error.name === "AbortError"
        ? "provider_request_timeout"
        : "provider_outcome_unknown";
      throw new ProfileGenerationError(code, {
        model: CHARACTER_PROFILE_MODEL,
        provider: "deepinfra",
        requestId: null,
        usage: {},
      });
    }
    if (!response.ok) {
      if (response.status >= 500) {
        throw new ProfileGenerationError("provider_outcome_unknown", {
          model: CHARACTER_PROFILE_MODEL,
          provider: "deepinfra",
          requestId: response.headers.get("x-request-id"),
          usage: {},
        });
      }
      throw new Error("openrouter_http_" + response.status);
    }
    let result: any;
    try {
      result = await response.json();
    } catch {
      throw new ProfileGenerationError("provider_outcome_unknown", {
        model: CHARACTER_PROFILE_MODEL,
        provider: "deepinfra",
        requestId: response.headers.get("x-request-id"),
        usage: {},
      });
    }
    const usage = result?.usage && typeof result.usage === "object" && !Array.isArray(result.usage)
      ? result.usage as Record<string, unknown>
      : {};
    const responseProvider = typeof result?.provider === "string" ? result.provider : "deepinfra";
    const requestIdValue = response.headers.get("x-request-id") ||
      (typeof result?.id === "string" ? result.id : null);
    const metadata: ProfileUsageMetadata = {
      model: CHARACTER_PROFILE_MODEL,
      provider: responseProvider.slice(0, 100),
      requestId: typeof requestIdValue === "string" &&
        /^[A-Za-z0-9._:-]{1,128}$/.test(requestIdValue) ? requestIdValue : null,
      usage,
    };
    const content = result?.choices?.[0]?.message?.content;
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
  fetch: withSupabase({ auth: "secret:default" }, async (request, ctx) => {
    if (request.method !== "POST") {
      return Response.json({ error: "method_not_allowed" }, { status: 405 });
    }
    const supabase = ctx.supabaseAdmin;
    if (!supabase) {
      return Response.json({ error: "worker_admin_context_missing" }, { status: 500 });
    }
    const apiKey = Deno.env.get("OPENROUTER_API_KEY");
    if (!apiKey) {
      return Response.json({ error: "profile_worker_provider_key_missing" }, { status: 503 });
    }

    const { data, error } = await supabase.rpc("claim_character_profile_organization_jobs", {
      p_limit: MAX_BATCH,
    });
    if (error) {
      return Response.json({
        error: "profile_job_claim_failed",
        code: safeCode(error, "claim_failed"),
      }, { status: 500 });
    }

    const items = (Array.isArray(data) ? data : []).slice(0, MAX_BATCH) as WorkItem[];
    const summary = { claimed: items.length, completed: 0, retried: 0, failed: 0, stale: 0 };

    for (const item of items) {
      let usageRecorded = false;
      try {
        if (!item.character_id || !item.author_id || !item.source_hash ||
          !item.lease_token || !Number.isSafeInteger(item.lease_generation) ||
          !item.source_payload || typeof item.source_payload !== "object") {
          throw new Error("claimed_job_invalid");
        }
        const generated = await generateProfile(item, apiKey);
        await recordProfileUsage(supabase, item, generated, "generated");
        usageRecorded = true;
        const { data: completion, error: completionError } = await supabase.rpc(
          "complete_character_profile_organization_job",
          {
            p_character_id: item.character_id,
            p_lease_token: item.lease_token,
            p_lease_generation: item.lease_generation,
            p_source_hash: item.source_hash,
            p_profile: generated.profile,
          },
        );
        if (completionError) throw completionError;
        const status = String(completion ?? "");
        if (status === "completed") summary.completed++;
        else if (status === "stale_source") summary.stale++;
        else summary.stale++;
      } catch (error) {
        const code = safeCode(error, "profile_generation_failed");
        if (!usageRecorded && item.character_id && item.author_id && item.source_hash) {
          const failedUsage = error instanceof ProfileGenerationError ? error.metadata : null;
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

    return Response.json({ ok: summary.failed === 0, summary }, {
      status: summary.failed === 0 ? 200 : 207,
    });
  }),
};
