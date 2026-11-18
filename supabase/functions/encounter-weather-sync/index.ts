import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { createEncounterWeather } from "../_shared/encounter-weather.mjs";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

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
    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: previous, error: readError } = await admin
      .from("encounter_city_weather")
      .select("weather_text, temperature_c, is_raining, fetched_at, source")
      .eq("city_key", "taipei")
      .maybeSingle();
    if (readError) return json({ error: "weather_cache_read_failed" }, 503);

    const now = new Date();
    const previousFetchedAt = previous?.fetched_at ? new Date(previous.fetched_at) : null;
    const weather = createEncounterWeather(now);
    const previousSlot = previousFetchedAt && Number.isFinite(previousFetchedAt.getTime())
      ? createEncounterWeather(previousFetchedAt).slot : null;
    if (previous && previousSlot === weather.slot && previous.source === weather.source) {
      return json({ status: "unchanged", city: "taipei", weather_text: previous.weather_text,
        temperature_c: previous.temperature_c, is_raining: previous.is_raining,
        fetched_at: previous.fetched_at, source: "poyozz_fictional_seasonal" });
    }
    if (previous?.weather_text === weather.weatherText && previous?.temperature_c !== null) {
      weather.temperatureC = Number(previous.temperature_c);
    }
    const unchanged = previous?.weather_text === weather.weatherText
      && Number(previous?.temperature_c) === weather.temperatureC
      && previous?.is_raining === weather.isRaining
      && previous?.source === weather.source;

    if (!unchanged) {
      const { error: writeError } = await admin
        .from("encounter_city_weather")
        .upsert({
          city_key: "taipei",
          weather_text: weather.weatherText,
          temperature_c: weather.temperatureC,
          precipitation_1h_mm: weather.precipitation1hMm,
          is_raining: weather.isRaining,
          observed_at: weather.observedAt,
          fetched_at: now.toISOString(),
          source: weather.source,
          updated_at: now.toISOString(),
        }, { onConflict: "city_key" });
      if (writeError) return json({ error: "weather_cache_write_failed" }, 503);
    }

    return json({
      status: unchanged ? "unchanged" : "updated",
      city: "taipei",
      weather_text: weather.weatherText,
      temperature_c: weather.temperatureC,
      is_raining: weather.isRaining,
      fetched_at: now.toISOString(),
      source: weather.source,
    });
  } catch {
    return json({ error: "weather_sync_failed" }, 503);
  }
});
