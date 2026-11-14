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
assert.match(html, /不會呼叫 AI，也不會扣款/, 'preset picker must explain that selection is local and free');
assert.doesNotMatch(presetSource, /fetch\s*\(|createSignedUrl|supabase|openrouter/i, 'preset asset must not make network or AI requests');

assert.match(pagination, /groupCharacterPicker:10/, 'group character picker page size must remain ten');
assert.match(html, /載入更多公開角色（每次 10 位）/, 'group picker must disclose its ten-item page size');

assert.match(html, /let groupCharacterIntroExpandedId = null/, 'character introductions must start collapsed');
assert.match(html, /data-action="group-toggle-character-intro"/, 'character name must expose an intro toggle');
assert.ok(html.includes("group-character-intro '+(expanded?'':'hidden')+'"), 'character intro must be hidden until expanded');

assert.match(html, /value="__player_custom__"/, 'group world choices must include player-defined background');
assert.match(html, /id="groupCustomWorldBackground" maxlength="3000" data-count-for="groupCustomWorldBackground"/, 'custom world field must be limited to 3000 characters and counted');
assert.match(html, /可以自行填入時空背景/, 'custom world option must show its helper copy');
assert.match(html, /world_character_id:g\.draft\.worldCharacterId==='__player_custom__'\?null:g\.draft\.worldCharacterId/, 'custom world must save without a character foreign-key reference');
assert.match(html, /g\.draft\.worldCharacterId==='__player_custom__'[\s\S]{0,260}最多 3000 字/, 'custom world text must be validated at 3000 characters');

assert.match(html, /\[data-action="pin"\][\s\S]{0,280}stopImmediatePropagation\(\)/, 'pin click must be isolated before other delegated actions');
const pinHelper = html.slice(html.indexOf('async function toggleChatSessionPin'), html.indexOf('/* Isolate chat-list pin clicks'));
assert.ok(pinHelper.includes('item.pinned=!previousPinned'), 'pin helper must toggle the pinned state');
assert.ok(!pinHelper.includes('confirmChatMessageDeletion'), 'pin helper must never request message deletion confirmation');

console.log('Group creation UI, 10-item pagination, static inspiration, and chat-list pin isolation checks passed.');
