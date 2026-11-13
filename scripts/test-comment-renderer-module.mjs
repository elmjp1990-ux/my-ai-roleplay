import assert from 'node:assert/strict';
import fs from 'node:fs';

const html = fs.readFileSync('index.html', 'utf8');
const moduleSource = fs.readFileSync('comment-renderer.js', 'utf8');

const moduleTag = '<script src="./comment-renderer.js"></script>';
assert.ok(html.includes(moduleTag), 'Comment renderer module must be loaded.');
assert.ok(html.indexOf(moduleTag) < html.indexOf('function renderComments()'),
  'Comment renderer must load before the app adapter.');

const start = html.indexOf('function renderComments()');
const end = html.indexOf('async function refreshAuthorFollowState', start);
assert.ok(start >= 0 && end > start && end - start < 700,
  'index.html must retain only a thin comment-renderer adapter.');
const adapter = html.slice(start, end);
assert.match(adapter, /window\.PoyozzCommentRenderer\?\.render/);
assert.match(adapter, /cloudCommentHydrationCache/);

assert.match(moduleSource, /global\.PoyozzCommentRenderer = Object\.freeze/);
assert.match(moduleSource, /render\(dependencies\)/);
for (const dependency of [
  '$', 'state', 'route', 'currentUser', 'currentCharacter',
  'author', 'avatar', 'e', 'timeText', 'cloudCommentHydrationCache'
]) {
  assert.ok(moduleSource.includes(dependency), 'Missing injected dependency: ' + dependency);
}

for (const contract of [
  'whisper-redacted-style',
  'whisper-redacted-avatar',
  'c.redacted && c.whisper',
  'state.comments[route.id]',
  'cloudCommentHydrationCache.get(cacheKey)',
  'author(parent.authorId).nickname',
  'data-action="comment-like"',
  'data-action="reply"',
  'data-action="translation"',
  'data-action="comment-menu"',
  '該筆評論已被刪除',
  '還沒有評論。'
]) {
  assert.ok(moduleSource.includes(contract), 'Comment rendering behavior is missing: ' + contract);
}

// The module is presentation-only: it must not query Supabase or mutate comment data.
assert.doesNotMatch(moduleSource, /\.from\(|\.rpc\(|\.insert\(|\.update\(|\.delete\(/);

console.log('Comment renderer extraction and presentation contract passed.');
