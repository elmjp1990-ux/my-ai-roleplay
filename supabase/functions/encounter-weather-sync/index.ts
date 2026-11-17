import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  isRainWeatherText,
  parseCwaRainfallObservation,
  parseCwaWeatherObservation,
} from "../_shared/encounter-weather.mjs";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: CORS });
}

async function fetchCwaDataset(datasetId: string, apiKey: string) {
  const url = new URL("https://opendata.cwa.gov.tw/api/v1/rest/datastore/" + datasetId);
  url.searchParams.set("Authorization", apiKey);
  url.searchParams.set("format", "JSON");
  url.searchParams.set("StationId", "466920");
  const response = await fetch(url, {
    headers: { Accept: "application/json" },
    signal: AbortSignal.timeout(12000),
  });
  if (!response.ok) throw new Error("cwa_http_" + response.status);
  const payload = await response.json();
  if (payload?.success === "false" || payload?.success === false) {
    throw new Error("cwa_dataset_rejected");
  }
  return payload;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")?.trim();
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim();
  const cwaKey = Deno.env.get("CWA_OPEN_DATA_API_KEY")?.trim();
  if (!url || !serviceKey) return json({ error: "server_not_configured" }, 503);
  if (!cwaKey) return json({ error: "cwa_api_key_not_configured" }, 503);
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
    const [weatherPayload, rainfallPayload] = await Promise.all([
      fetchCwaDataset("O-A0001-001", cwaKey),
      fetchCwaDataset("O-A0002-001", cwaKey),
    ]);
    const weather = parseCwaWeatherObservation(weatherPayload, "466920");
    if (!weather) return json({ error: "taipei_weather_station_not_found" }, 502);
    const rainfall = parseCwaRainfallObservation(rainfallPayload, "466920");
    const isRaining = Boolean(rainfall?.isRaining || isRainWeatherText(weather.weatherText));
    const weatherText = isRaining
      ? (isRainWeatherText(weather.weatherText) ? weather.weatherText : "降雨中")
      : (weather.weatherText || "天氣資料暫缺");
    const precipitation1h = rainfall?.precipitation1hMm ?? null;

    if (weather.temperatureC === null && !weather.observedAt) {
      return json({ error: "cwa_weather_observation_invalid" }, 502);
    }

    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const now = new Date().toISOString();
    const { error: writeError } = await admin
      .from("encounter_city_weather")
      .upsert({
        city_key: "taipei",
        weather_text: weatherText,
        temperature_c: weather.temperatureC,
        precipitation_1h_mm: precipitation1h,
        is_raining: isRaining,
        observed_at: weather.observedAt,
        fetched_at: now,
        source: "cwa_o-a0001-001+o-a0002-001",
        updated_at: now,
      }, { onConflict: "city_key" });
    if (writeError) return json({ error: "weather_cache_write_failed" }, 503);

    return json({
      status: "updated",
      city: "taipei",
      station_id: "466920",
      weather_text: weatherText,
      temperature_c: weather.temperatureC,
      precipitation_1h_mm: precipitation1h,
      is_raining: isRaining,
      observed_at: weather.observedAt,
      fetched_at: now,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown";
    return json({ error: "weather_sync_failed", detail: message.slice(0, 120) }, 502);
  }
});
