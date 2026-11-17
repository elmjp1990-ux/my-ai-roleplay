import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { parseTaiwanCalendarRows } from "../_shared/taiwan-calendar.mjs";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
const DATASET_URL = "https://data.ntpc.gov.tw/api/datasets/308dcd75-6434-45bc-a95f-584da4fed251/json";
const PAGE_SIZE = 1000;

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: CORS });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")?.trim();
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim();
  if (!url || !serviceKey) return json({ error: "server_not_configured" }, 503);
  if (request.headers.get("Authorization") !== "Bearer " + serviceKey) {
    return json({ error: "service_role_required" }, 401);
  }

  let body: Record<string, unknown> = {};
  try {
    const parsed = await request.json();
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) body = parsed;
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  if (body.mode && body.mode !== "scheduled") return json({ error: "unsupported_mode" }, 400);

  try {
    const allRows: ReturnType<typeof parseTaiwanCalendarRows> = [];
    let page = 0;
    const seenPages = new Set<string>();
    for (let pageIndex = 0; pageIndex < 10; pageIndex++) {
      const datasetUrl = new URL(DATASET_URL);
      datasetUrl.searchParams.set("page", String(page));
      datasetUrl.searchParams.set("size", String(PAGE_SIZE));
      const response = await fetch(datasetUrl, {
        headers: { Accept: "application/json" },
        signal: AbortSignal.timeout(15000),
      });
      if (!response.ok) throw new Error("calendar_http_" + response.status);
      const payload = await response.json();
      const parsedRows = parseTaiwanCalendarRows(payload);
      if (!parsedRows.length) {
        if (page === 0) throw new Error("calendar_dataset_empty_or_schema_changed");
        break;
      }
      const pageSignature = parsedRows[0].calendar_date + ":" + parsedRows[parsedRows.length - 1].calendar_date;
      if (seenPages.has(pageSignature)) break;
      seenPages.add(pageSignature);
      allRows.push(...parsedRows);
      if (parsedRows.length < PAGE_SIZE) break;
      page += 1;
    }

    const deduped = [...new Map(allRows.map((row) => [row.calendar_date, row])).values()];
    if (!deduped.length) return json({ error: "calendar_dataset_has_no_valid_dates" }, 502);
    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    let upserted = 0;
    for (let index = 0; index < deduped.length; index += 500) {
      const batch = deduped.slice(index, index + 500).map((row) => ({
        ...row,
        updated_at: new Date().toISOString(),
      }));
      const { error } = await admin.from("taiwan_calendar_days").upsert(batch, { onConflict: "calendar_date" });
      if (error) return json({ error: "calendar_cache_write_failed", detail: error.message.slice(0, 120) }, 503);
      upserted += batch.length;
    }

    return json({
      status: "updated",
      source: "data.gov.tw:123662 / data.ntpc.gov.tw:308dcd75-6434-45bc-a95f-584da4fed251",
      upserted_count: upserted,
      date_from: deduped[0].calendar_date,
      date_to: deduped[deduped.length - 1].calendar_date,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown";
    return json({ error: "calendar_sync_failed", detail: message.slice(0, 120) }, 502);
  }
});
