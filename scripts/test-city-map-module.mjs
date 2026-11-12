import assert from 'node:assert/strict';
import fs from 'node:fs';

const html = fs.readFileSync('index.html', 'utf8');
const cityMap = fs.readFileSync('city-map.js', 'utf8');

assert.match(html, /<script src="\.\/city-map\.js"><\/script>/);
assert.match(html, /function renderCityMapMVP\(\)\s*\{[\s\S]*?window\.PoyozzCityMap\?\.render/);
assert.ok(html.indexOf('<script src="./city-map.js"></script>') < html.indexOf('<script>\n'),
  'City map module must load before the main application script.');
assert.doesNotMatch(html, /function renderCityMapMVP\(\)\s*\{[\s\S]{2000,}function renderCityMapMVP/,
  'The city map implementation must not remain duplicated in index.html.');

assert.match(cityMap, /global\.PoyozzCityMap = Object\.freeze/);
assert.match(cityMap, /render\(dependencies\)/);
for (const name of [
  'state', 'escapeHTML', 'safeImage', 'currentUser', 'toast', 'go', 'requireLogin',
  'persist', 'hydratePublicCharacterIllustrations', 'characterVideoObserver',
  'releaseCharacterVideo', 'hydrateCharacterVideo', 'findResumableEncounterSession',
  'setEncounterLifecycleState', 'saveChatSessionSafely', 'createEncounterSession'
]) {
  assert.ok(cityMap.includes(name), 'Injected city-map dependency must remain explicit: ' + name);
}
for (const contract of [
  'POYOZZ 城市地圖',
  'taipeiSunTimes2025',
  'get_encounter_character_schedule',
  'get_latest_settled_encounter_affinity',
  'city-character-meet',
  'findResumableEncounterSession',
  'setEncounterLifecycleState',
  'saveChatSessionSafely'
]) {
  assert.ok(cityMap.includes(contract), 'Extracted city-map behavior is missing: ' + contract);
}

console.log('City map module extraction and dependency contract passed.');
