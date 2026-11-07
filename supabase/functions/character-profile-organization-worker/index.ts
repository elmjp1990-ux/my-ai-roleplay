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
  const raw = value && typeof value === "object" && "code" in value
    ? (value as { code?: unknown }).code
    : value && typeof value === "object" && "name" in value
    ? (value as { name?: unknown }).name
    : value;
  return typeof raw === "string"
    ? raw.replace(/[^a-zA-Z0-9:_-]/g, "").slice(0, 80) || fallback
    : fallback;
};

async function generateProfile(
  item: WorkItem,
  apiKey: string,
): Promise<Record<string, unknown>> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const response = await fetch(OPENROUTER_URL, {
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
      }),
    });
    if (!response.ok) throw new Error("openrouter_http_" + response.status);
    const result = await response.json();
    const content = result?.choices?.[0]?.message?.content;
    if (typeof content !== "string" || !content.trim()) {
      throw new Error("model_content_missing");
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(content);
    } catch {
      throw new Error("model_json_invalid");
    }
    const validation = validateCharacterAiProfile(parsed, item.source_payload);
    if (!validation.ok) throw new Error("profile_schema_invalid_" + validation.errors[0]);
    return parsed as Record<string, unknown>;
  } finally {
    clearTimeout(timeout);
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
      try {
        if (!item.character_id || !item.author_id || !item.source_hash ||
          !item.lease_token || !Number.isSafeInteger(item.lease_generation) ||
          !item.source_payload || typeof item.source_payload !== "object") {
          throw new Error("claimed_job_invalid");
        }
        const profile = await generateProfile(item, apiKey);
        const { data: completion, error: completionError } = await supabase.rpc(
          "complete_character_profile_organization_job",
          {
            p_character_id: item.character_id,
            p_lease_token: item.lease_token,
            p_lease_generation: item.lease_generation,
            p_source_hash: item.source_hash,
            p_profile: profile,
          },
        );
        if (completionError) throw completionError;
        const status = String(completion ?? "");
        if (status === "completed") summary.completed++;
        else if (status === "stale_source") summary.stale++;
        else summary.stale++;
      } catch (error) {
        const code = safeCode(error, "profile_generation_failed");
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
