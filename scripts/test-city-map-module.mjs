import assert from 'node:assert/strict';
import fs from 'node:fs';

const html = fs.readFileSync('index.html', 'utf8');
const cityMap = fs.readFileSync('city-map.js', 'utf8');
const encounterHistory = fs.readFileSync('encounter-history.js', 'utf8');
assert.match(html,/session_id:metadata->>session_id/,
  'Encounter diary list must select only the session ID from JSON metadata');
assert.doesNotMatch(html,/select\('id,summary,occurred_at,metadata'\)/,
  'Encounter diary list and detail pages must not transfer unused metadata JSON');
assert.match(encounterHistory,/const N=10/);
assert.match(encounterHistory,/\.range\(offset,offset\+N-1\)/,
  'City Encounter history must fetch only ten sessions per page');
assert.match(encounterHistory,/\.limit\(N\)/,
  'City Encounter history preview hydration must be capped at ten messages');
assert.match(encounterHistory,/\.select\('session_id'\)/,
  'City Encounter history fallback must fetch only session IDs, never message bodies');
assert.doesNotMatch(encounterHistory,/\.select\('session_id,content'\)/,
  'City Encounter history list must not transfer full chat message content');
assert.match(encounterHistory,/observeEnd/,
  'City Encounter history must load the next ten records when scrolled to the end');
assert.match(encounterHistory,/encounterHistoryOffset=offset\+batch\.length/);
assert.doesNotMatch(encounterHistory,/while\(true\)|\.limit\(200\)/,
  'City Encounter history must not eagerly fetch every page or 200 message previews');


assert.match(html, /<script src="\.\/city-map\.js"><\/script>/);
assert.match(html, /session_encounter_temporarily_left_at:session_data->>encounterTemporarilyLeftAt/);
assert.match(html, /encounterTemporarilyLeftAt:Number\(row\.session_encounter_temporarily_left_at\)/);
assert.match(cityMap, /get_encounter_character_affinity/);
assert.match(cityMap, /findResumableEncounterSession=async/);
assert.match(html, /function renderCityMapMVP\(\)\s*\{[\s\S]*?window\.PoyozzCityMap\?\.render/);
assert.ok(html.indexOf('<script src="./city-map.js"></script>') < html.indexOf('function renderCityMapMVP()'),
  'City map module must load before the main application can invoke it.');
const wrapperStart = html.indexOf('function renderCityMapMVP()');
const initializationStart = html.indexOf('/* Initialization */', wrapperStart);
assert.ok(wrapperStart >= 0 && initializationStart > wrapperStart && initializationStart - wrapperStart < 1200,
  'index.html must retain only the small city-map dependency adapter, not the extracted implementation.');

assert.match(cityMap, /global\.PoyozzCityMap = Object\.freeze/);
assert.match(cityMap, /client\.from\('chat_sessions'\)/);
assert.match(cityMap, /\.eq\('chat_mode','encounter'\)/);
assert.match(cityMap, /encounter_place:session_data->>encounterPlace/);
assert.doesNotMatch(cityMap, /select\('id,character_id,chat_mode,session_data,updated_at'\)/,
  'resumable encounter lookup must not transfer the full session_data JSON payload');
assert.match(cityMap, /Number\(row\.encounter_left_at\)>0/);
assert.match(cityMap, /row\.event_label/);
assert.match(cityMap, /loadCloudChatSessions\(user,\{onlySessionId:candidate\.id,listPage:false\}\)/,
  'Resume lookup must hydrate the candidate cloud session before reopening it');
assert.match(cityMap, /hydrated\?\.cloudOwned===true/);
assert.doesNotMatch(cityMap, /PoyozzEncounterSessionResume/,
  'Resume lookup must not depend on an undefined global module');
assert.doesNotMatch(cityMap, /inferCharacterAgeFromLore/,
  'Character age must not be guessed from introduction text');
assert.doesNotMatch(cityMap, /snapshotAges|consistentSnapshotAge|cloudCharacterSnapshot\.age/,
  'City cards must not replace the authoritative live age with stale chat snapshots');
assert.match(cityMap, /const liveAge=\[person\.age,person\.characterAge,person\.character_age\]\.map\(value=>value==null\?'':String\(value\)\.trim\(\)\)\.find\(Boolean\)\|\|''/);
assert.ok(cityMap.includes("const ageDisplay=liveAge?( /^\\d+$/.test(liveAge)?liveAge+' 歲':liveAge):'未設定'"),
  'Only a numeric age receives the 歲 suffix; descriptive text must remain unchanged');
assert.match(cityMap, /requestedSleepScene=person\.name==='陸沈宵'&&rawTimeRange==='08:00–09:00'/);
assert.match(cityMap, /安靜且完全遮光的臥室，深層睡眠中。/);
assert.match(cityMap, /render\(dependencies\)/);
for (const name of [
  'state', 'accessible', 'escapeHTML', 'safeImage', 'currentUser', 'toast', 'go', 'requireLogin',
  'persist', 'hydratePublicCharacterIllustrations', 'characterVideoObserver',
  'releaseCharacterVideo', 'hydrateCharacterVideo', 'findResumableEncounterSession',
  'setEncounterLifecycleState', 'createEncounterSession'
]) {
  assert.ok(cityMap.includes(name), 'Injected city-map dependency must remain explicit: ' + name);
}
for (const contract of [
  'POYOZZ 城市地圖',
  'taipeiSunTimes2025',
  'loadCityCharacterSchedules',
  'get_encounter_character_affinity',
  'city-character-meet',
  'findResumableEncounterSession',
  'setEncounterLifecycleState',
  'loadCityCharacterSchedules'
]) {
  assert.ok(cityMap.includes(contract), 'Extracted city-map behavior is missing: ' + contract);
}

const sceneLoaderDeclaration = cityMap.indexOf('const loadCitySceneCatalog=async()=>');
const weatherLoaderDeclaration = cityMap.indexOf('const loadCityWeather=async()=>');
const sceneLoaderInvocation = cityMap.indexOf('void loadCitySceneCatalog();');
const weatherLoaderInvocation = cityMap.indexOf('void loadCityWeather();');
assert.ok(sceneLoaderDeclaration >= 0 && sceneLoaderInvocation > sceneLoaderDeclaration,
  'Scene catalog loader must be initialized before invocation.');
assert.ok(weatherLoaderDeclaration >= 0 && weatherLoaderInvocation > weatherLoaderDeclaration,
  'Weather loader must be initialized before invocation.');

assert.match(cityMap, /get_encounter_scene_catalog/);
const liveAffinityMigration=fs.readFileSync('supabase/migrations/20261120150000_encounter_character_affinity_live_read.sql','utf8');
assert.match(liveAffinityMigration,/get_encounter_character_affinity/);
assert.match(liveAffinityMigration,/state\.affinity, state\.relationship_stage/);
assert.match(liveAffinityMigration,/auth\.uid\(\)/);
assert.match(liveAffinityMigration,/GRANT EXECUTE ON FUNCTION public\.get_encounter_character_affinity\(uuid\) TO authenticated/);
const sceneAvailabilityMigration=fs.readFileSync('supabase/migrations/20261118074708_resolve_only_published_encounter_scenes.sql','utf8');
const hourlyOptionsMigration=fs.readFileSync('supabase/migrations/20261118074718_encounter_hourly_schedule_options.sql','utf8');
const fixedSceneMigration=fs.readFileSync('supabase/migrations/20261123100000_fixed_encounter_city_scene_anchors.sql','utf8');
assert.match(fixedSceneMigration,/Returns only the fourteen permanent A–N city scene anchors/);
assert.match(fixedSceneMigration,/publish_encounter_scene_metadata/);
assert.match(fixedSceneMigration,/It cannot create, move, rename, activate, or hide map markers/);
for (const key of [
  'waterfront','commercial','airport','university','park','shopping-street',
  'department-store','hospital','night-bar','live-house','luxury-apartment',
  'apartment','convenience-store','private-club'
]) {
  assert.ok(fixedSceneMigration.includes("'" + key + "'"),
    'SQL registry migration must include fixed scene key ' + key);
}
assert.match(sceneAvailabilityMigration,/get_encounter_scene_catalog/,
  'Only scenes in the server-owned catalog may resolve onto the map.');
assert.match(hourlyOptionsMigration,/hourly-options-v1/);
assert.match(hourlyOptionsMigration,/\),\s*100\s*\)/,
  'Hourly options must keep the original 0–99 weighted roll; unavailable selections are not rerolled.');
assert.equal(
  fs.existsSync('supabase/migrations/20261119001100_encounter_schedule_available_option_weighting.sql'),
  false,
  'Unavailable scene options must not be removed from or renormalized within the original weighted pool.'
);
assert.match(cityMap, /refreshScenes\(\)/);
assert.match(cityMap, /refreshSchedules\(\)/);
assert.match(cityMap, /activeScheduleRefresh=async\(\)=>/);
assert.match(cityMap, /refreshSchedules\(\)\s*\{\s*return activeScheduleRefresh \? activeScheduleRefresh\(\) : Promise\.resolve\(\);\s*\}/, 'Schedule refresh must safely no-op before the city map is rendered or after it is destroyed.');
assert.match(cityMap, /activeScheduleRefresh = null/, 'Destroying the active city map must release its schedule refresh callback.');
assert.match(cityMap, /await loadCityPeoplePage\(activePlace\)/);
assert.match(cityMap, /activeVenueRefresh=renderVenue/);
assert.match(cityMap, /const latestScene=cityVenueScenes\[place\]\|\|scene/);
assert.match(cityMap, /poyozz-city-map-scenes-v3-v1/);

assert.ok(cityMap.indexOf("void loadCitySceneCatalog();") > cityMap.indexOf("const cityVenueScenes"),
  "scene catalog loading must start after the fixed scene-key map is initialized");

assert.match(cityMap, /get_encounter_city_weather/);
assert.match(cityMap, /stage.classList.toggle\('is-raining',weather.is_raining===true\)/);
assert.doesNotMatch(cityMap, /MAX_DYNAMIC_SCENE_MARKERS|data-dynamic-scene|cityDynamicSceneMarkers|createElementNS\(CITY_MAP_SVG_NS/);
assert.doesNotMatch(cityMap, /Math\.hypot\(point\.x-x,point\.y-y\)<120/);
assert.match(cityMap, /marker\.dataset\.place===key/);
assert.doesNotMatch(cityMap, /cityPlaceAliases|getTaipeiClock/);
assert.match(cityMap, /row=>row\?\.location_key===sceneKey/);
assert.match(cityMap, /Array\.isArray\(character\.encounterSchedules\)/);
assert.match(html, /rows\.push\(row\)/);
assert.doesNotMatch(html, /encodeURIComponent\(String\(row\.scene_description/);
assert.match(cityMap, /row\.event_label/);
assert.match(cityMap, /row\?\.location_key===sceneKey/);
assert.match(cityMap, /const cityPlaceNames=Object\.create\(null\)/);
assert.match(cityMap, /const cityVenueScenes=Object\.create\(null\)/);
assert.doesNotMatch(cityMap, /cityPlaceSubtitles|airport:\{icon:/);
assert.match(cityMap, /await loadCitySceneCatalog\(\);[\s\S]*?const scene=cityVenueScenes\[place\]/);
assert.doesNotMatch(cityMap, /row\.is_dynamic!==true/);
assert.doesNotMatch(cityMap, /builtInMarker\.setAttribute/);
assert.doesNotMatch(cityMap, /glyph\.replaceWith\(textGlyph\)/);
assert.equal((cityMap.match(/class="city-place-marker is-available"/g)||[]).length,14,
  'The city map must render exactly fourteen fixed A–N scene anchors.');
for (const key of [
  'waterfront','commercial','airport','university','park','shopping-street',
  'department-store','hospital','night-bar','live-house','luxury-apartment',
  'apartment','convenience-store','private-club'
]) {
  assert.match(cityMap, new RegExp('data-place="' + key + '"'),
    'Fixed A–N map anchor is missing: ' + key);
}
assert.match(cityMap, /data-place="night-bar" transform="translate\(632 294\)"/,
  'Existing I night-bar marker coordinates must remain unchanged.');
assert.match(cityMap, /data-place="apartment" transform="translate\(666 440\)"/,
  'Existing L 308 apartment marker coordinates must remain unchanged.');
assert.match(cityMap, /cityVenueScenes\[key\]=scene;/);
assert.doesNotMatch(cityMap, /cityPlaceNames\[key\]=name|marker\.setAttribute\('aria-label',name\)/, 'Scene catalog updates must not rename or move fixed map anchors.');
assert.match(cityMap, /latestScene\.eventTitle,latestScene\.eventDescription/);

assert.match(html, /city-map-stage\.is-raining \.city-map-world/);
assert.match(html, /poyozz-city-rain/);
assert.match(html, /prefers-reduced-motion:reduce\)\{\.city-map-stage\.is-raining:after/);
assert.match(html, /city-map-stage\.is-raining\.low-performance:after/);


const ageTextMigration=fs.readFileSync('supabase/migrations/20261121100000_character_age_as_text.sql','utf8');
assert.match(ageTextMigration,/ALTER COLUMN age TYPE text/);
assert.match(ageTextMigration,/USING age::text/);
assert.match(html,/const age = ageValue \|\| null/);
assert.match(html,/ageValue\.length > 25/);
assert.match(html,/select\('visibility, age, first_published_at/);
assert.match(html,/String\(savedCharacter\.age \?\? ''\) !== ageValue/);
assert.match(html,/name="age" type="text" maxlength="25"/);
assert.match(html,/age: row\.age == null \? '' : String\(row\.age\)/);

console.log('City map module extraction, fixed A–N scene anchors, descriptive character age, cached weather, CSS rain fallback, and dependency contract passed.');

assert.match(html,/get_encounter_character_schedules/);
assert.doesNotMatch(cityMap,/hydrateCitySchedule/);
assert.ok(cityMap.includes("const schedules=await loadCityCharacterSchedules(items.map(person=>person.id))"));
assert.ok(!cityMap.includes("Promise.all(items.map(hydrateCitySchedule)"));

assert.match(cityMap, /const targetCount=pager\.people\.length\+10/);
assert.match(cityMap, /scannedPages<5/);
assert.match(cityMap, /while\(pager\.hasMore&&pager\.people\.length<targetCount/);
assert.match(html, /button.dataset\.aiEnabled='false'/);
assert.match(html, /const canRun=pending>0&&!blocked/);
assert.ok(html.includes('const scheduleEnabled=canRun&&profileReady&&!profileStatusError'));
assert.ok(html.includes("button.dataset.aiEnabled=scheduleEnabled?'true':'false'"));
assert.ok(html.includes("button.disabled=!scheduleEnabled"));
assert.match(html, /processing_character_count/);
assert.match(html, /failed_character_count/);
assert.match(html, /needs_reconciliation_count/);
assert.match(html, /button.dataset\.aiEnabled!=='true'\|\|button\.disabled/);
assert.match(html, /AI 生成角色行程與場景/);
assert.doesNotMatch(html, /if\(error\|\|data\?\.enabled!==true\)\{section\.remove\(\);return;\}/);

assert.match(html, /if\(!client\)throw new Error\('城市角色行程服務尚未連線。'\)/);
assert.match(html, /if\(error\)throw new Error\('讀取角色行程失敗：'\+error\.message\)/);
assert.doesNotMatch(html, /城市角色排程批次載入失敗[\s\S]{0,180}return schedules/);
assert.match(cityMap, /目前沒有角色出現在此場景/);
assert.match(cityMap, /目前沒有角色出現在此場景/);
assert.match(cityMap, /角色行程載入失敗，請重試。/);
assert.match(cityMap, /data-action="city-people-retry"/);
assert.match(cityMap, /const retryButton=event\.target\.closest\('\[data-action="city-people-retry"\]'\)/);
assert.match(cityMap, /pager\.error=null;void loadCityPeoplePage\(locationModal\.dataset\.place\)/);

const scheduleOrganizer = fs.readFileSync('supabase/functions/_shared/encounter-schedule-organizer-handler.ts', 'utf8');
const scheduleOrganizerEntry = fs.readFileSync('supabase/functions/encounter-schedule-organizer/index.ts', 'utf8');
const schedulePipelineMigration = fs.readFileSync('supabase/migrations/20261117095320_encounter_schedule_pipeline.sql', 'utf8');
const scheduleBatchMigration = fs.readFileSync('supabase/migrations/20261117133525_encounter_schedule_batch_semantics.sql', 'utf8');
assert.match(scheduleOrganizer, /ENCOUNTER_SCHEDULE_TEST_MODE["']\) !== ["']true/);
assert.match(scheduleOrganizerEntry, /handleEncounterScheduleOrganizer\(request, Deno\.env, createClient, 100_000\)/);
assert.match(scheduleOrganizer, /test_mode: false/);
assert.match(scheduleOrganizer, /test_mode: true/);
assert.match(scheduleOrganizer, /auth\.getUser\(\)/);
assert.doesNotMatch(scheduleOrganizer, /ENCOUNTER_SCHEDULE_TEST_USER_IDS/);
assert.doesNotMatch(scheduleOrganizer, /account_is_active/);
assert.match(scheduleOrganizer, /manual_schedule_trigger_disabled/);
assert.match(scheduleOrganizer, /blocked_unresolved_failures/);
assert.match(scheduleOrganizer, /processing_character_count/);
assert.match(scheduleOrganizer, /failed_character_count/);
assert.match(scheduleOrganizer, /needs_reconciliation_count/);
assert.match(scheduleOrganizer, /const enrichedSources = await Promise\.all\(sources\.map\(async \(source\)/);
assert.match(scheduleOrganizer, /get_character_ai_profile_for_chat/);
assert.match(scheduleOrganizer, /const generationSources = enrichedSources\.filter\(/);
assert.match(scheduleOrganizer, /classifyEncounterWorldview\(source\)/);
assert.match(scheduleOrganizer, /ai_generation_skipped: true/);
assert.match(scheduleOrganizer, /Promise\.all\(generationSources\.map\(async \(source\)/);
assert.match(scheduleOrganizer, /characterPrompt = buildEncounterScheduleBatchMessages\(\[source\], sceneCatalog\)/,
  'the AI receives active scene display names as optional examples, never as a whitelist');
assert.match(scheduleOrganizer, /parseEncounterScheduleBatchOutput\([\s\S]*?\[source\],[\s\S]*?sceneCatalog/);
assert.match(scheduleOrganizer, /parseEncounterScheduleBatchOutput\([\s\S]*?\[source\],[\s\S]*?sceneCatalog/);
assert.match(scheduleOrganizer, /providerTimeoutMs = 100_000/);
assert.ok(scheduleOrganizer.includes("Math.min(") && scheduleOrganizer.includes("270_000"),
  "Shared schedule handler must cap its runtime-specific provider timeout at 270 seconds.");
assert.match(scheduleOrganizer, /timeoutMs: ENCOUNTER_SCHEDULE_PROVIDER_TIMEOUT_MS/);
assert.match(scheduleOrganizer, /provider_duration_ms/);
assert.match(scheduleOrganizer, /let providerDurationMs = 0/);
assert.match(scheduleOrganizer, /providerDurationMs = providerResponse\.durationMs/);
assert.match(scheduleOrganizer, /measuredProviderDurationMs = providerDurationMs \|\| Date\.now\(\) - providerStartedAt/);
assert.match(schedulePipelineMigration, /v_timeout := 120000/);
assert.match(scheduleBatchMigration, /lease_expires_at = v_now \+ interval '20 minutes'/);
assert.match(scheduleOrganizer, /_poyozz_diagnostics/);
assert.match(scheduleOrganizer, /character_id: characterId/);
assert.match(scheduleOrganizer, /sourceId: result.sourceId, providerResponse: result.providerResponse/);
const openRouterHelper = fs.readFileSync('supabase/functions/_shared/openrouter-chat-completions.ts', 'utf8');
assert.match(openRouterHelper, /const responseText = await response\.text\(\)/);
assert.match(openRouterHelper, /responseContentType/);
assert.match(openRouterHelper, /durationMs: Date\.now\(\) - startedAt/);
assert.match(openRouterHelper, /responseParsed/);
assert.match(openRouterHelper, /http_\" \+ response\.status/);
assert.match(html, /if\(!error&&data\?\.test_mode!==true\)\s*\{\s*section\.hidden=true/);
assert.match(html, /目前暫停生成，請先確認處理中工作或待核對結果。/);
assert.match(html, /失敗紀錄保留，不會自動重試/);
assert.doesNotMatch(html, /測試環境登入帳號皆可使用/);
assert.match(html, /正式環境不提供此工具/);


assert.match(cityMap, /data-place="apartment"[\s\S]*?aria-label="308公寓"/);
assert.match(cityMap, /const cardPerson=\{\.\.\.live,\.\.\.person\}/,
  'Opening a city character card must merge resolved schedule data with the base profile.');
assert.match(cityMap, /if\(\(person\?\.\[key\]==null\|\|person\?\.\[key\]===''\)&&live\?\.\[key\]!=null\)cardPerson\[key\]=live\[key\]/,
  'Null or empty schedule profile fields must fall back to the cached character profile.');
assert.match(cityMap, /renderCityCharacterCard\(cardPerson,0\)/);
assert.match(html, /city-character-photo-column \.city-character-portrait\{[^}]*background:transparent!important/);
assert.match(cityMap, /const isSleepingSchedule=.*睡夢.*淺眠/);
assert.match(cityMap, /return schedules\.some\(row=>row\?\.location_key===sceneKey\)/,
  'Sleeping characters must remain visible in their current city scene.');
assert.match(cityMap, /\.find\(item=>item\?\.location_key===sceneKey\)/,
  'The displayed status must use the current scene schedule even when the character is asleep.');
assert.match(cityMap, /const meetControl=isSleepingSchedule[\s\S]*?熟睡中無法打擾/);
assert.match(cityMap, /const left=.*meetControl/);

assert.match(cityMap, /id="cityMapPlaceSubtitle"/,
  'Scene title row must provide a dedicated subtitle element.');
assert.doesNotMatch(cityMap, /city-location-open-inline/,
  'Scene title must not render the redundant open-status label or green dot.');
assert.doesNotMatch(html, /city-location-open-inline/,
  'Removed open-status CSS must not remain in the main stylesheet.');
assert.match(html, /\.city-location-subtitle\{/,
  'Scene subtitle must use the restrained secondary-text style.');
assert.doesNotMatch(cityMap, /cityPlaceSubtitles/,
  'Redundant hardcoded scene subtitles must be removed; the database catalog is the single scene metadata source.');
assert.match(cityMap, /placeSubtitle\)placeSubtitle\.textContent=''/,
  'The unused subtitle element must be cleared rather than retaining a second scene-name dictionary.');

