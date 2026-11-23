import { createClient } from "@supabase/supabase-js";
import { handleEncounterScheduleOrganizer } from "./_generated/encounter-schedule-organizer-handler.mjs";

const runtimeProcess = (globalThis as unknown as {
  process: { env: Record<string, string | undefined> };
}).process;

function readBody(request: any): Record<string, unknown> {
  if (request?.body && typeof request.body === "object" && !Array.isArray(request.body)) {
    return request.body as Record<string, unknown>;
  }
  if (typeof request?.body === "string") {
    try {
      const parsed = JSON.parse(request.body);
      return parsed && typeof parsed === "object" && !Array.isArray(parsed)
        ? parsed as Record<string, unknown>
        : {};
    } catch {
      return {};
    }
  }
  return {};
}

export default async function handler(req: any, res: any) {
  const method = String(req?.method || "GET").toUpperCase();
  if (method === "OPTIONS") {
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Headers", "authorization, x-client-info, apikey, content-type");
    res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
    res.status(204).end();
    return;
  }
  if (method !== "POST") {
    res.status(405).json({ error: "method_not_allowed" });
    return;
  }

  // This Vercel endpoint is deliberately limited to the authenticated manual
  // test action. Never allow it to run from a production deployment.
  if (runtimeProcess.env.VERCEL_ENV === "production") {
    res.status(403).json({ error: "manual_schedule_trigger_disabled" });
    return;
  }
  // Status, repair, and scheduled dispatch remain on Supabase.
  const body = readBody(req);
  if (body.mode !== "manual") {
    res.status(400).json({ error: "unsupported_mode" });
    return;
  }

  const headers = new Headers();
  for (const [name, value] of Object.entries(req?.headers || {})) {
    if (typeof value === "string") headers.set(name, value);
    else if (Array.isArray(value)) headers.set(name, value.join(", "));
  }
  const host = headers.get("host") || "localhost";
  const requestUrl = new URL(req?.url || "/api/encounter-schedule-organizer", `https://${host}`);
  const requestBody = typeof req?.body === "string"
    ? req.body
    : JSON.stringify(req?.body ?? {});
  const webRequest = new Request(requestUrl, {
    method,
    headers,
    body: requestBody,
  });

  const runtimeEnv = {
    get(name: string): string | undefined {
      return runtimeProcess.env[name];
    },
  };

  // Keep the browser connection active while the provider is working. Leading
  // JSON whitespace is valid, so the client can still call response.json().
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "authorization, x-client-info, apikey, content-type");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.statusCode = 200;
  res.flushHeaders?.();
  const heartbeat = setInterval(() => {
    if (!res.destroyed && !res.writableEnded) res.write(" ");
  }, 15_000);

  try {
    const response = await handleEncounterScheduleOrganizer(
      webRequest,
      runtimeEnv,
      createClient,
      270_000,
    );
    const bodyText = await response.text();
    if (response.status === 200) {
      res.end(bodyText);
    } else {
      try {
        const payload = JSON.parse(bodyText);
        if (payload && typeof payload === "object" && !Array.isArray(payload)) {
          payload.http_status = response.status;
        }
        res.end(JSON.stringify(payload));
      } catch {
        res.end(bodyText);
      }
    }
  } catch (error) {
    console.error("Encounter schedule Vercel handler failed:", error);
    res.end(JSON.stringify({ error: "schedule_handler_failed", http_status: 500 }));
  } finally {
    clearInterval(heartbeat);
  }
}
