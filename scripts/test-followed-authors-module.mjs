import assert from 'node:assert/strict';
import fs from 'node:fs';

const html = fs.readFileSync('index.html', 'utf8');
const moduleSource = fs.readFileSync('followed-authors.js', 'utf8');

const moduleTag = '<script src="./followed-authors.js"></script>';
assert.ok(html.includes(moduleTag), 'Followed authors module must be included in the page.');
assert.ok(html.indexOf(moduleTag) < html.indexOf('function renderFollowedAuthors()'),
  'Followed authors module must load before the app adapter can invoke it.');
const adapterStart = html.indexOf('async function renderFollowedAuthors()');
const charactersStart = html.indexOf('/* Characters */', adapterStart);
assert.ok(adapterStart >= 0 && charactersStart > adapterStart && charactersStart - adapterStart < 900,
  'index.html must retain only a thin followed-authors adapter.');
assert.match(html.slice(adapterStart, charactersStart), /window\.PoyozzFollowedAuthors\?\.render/);

assert.match(moduleSource, /global\.PoyozzFollowedAuthors = Object\.freeze/);
assert.match(moduleSource, /async render\(dependencies\)/);
assert.doesNotMatch(moduleSource, /async function render\(dependencies\)/);
for (const dependency of [
  '$', 'currentUser', 'getRoute', 'getSupabaseClient', 'isUuid', 'state',
  'loadPublicAuthorLatestCharacters', 'author', 'ICON', 'e', 'avatar', 'card', 'persist', 'toast'
]) {
  assert.ok(moduleSource.includes(dependency), 'App-owned dependency must be explicit: ' + dependency);
}
for (const contract of [
  "from('author_follows')", "from('public_profiles')",
  "eq('follower_id',current.userId)", "order('created_at',{ascending:false})",
  "getRoute()?.page !== 'followed-authors'", "公開角色 '+entry.total+' 名",
  '你還沒有追蹤任何作者。', '讀取失敗，請重新整理後再試。'
]) {
  assert.ok(moduleSource.includes(contract), 'Followed authors behavior is missing: ' + contract);
}
assert.doesNotMatch(moduleSource, /window\.mySupabase/,
  'The extracted module must receive the Supabase client through dependency injection.');

console.log('Followed authors module extraction and dependency contract passed.');
