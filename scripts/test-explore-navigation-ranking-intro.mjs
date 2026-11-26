import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync('index.html', 'utf8');
const cityMap = readFileSync('city-map.js', 'utf8');
const migration = readFileSync('supabase/migrations/20261126072000_explore_character_leaderboards.sql', 'utf8');

assert.match(html, /go\(\{page:route\.page==='citymap'\?'home':'citymap'\}\)/,
  'Explore navigation must toggle map and traditional Explore only when already on either mode.');
assert.match(html, /\['citymap','home','detail','session-detail'\]\.includes\(route\.page\) \? 'citymap'/,
  'Map and traditional Explore should share the active Explore navigation state.');
assert.doesNotMatch(cityMap, /city-map-traditional|data-action="city-traditional"/,
  'The redundant traditional Explore shortcut must be removed from the map.');

assert.match(html, /data-action="popular-period" data-period="all"/);
assert.match(html, /data-action="popular-period" data-period="month"/);
assert.match(html, /data-action="popular-period" data-period="week"/);
assert.match(html, /get_public_character_leaderboard/);
assert.match(html, /p_period:popularPeriod/);
assert.match(migration, /activity_date >= p\.period_start/);
assert.match(migration, /c\\.tags @> pg_catalog\\.to_jsonb\\(p_tags\\)/);
assert.match(migration, /jsonb_array_elements_text/);
assert.match(migration, /EXTRACT\(isodow FROM/);
assert.match(migration, /Asia\/Taipei/);
assert.match(migration, /AFTER INSERT OR UPDATE OF deleted_at ON public\.chat_messages/);
assert.match(migration, /AFTER INSERT OR UPDATE OF deleted_at ON public\.chat_group_messages/);
assert.match(migration, /chat_deletion_character_turn_stats|public\.get_character_turn_counts/,
  'All-time ranking must reuse the canonical cumulative assistant-turn count source.');

assert.match(html, /function renderCharacterIntroHtml/);
assert.match(html, /const dangerous=new Set\(\['SCRIPT','STYLE','IFRAME'/);
assert.match(html, /url\.protocol==='https:'/);
assert.match(html, /image\.referrerPolicy='no-referrer'/);
assert.doesNotMatch(html, /\$\{e\(replaceRoleplayVariables\(c\.intro/,
  'Full public introduction should render through the safe HTML renderer, not be escaped as plain text.');
assert.match(html, /data-action="remove-explore-tag"/,
  'Applied Explore tags must be removable without reopening the picker.');

console.log('Explore navigation, global leaderboards, safe public intro HTML, and removable tags passed.');
