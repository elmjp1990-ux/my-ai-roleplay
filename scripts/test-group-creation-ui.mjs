import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const pagination = fs.readFileSync(new URL('../list-pagination.js', import.meta.url), 'utf8');
const presetSource = fs.readFileSync(new URL('../group-opening-presets.js', import.meta.url), 'utf8');

const window = {};
vm.runInNewContext(presetSource, { window, Object });
const presets = window.PoyozzGroupOpeningPresets;

assert.equal(presets.length, 100, 'exactly 100 static group opening presets must be available');
assert.equal(new Set(presets.map(item => item.id)).size, 100, 'preset IDs must be unique');
assert.ok(presets.every(item => item.title && item.category && item.text), 'every preset needs a category, title, and text');
assert.match(html, /\.\/group-opening-presets\.js/, 'preset asset must be loaded by the page');
assert.match(html, /data-action="group-inspiration">✨ AI靈感/, 'group inspiration must be a one-click AI-style button');
assert.match(html, /Math\.random\(\)/, 'group inspiration must randomly apply a preset without showing a selection dialog');
assert.match(html, /function groupOpeningRoleIntro\(members,userName\)/, 'group inspiration must use a dedicated natural-opening helper');
assert.match(html, /oneRoleOpeners=\[/, 'single-role inspiration must have varied opening styles');
assert.match(html, /twoRoleOpeners=\[/, 'two-role inspiration must have varied opening styles');
assert.match(html, /threeRoleOpeners=\[/, 'three-role inspiration must have varied opening styles');
assert.match(html, /groupOpeningRoleIntro\(members,userName\)/, 'inspiration must select a natural opener based on formal member count');
assert.doesNotMatch(presetSource, /fetch\s*\(|createSignedUrl|supabase|openrouter/i, 'preset asset must not make network or AI requests');

assert.match(pagination, /groupCharacterPicker:10/, 'group character picker page size must remain ten');
assert.match(html, /載入更多公開角色（每次 10 位）/, 'group picker must disclose its ten-item page size');
assert.match(html, /function groupCharacterPickerAvatar\(character\)/, 'group picker must render a safe initial fallback when an avatar URL is missing');
assert.match(html, /loadCharacterPrimaryIllustrationAssets\(missingImageItems\.map\(character=>character\.id\)\)/, 'group picker must hydrate only missing primary portraits with signed URLs');

assert.match(html, /let groupCharacterIntroExpandedId = null/, 'character introductions must start collapsed');
assert.match(html, /data-action="group-toggle-character-intro"/, 'character name must expose an intro toggle');
assert.ok(html.includes("group-character-intro '+(expanded?'':'hidden')+'"), 'character intro must be hidden until expanded');

assert.match(html, /value="__player_custom__"/, 'group world choices must include player-defined background');
assert.match(html, /id="groupWorldBackground" maxlength="3000" data-count-for="groupWorldBackground"/, 'the single group background field must be limited to 3000 characters and counted');
assert.doesNotMatch(html, /groupCustomWorldBackground/, 'group background must not render a second custom textarea');
assert.match(html, /清空下方背景框/, 'custom world option must clear the shared background field');
assert.match(html, /worldCharacterIdForSave=g\.draft\.worldCharacterId==='__player_custom__'\?null:g\.draft\.worldCharacterId/, 'custom world must be normalized before the asynchronous group create flow');
assert.match(html, /world_character_id:worldCharacterIdForSave/, 'custom world must save without a character foreign-key reference');
assert.match(html, /if\(g\.draft\.world\.length>3000\)return '群組背景最多 3000 字。'/, 'all group background text must be validated at 3000 characters');

assert.match(html, /data-chat-list-pin="single"/, 'single-chat pin must have a dedicated isolated target');
assert.match(html, /data-chat-list-pin="group"/, 'group-chat pin must have a dedicated isolated target');
assert.match(html, /\[data-chat-list-pin\][\s\S]{0,420}stopImmediatePropagation\(\)/, 'both pin clicks must be isolated before delete/menu delegation');
const pinHelper = html.slice(html.indexOf('async function toggleChatSessionPin'), html.indexOf('/* Isolate chat-list pin clicks'));
assert.ok(pinHelper.includes('item.pinned=!previousPinned'), 'pin helper must toggle the pinned state');
assert.ok(!pinHelper.includes('confirmChatMessageDeletion'), 'pin helper must never request message deletion confirmation');
assert.doesNotMatch(pinHelper, /cloudRow\.updated_at!==expectedUpdatedAt/, 'pin sync must compare against the freshly-read cloud version, not stale local metadata');

const groupTurn = fs.readFileSync(new URL('../supabase/functions/group-chat-turn/index.ts', import.meta.url), 'utf8');
assert.ok(html.includes("const initialOpening=String(initialScene?.description||'').trim()"), 'group chat must read the saved initial scene description');
assert.ok(html.includes('const initialOpeningRow=initialOpening && !g.historyHasMore'), 'group chat must render the original opening before the earliest loaded messages, not above a recent partial page');
assert.match(html,/function groupOpeningDraftKey\(/,'group opening draft must have an account-scoped recovery key');
assert.match(html,/localStorage\.setItem\(key,JSON\.stringify\(\{text,savedAt:Date\.now\(\)\}\)\)/,'group opening draft must be persisted while typing and survive app switching');
assert.match(html,/document\.addEventListener\('visibilitychange'/,'group opening draft must be synchronized when the app is backgrounded');
assert.match(html,/初始開場情境最多 1000 字/,'group opening scene must be limited to 1000 characters');
assert.match(html,/renderGroupOpeningContent\(initialOpening,roleplayRoles\)/,'opening text must parse star narration and speaker prefixes');
const groupConversation=html.slice(html.indexOf('function renderGroupConversation()'),html.indexOf('async function groupOpen('));
assert.doesNotMatch(groupConversation,/avatar-fallback">序|message-name">初始開場情境/,'group initial opening must not render an avatar or title/name frame');
assert.match(html,/function conversationTypingIndicatorHTML\(\)/,'group and single chat must share the same reply animation');
assert.match(html,/loadCharacterPrimaryIllustrationAssets\(missingImageItems\.map\(character=>character\.id\)\)/,'group picker must pass only missing character IDs to the shared primary-illustration batch loader');
assert.match(html,/characterIllustrationSignedUrlManager\.get\(row\.storage_path\)/,'a failed batch of portrait URLs must fall back to each individual character image');
assert.match(html,/maxlength="2000" data-max-count="1000"/,'group initial opening textarea must enforce a 1000-codepoint maximum while allowing surrogate pairs');
assert.ok(html.includes('const messageRows=initialOpeningRow+g.messages.map'), 'opening display must be prepended without inserting a duplicate chat message');
assert.ok(html.includes("if(!typedContent && !(g.messages||[]).length)"), 'empty first send must not start a paid AI turn');
assert.ok(html.includes("💎 本群組每次對話 '+(groupPrototype.draft.memberIds.length*3)+' 鑽石（每加一位角色3鑽石）。"), 'group picker must show the requested per-turn cost wording');
assert.ok(html.includes('padding:17px 12px')&&html.includes('min-height:88px'), 'chat-list cards must be visibly enlarged, not only slightly spaced');
assert.ok(html.includes('grid-template-columns:280px minmax(0,1fr)'), 'desktop chat list column must be widened');
const groupCreateStart = html.indexOf('async function groupCreate()');
const groupCreateEnd = html.indexOf('\nfunction groupBack()', groupCreateStart);
const groupCreateSource = html.slice(groupCreateStart, groupCreateEnd);
for (const forbidden of ['functions.invoke', 'group-chat-turn', 'walletPreflight', 'reserve_group_chat_turn']) {
  assert.ok(!groupCreateSource.includes(forbidden), 'group creation must not call AI or reserve wallet funds: ' + forbidden);
}
assert.ok(groupTurn.includes('const initialOpeningContext = (sceneResult.data || []).map'), 'group AI must load original scene descriptions');
assert.ok(groupTurn.includes('serializeGroupPhoneUpdatesForRpc') && groupTurn.includes('story_world_state'), 'group AI must persist phone data using the RPC contract and return game world state');
assert.ok(groupTurn.includes('不可讀取、推測或使用系統現在時間'), 'group AI game time must never be derived from real device time');
const groupMigration=fs.readFileSync(new URL('../supabase/migrations/20261116064526_group_story_world_state_and_opening_limit.sql',import.meta.url),'utf8');
assert.match(groupMigration,/chat_group_scenes_description_max_1000/,'database group scene constraint must enforce the 1000-character opening limit');
assert.match(groupMigration,/CREATE OR REPLACE FUNCTION public\.get_active_character_tags/,'unused tags must be checked against authoritative active-character usage');
assert.ok(groupTurn.includes('【玩家設定的初始開場情境】'), 'group AI system prompt must include the original opening context');
assert.ok(groupTurn.includes('AI 只在玩家送出第一則訊息後才回覆'), 'group AI prompt must only respond after the player sends a message');

console.log('Group creation UI, 10-item pagination, static inspiration, chat-list pin isolation, and free initial group opening checks passed.');
