import assert from 'node:assert/strict';
import fs from 'node:fs';

const html = fs.readFileSync('index.html', 'utf8');
const moduleSource = fs.readFileSync('author-profile.js', 'utf8');

const moduleTag = '<script src="./author-profile.js"></script>';
assert.ok(html.includes(moduleTag), 'Author profile module must be included in the page.');
assert.ok(html.indexOf(moduleTag) < html.indexOf('function renderAuthor()'),
  'Author profile module must load before the app adapter can invoke it.');

const adapterStart = html.indexOf('function renderAuthor()');
const favoritesStart = html.indexOf('function renderFavorites()', adapterStart);
assert.ok(adapterStart >= 0 && favoritesStart > adapterStart && favoritesStart - adapterStart < 900,
  'index.html must retain only a thin author-profile adapter.');
const adapter = html.slice(adapterStart, favoritesStart);
assert.match(adapter, /window\.PoyozzAuthorProfile\?\.render/);
assert.match(adapter, /getSupabaseClient:\(\) => window\.mySupabase/);

assert.match(moduleSource, /global\.PoyozzAuthorProfile = Object\.freeze/);
assert.match(moduleSource, /render\(dependencies\)/);
assert.doesNotMatch(moduleSource, /window\.mySupabase/,
  'The extracted module must receive Supabase access through dependency injection.');

for (const dependency of [
  'route', 'state', 'currentUser', 'author', 'isUuid', 'getSupabaseClient',
  'publicAuthorProfileLoaded', 'hydratePublicAuthorProfile',
  '$', 'e', 'avatar', 'card', 'refreshAuthorFollowState'
]) {
  assert.ok(moduleSource.includes(dependency), 'App-owned dependency must be explicit: ' + dependency);
}

for (const contract of [
  "state.following.includes(a.uid)",
  "c.visibility === 'public'",
  "c.cloudPublic !== false",
  "c.localOnly !== true",
  'id="authorFollowerCount"',
  'data-action="follow"',
  'data-action="share"',
  '公開角色',
  '目前沒有公開角色。'
]) {
  assert.ok(moduleSource.includes(contract), 'Author profile behavior is missing: ' + contract);
}

console.log('Author profile module extraction and dependency contract passed.');
