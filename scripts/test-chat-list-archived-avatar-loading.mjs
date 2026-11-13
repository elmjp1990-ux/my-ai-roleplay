import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const encounter = readFileSync(new URL('../encounter-scene.js', import.meta.url), 'utf8');

function between(source, start, end) {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from + start.length);
  assert.notEqual(from, -1, `missing start: ${start}`);
  assert.ok(to > from, `missing end: ${end}`);
  return source.slice(from, to);
}

test('chat list query reads only the snapshot image path, not the Base64 image payload', () => {
  const loader = between(html, 'async function loadCloudChatSessions(user, options = {})', 'async function ');
  assert.match(loader, /character_snapshot_image_path:character_snapshot->>imagePath/);
  assert.match(loader, /imagePath:row\.character_snapshot_image_path\|\|''/);
  assert.doesNotMatch(loader, /character_snapshot_image\s*:/);
  assert.doesNotMatch(loader, /character_snapshot->>image\b/);
});

test('chat list avatars use an identity placeholder until the exact snapshot path is signed', () => {
  const list = between(html, 'function chatEntries() {', 'function chatListHTML()');
  assert.match(list, /data-chat-avatar-session-id=/);
  assert.match(list, /data-chat-avatar-path=/);
  assert.match(list, /avatar-fallback/);
  assert.doesNotMatch(list, /<img class="avatar" src="\$\{e\(safeImage\(c\.image\)\)\}" alt=/);
});

test('archived chat avatar hydration is visibility-lazy and updates only the matching session/path', () => {
  const hydration = between(html, 'function applyCloudChatSessionAvatarUrl(session,url)', 'function canAccessSessionCharacter(s,c)');
  assert.match(hydration, /IntersectionObserver/);
  assert.match(hydration, /root:list,rootMargin:'120px 0px'/);
  assert.match(hydration, /node\.dataset\.chatAvatarSessionId!==session\.id/);
  assert.match(hydration, /node\.dataset\.chatAvatarPath!==\(session\.cloudCharacterSnapshot\?\.imagePath\|\|''\)/);
  assert.match(hydration, /image\.dataset\.characterIllustrationPath=session\.cloudCharacterSnapshot\.imagePath/);
});

test('offline styling remains attached to the character avatar wrapper', () => {
  const list = between(html, 'function chatEntries() {', 'function chatListHTML()');
  assert.match(list, /character-avatar-status \$\{characterIsOffline\(c\)\?'is-offline':''\}/);
  assert.match(list, /character-status-dot/);
});

test('encounter still requests only the first gallery illustration and reports authorization failures', () => {
  const loader = between(html, 'async function hydrateEncounterGalleryIllustration(characterId)', 'async function refreshCharacterIllustrationSignedUrl');
  assert.match(loader, /\.eq\('asset_type','gallery'\)/);
  assert.match(loader, /\.limit\(1\)/);
  assert.match(loader, /讀取相遇立繪資料失敗/);
  assert.match(encounter, /hydrateEncounterGalleryIllustration\(character\.id\)/);
  assert.match(encounter, /角色立繪暫時無法載入/);
});

test('hidden and deleted characters prefer their own chat snapshot portrait over current card art', () => {
  const sessionCharacter = between(html, 'function sessionCharacter(s) {', 'async function hydrateCloudSessionCharacterImage(s)');
  assert.match(sessionCharacter, /hasMatchingSnapshot&&characterIsOffline\(found\)/);
  assert.match(sessionCharacter, /image:snap\.imagePath \? \(snap\.image \|\| hydratedImage \|\| ''\)/);
  const hydration = between(html, 'async function hydrateCloudSessionCharacterImage(s)', 'function applyCloudChatSessionAvatarUrl(session,url)');
  assert.doesNotMatch(hydration, /liveCharacter\?\.image/);
});


test('legacy archived chat avatars hydrate only when visible and only from the owned session snapshot', () => {
  const hydration = between(html, 'async function hydrateCloudSessionCharacterImage(s)', 'function applyCloudChatSessionAvatarUrl(session,url)');
  assert.match(hydration, /legacy-snapshot-image/);
  assert.match(hydration, /\.select\('snapshot_id:character_snapshot->>id,snapshot_image:character_snapshot->>image'\)/);
  assert.match(hydration, /\.eq\('id',s\.id\)\.eq\('user_id',uid\)\.is\('deleted_at',null\)/);
  assert.match(hydration, /data\?\.snapshot_id!==s\.characterId/);
  assert.match(hydration, /safeImage\(data\?\.snapshot_image\)/);
  assert.match(hydration, /state\.sessions\?\.\[s\.id\]!==s/);
  const observer = between(html, 'function observeCloudChatSessionAvatars(root=', 'function canAccessSessionCharacter(s,c)');
  assert.match(observer, /list\.querySelectorAll\('\[data-chat-avatar-session-id\]'\)/);
});

test('legacy snapshot hydration does not fetch Base64 for every chat in the initial list query', () => {
  const loader = between(html, 'async function loadCloudChatSessions(user, options = {})', 'async function ');
  assert.doesNotMatch(loader, /character_snapshot_image\s*:/);
  assert.doesNotMatch(loader, /character_snapshot\s*[,)]/);
  const list = between(html, 'function chatEntries() {', 'function chatListHTML()');
  assert.match(list, /s\.cloudOwned\)\?'<span class="avatar avatar-fallback" data-chat-avatar-session-id=/);
});

test('PR 249 preserves the guest NSFW age gate from PR 250', () => {
  const guard = between(html, 'function canViewCharacterNsfw(character)', 'function availableExploreTags()');
  assert.match(guard, /if \(!uid\) return false;/);
  assert.match(guard, /return currentUserCanViewNsfw\(\);/);
  assert.doesNotMatch(guard, /cloudPublic\s*===\s*true/);
});
