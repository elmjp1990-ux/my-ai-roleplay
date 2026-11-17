import assert from "node:assert/strict";
import fs from "node:fs";
import { parseEncounterTurnOutput } from "../supabase/functions/_shared/encounter-turn-output.mjs";

const text = "相遇內容。".repeat(30);
const illustrationId = "11111111-1111-4111-8111-111111111111";
const sceneBackgroundId = "22222222-2222-4222-8222-222222222222";
assert.equal(Array.from(text).length, 150);
assert.deepEqual(
  parseEncounterTurnOutput(JSON.stringify({ reply: text, illustration_id: illustrationId, scene_background_id: sceneBackgroundId })),
  { reply: text, illustrationId, sceneBackgroundId },
);
assert.equal(parseEncounterTurnOutput(JSON.stringify({ reply: "太短了" })), null);
assert.equal(parseEncounterTurnOutput(JSON.stringify({ reply: "相遇內容".repeat(76) })), null);
assert.equal(parseEncounterTurnOutput("not-json"), null);
assert.equal(parseEncounterTurnOutput(JSON.stringify(["not", "an", "object"])), null);
assert.equal(parseEncounterTurnOutput(JSON.stringify({ reply: 123 })), null);
assert.equal(parseEncounterTurnOutput(JSON.stringify({ reply: text, illustration_id: "invented-id" })).illustrationId, null);

const max = "相遇內容".repeat(75);
assert.equal(Array.from(max).length, 300);
assert.equal(parseEncounterTurnOutput(JSON.stringify({ reply: max })).reply, max);

const endpoint = fs.readFileSync("supabase/functions/encounter-turn/index.ts", "utf8");
const guidelines = fs.readFileSync("supabase/functions/_shared/encounter-response-guidelines.ts", "utf8");
const frontend = fs.readFileSync("index.html", "utf8");
const scene = fs.readFileSync("encounter-scene.js", "utf8");
const sessionCreator = fs.readFileSync("supabase/functions/encounter-session/index.ts", "utf8");
const pipeline = fs.readFileSync("supabase/drafts/encounter-schedule-pipeline.sql", "utf8");
const replay = fs.readFileSync("supabase/drafts/replay-encounter-schedule-pipeline.sql", "utf8");
const weatherSync = fs.readFileSync("supabase/functions/encounter-weather-sync/index.ts", "utf8");
const weatherModule = fs.readFileSync("supabase/functions/_shared/encounter-weather.mjs", "utf8");
const cityMap = fs.readFileSync("city-map.js", "utf8");

assert.equal((pipeline.match(/^BEGIN;$/gm) || []).length, 1, "Encounter SQL draft must contain one transaction start");
assert.equal((pipeline.match(/^COMMIT;$/gm) || []).length, 1, "Encounter SQL draft must contain one transaction end");
assert.doesNotMatch(pipeline, /encounter_weather_baseline_2025|O-A0001-001|O-A0002-001|CWA_OPEN_DATA_API_KEY/);
assert.ok(pipeline.includes("CHECK (asset_path ~ '^([.]/|/)[A-Za-z0-9_./-]+$')"));
assert.match(pipeline, /ALTER TABLE public\.encounter_city_weather ALTER COLUMN source SET DEFAULT 'poyozz_fictional_seasonal'/);
assert.match(pipeline, /UPDATE public\.encounter_city_weather[\s\S]*?source = 'poyozz_fallback'[\s\S]*?WHERE source IS DISTINCT FROM 'poyozz_fictional_seasonal'/);
assert.match(pipeline, /AND c\.deleted_at IS NULL;\s*IF p_force IS NOT TRUE/);
assert.doesNotMatch(weatherSync, /\bfetch\s*\(/, "Taipei simulation must not call external weather APIs");
assert.doesNotMatch(weatherSync, /CWA|OPEN_DATA_API_KEY|forecast/i);
assert.match(weatherSync, /previousSlot === weather\.slot/);
assert.match(weatherSync, /status: "unchanged"/);
assert.match(weatherModule, /Asia\/Taipei/);
assert.match(weatherModule, /poyozz_fictional_seasonal/);
assert.match(cityMap, /CITY_MAP_WEATHER_CACHE_TTL_MS = 6 \* 60 \* 60 \* 1000/);
assert.match(cityMap, /CITY_MAP_SCENES_CACHE_TTL_MS = 30 \* 60 \* 1000/);
assert.match(pipeline, /ORDER BY r\.display_order, r\.location_key\s+LIMIT 3/);

assert.match(endpoint, /requestOpenRouterChatCompletion/);
assert.match(endpoint, /POYOZZ_DEFAULT_CHAT_MODEL/);
assert.match(endpoint, /reserve_encounter_chat_turn/);
assert.match(endpoint, /releaseGenerationClaim/);
assert.match(endpoint, /refundEncounterTurn/);
assert.equal((endpoint.match(/admin\.rpc\(["\']refund_chat_turn["\']/g) || []).length, 1, "Refund logic must be centralized");
assert.match(endpoint, /findPrivateContextLeak/);
assert.match(endpoint, /record_encounter_session_turn_evidence/);
assert.match(endpoint, /settle_chat_turn/);
assert.doesNotMatch(endpoint, /demoReply/);
assert.ok(
  endpoint.indexOf('if (!openRouterKey)') < endpoint.indexOf('reserve_encounter_chat_turn'),
  "Missing OpenRouter credentials must fail before wallet reservation",
);
assert.match(endpoint, /provider_generation_outcome_unknown/);
assert.match(endpoint, /provider_request_refund/);
assert.doesNotMatch(endpoint, /classifyProviderFailure/);
assert.match(endpoint, /generation_already_claimed/);
assert.match(guidelines, /150～300 字元/);
assert.match(guidelines, /buildRoleplayResponseGuidelines\(["']single["']\)/);
assert.match(frontend, /poyozz-encounter-opening-choice/);
assert.match(frontend, /initialOpeningMessage = \{ text: greeting, at: Date\.now\(\) \}/);
assert.match(frontend, /encounterOpeningChoice:\['greet','wait'\]/);
assert.match(frontend, /session\.encounterIntroChoice=\['greet','wait'\]/);
assert.match(scene, /data-action="encounter-opening-choice"/);
assert.match(scene, /data-choice="greet"/);
assert.match(scene, /data-choice="wait"/);
assert.match(endpoint, /openingMessage = asRow\(asRow\(session\.session_data\)\.openingMessage\)/);
assert.match(endpoint, /encounterSchedule/);
assert.doesNotMatch(endpoint, /from\(["']encounter_session_lifecycle["']\)/);
assert.match(sessionCreator, /snapshot\.encounterSchedule = scheduleSnapshot/);
assert.match(sessionCreator, /snapshot\.encounterGreeting/);
assert.match(sessionCreator, /availableIllustrations/);
assert.match(sessionCreator, /availableSceneBackgrounds/);
assert.match(endpoint, /resolveEncounterVisuals/);
assert.match(endpoint, /encounter_turn_visuals/);
assert.match(endpoint, /sceneBackgroundPath/);
assert.match(pipeline, /CREATE TABLE IF NOT EXISTS public\.encounter_scene_backgrounds/);
assert.match(pipeline, /CREATE TABLE IF NOT EXISTS public\.encounter_turn_visuals/);
assert.match(pipeline, /v_schedule_day::smallint,\s*v_day_type/);
assert.match(pipeline, /CASE WHEN v_is_raining IS TRUE AND v_row\.is_outdoor IS TRUE\s*THEN v_row\.rain_fallback_location_key ELSE v_row\.location_key END/);
assert.match(replay, /DO \$rainy_schedule_resolution_smoke\$/);
assert.match(replay, /rainy outdoor schedule did not resolve to its indoor fallback/);
assert.match(replay, /dry outdoor schedule did not resolve to its original location/);
assert.match(replay, /must not remain at its original outdoor location/);
assert.match(pipeline, /encounter-default-scene\.webp/);
assert.match(pipeline, /REFERENCES public\.character_illustrations\(id\)/);
assert.match(endpoint, /illustration_id/);
assert.match(endpoint, /scene_background_id/);
assert.match(scene, /session\?\.encounterVisuals/);
assert.match(scene, /hydrateEncounterGalleryIllustration\(character\.id,selectedIllustrationId\)/);
const openingHandlerStart = frontend.indexOf("window.addEventListener('poyozz-encounter-opening-choice'");
const openingHandlerEnd = frontend.indexOf("async function markCloudChatSessionRead", openingHandlerStart);
assert.ok(openingHandlerStart >= 0 && openingHandlerEnd > openingHandlerStart, "Opening-choice persistence handler must exist");
const openingHandler = frontend.slice(openingHandlerStart, openingHandlerEnd);
assert.doesNotMatch(openingHandler, /executePendingChatTurn|reserve_encounter_chat_turn/,
  "Free opening choice must not call AI or reserve wallet funds");

console.log("Encounter AI output, billing safety, and opening-choice contract tests passed.");
