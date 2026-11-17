import assert from 'node:assert/strict';
import fs from 'node:fs';

const html = fs.readFileSync('index.html', 'utf8');
const cityMap = fs.readFileSync('city-map.js', 'utf8');

assert.match(html, /<script src="\.\/city-map\.js"><\/script>/);
assert.match(html, /function renderCityMapMVP\(\)\s*\{[\s\S]*?window\.PoyozzCityMap\?\.render/);
assert.ok(html.indexOf('<script src="./city-map.js"></script>') < html.indexOf('function renderCityMapMVP()'),
  'City map module must load before the main application can invoke it.');
const wrapperStart = html.indexOf('function renderCityMapMVP()');
const initializationStart = html.indexOf('/* Initialization */', wrapperStart);
assert.ok(wrapperStart >= 0 && initializationStart > wrapperStart && initializationStart - wrapperStart < 1200,
  'index.html must retain only the small city-map dependency adapter, not the extracted implementation.');

assert.match(cityMap, /global\.PoyozzCityMap = Object\.freeze/);
assert.match(cityMap, /render\(dependencies\)/);
for (const name of [
  'state', 'accessible', 'escapeHTML', 'safeImage', 'currentUser', 'toast', 'go', 'requireLogin',
  'persist', 'hydratePublicCharacterIllustrations', 'characterVideoObserver',
  'releaseCharacterVideo', 'hydrateCharacterVideo', 'findResumableEncounterSession',
  'setEncounterLifecycleState', 'saveChatSessionSafely', 'createEncounterSession'
]) {
  assert.ok(cityMap.includes(name), 'Injected city-map dependency must remain explicit: ' + name);
}
for (const contract of [
  'POYOZZ 城市地圖',
  'taipeiSunTimes2025',
  'loadCityCharacterSchedules',
  'get_latest_settled_encounter_affinity',
  'city-character-meet',
  'findResumableEncounterSession',
  'setEncounterLifecycleState',
  'saveChatSessionSafely',
  'loadCityCharacterSchedules'
]) {
  assert.ok(cityMap.includes(contract), 'Extracted city-map behavior is missing: ' + contract);
}

const sceneLoaderDeclaration = cityMap.indexOf('const loadCityDynamicScenes=async()=>');
const weatherLoaderDeclaration = cityMap.indexOf('const loadCityWeather=async()=>');
const sceneLoaderInvocation = cityMap.indexOf('void loadCityDynamicScenes();');
const weatherLoaderInvocation = cityMap.indexOf('void loadCityWeather();');
assert.ok(sceneLoaderDeclaration >= 0 && sceneLoaderInvocation > sceneLoaderDeclaration,
  'Dynamic scene loader must be initialized before invocation.');
assert.ok(weatherLoaderDeclaration >= 0 && weatherLoaderInvocation > weatherLoaderDeclaration,
  'Weather loader must be initialized before invocation.');

assert.match(cityMap, /get_encounter_scene_catalog/);
assert.match(cityMap, /refreshScenes\(\)/);
assert.match(cityMap, /refreshSchedules\(\)/);
assert.match(cityMap, /activeScheduleRefresh=async\(\)=>/);
assert.match(cityMap, /await loadCityPeoplePage\(activePlace\)/);
assert.match(cityMap, /activeVenueRefresh=renderVenue/);
assert.match(cityMap, /const latestScene=cityVenueScenes\[place\]\|\|scene/);
assert.match(cityMap, /poyozz-city-map-scenes-v2-v1/);

assert.ok(cityMap.indexOf("void loadCityDynamicScenes();") > cityMap.indexOf("const cityPlaceAliases"),
  "scene catalog loading must start after place aliases and names are initialized");

assert.match(cityMap, /get_encounter_city_weather/);
assert.match(cityMap, /stage.classList.toggle\('is-raining',weather.is_raining===true\)/);
assert.match(cityMap, /MAX_DYNAMIC_SCENE_MARKERS=3/);
assert.match(cityMap, /Math\.hypot\(point\.x-x,point\.y-y\)<120/);
assert.match(cityMap, /data-dynamic-scene/);
assert.match(cityMap, /cityPlaceAliases\[key\]=\[key\]/);
assert.match(cityMap, /row\.event_label/);
assert.match(cityMap, /row\.is_dynamic!==true/);
assert.match(cityMap, /builtInMarker\.setAttribute\('aria-label',name\)/);
assert.match(cityMap, /glyph\.replaceWith\(textGlyph\)/);

assert.match(cityMap, /cityPlaceNames\[key\]=name;\s*cityVenueScenes\[key\]=scene;/);
assert.match(cityMap, /if\(row\.is_dynamic!==true\)[\s\S]*?continue;/);
assert.match(cityMap, /latestScene\.eventTitle,latestScene\.eventDescription/);

assert.match(html, /city-map-stage\.is-raining \.city-map-world/);
assert.match(html, /poyozz-city-rain/);
assert.match(html, /prefers-reduced-motion:reduce\)\{\.city-map-stage\.is-raining:after/);
assert.match(html, /city-map-stage\.is-raining\.low-performance:after/);

console.log('City map module extraction, dynamic scene registry, cached weather, CSS rain fallback, and dependency contract passed.');

assert.match(html,/get_encounter_character_schedules/);
assert.doesNotMatch(cityMap,/hydrateCitySchedule/);
assert.ok(cityMap.includes("const schedules=await loadCityCharacterSchedules(items.map(person=>person.id))"));
assert.ok(!cityMap.includes("Promise.all(items.map(hydrateCitySchedule)"));

assert.match(cityMap, /const targetCount=pager\.people\.length\+10/);
assert.match(cityMap, /scannedPages<5/);
assert.match(cityMap, /while\(pager\.hasMore&&pager\.people\.length<targetCount/);
assert.match(html, /button.dataset\.aiEnabled='false'/);
assert.match(html, /button.dataset\.aiEnabled='true'/);
assert.match(html, /button.dataset\.aiEnabled!=='true'\|\|button\.disabled/);
assert.match(html, /AI 生成角色行程與場景/);
assert.doesNotMatch(html, /if\(error\|\|data\?\.enabled!==true\)\{section\.remove\(\);return;\}/);

assert.match(html, /if\(!client\)throw new Error\('城市角色行程服務尚未連線。'\)/);
assert.match(html, /if\(error\)throw new Error\('讀取角色行程失敗：'\+error\.message\)/);
assert.doesNotMatch(html, /城市角色排程批次載入失敗[\s\S]{0,180}return schedules/);
assert.match(cityMap, /const hasAnySchedule=\(pager\?\.candidates\|\|\[\]\)\.some\(person=>String\(person\.encounterSchedules\|\|''\)\.trim\(\)\)/);
assert.match(cityMap, /尚未建立角色行程；可到測試工具手動生成。/);
assert.match(cityMap, /目前沒有角色在此地點與台灣時間活動。/);
assert.match(cityMap, /角色行程載入失敗，請重試。/);
assert.match(cityMap, /data-action="city-people-retry"/);
assert.match(cityMap, /const retryButton=event\.target\.closest\('\[data-action="city-people-retry"\]'\)/);
assert.match(cityMap, /pager\.error=null;void loadCityPeoplePage\(locationModal\.dataset\.place\)/);
