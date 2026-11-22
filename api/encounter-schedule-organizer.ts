import { createClient } from "@supabase/supabase-js";
import { handleEncounterScheduleOrganizer } from "../supabase/functions/_shared/encounter-schedule-organizer-handler.ts";

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
  // test action. Status, repair, and scheduled dispatch remain on Supabase.
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
      return process.env[name];
    },
  };

  try {
    const response = await handleEncounterScheduleOrganizer(
      webRequest,
      runtimeEnv,
      createClient,
      270_000,
    );
    response.headers.forEach((value, name) => res.setHeader(name, value));
    res.setHeader("Cache-Control", "no-store");
    res.status(response.status).send(await response.text());
  } catch (error) {
    console.error("Encounter schedule Vercel handler failed:", error);
    res.status(500).json({ error: "schedule_handler_failed" });
  }
}
