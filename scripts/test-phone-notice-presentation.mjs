import assert from 'node:assert/strict';
import fs from 'node:fs';

const html = fs.readFileSync('index.html', 'utf8');
const generatedStart = html.indexOf('  // Creator notice prompts guide AI generation only; never render raw instructions to players.');
const generatedEnd = html.indexOf('  const memberSwitch=', generatedStart);

assert.ok(generatedStart >= 0 && generatedEnd > generatedStart, 'Phone notification rendering block must exist');
const phoneBlock = html.slice(generatedStart, generatedEnd);

assert.match(phoneBlock, /const generated=isGroup\?/);
assert.match(phoneBlock, /const notices=Array\.isArray\(generated\)/);
assert.match(phoneBlock, /const noticeLines=notices\.map/);
assert.match(phoneBlock, /目前還沒有新的手機通知/);
assert.doesNotMatch(phoneBlock, /noticePrompts|settings\.notices|\.\.\.prompts/, 'Creator-only notice prompts must never be rendered as player-facing phone content');

console.log('Phone notification UI hides creator prompts and renders generated notices only.');

const editorStart = html.indexOf('function normalizePhoneNoticeRows');
const editorEnd = html.indexOf('function saveEditorDraft()', editorStart);
assert.ok(editorStart >= 0 && editorEnd > editorStart, 'Structured author phone editor helpers must exist');
const editorHelpers = html.slice(editorStart, editorEnd);
assert.match(editorHelpers, /source\.slice\(0,8\)/, 'Phone editor must align with the eight-field Story contract');
assert.match(editorHelpers, /phoneDisplay/);
assert.match(editorHelpers, /phoneInstruction/);
assert.match(editorHelpers, /<span>名稱<\/span>/);
assert.match(editorHelpers, /AI 內容生成指示/);
assert.match(html, /encounterScheduleDescription:String\(values\.get\('encounterScheduleDescription'\) \|\| ''\)/,
  'Editor draft must retain the schedule field');
assert.match(html, /scheduleField\.dataset\.scheduleHydrated !== 'true'/,
  'Saving must wait for schedule hydration instead of deleting an unread existing value');
assert.match(html, /verifiedPrivateInfo/,
  'Private personality and private-info fields must be read back after save');
assert.match(html, /expectedPhonePrompts/,
  'Phone settings must be verified against the saved database row');

console.log('Character editor preserves fields 7–10 and round-trips structured eight-field phone settings.');

assert.match(html, /phoneSettingAction="add"|data-phone-setting-action="add"/,
  'Phone editor must provide a dynamic add control');
assert.match(html, /phoneSettingAction="remove"|data-phone-setting-action="remove"/,
  'Phone editor must provide a dynamic remove control');
assert.match(html, /visibleRows\.length>=8/,
  'Phone editor must cap dynamic rows at eight');

const phoneEditor = html.slice(html.indexOf('function renderPhoneSettingsFields'), html.indexOf('function saveEditorDraft()'));
assert.ok(phoneEditor.includes('<span>名稱</span>'), 'Phone notice row must label the display name');
assert.ok(phoneEditor.includes('AI 內容生成指示'), 'Phone notice row must label the AI content instruction');
assert.ok(phoneEditor.includes('visibleRows.length<=1'), 'Phone editor must retain at least one row');
assert.ok(phoneEditor.includes('visibleRows.length>=8'), 'Phone editor must cap rows at eight');
assert.ok(html.includes("primaryIllustrationName:f.get('primaryIllustrationName')"),
  'Primary illustration name must be included in the persisted personality profile');
assert.ok(html.includes('draftIllustrations=draftIllustrations.slice(0,5).map'),
  'Gallery names typed in the form must be copied to the objects passed to cloud sync');
assert.ok(html.includes('立繪名稱寫入後無法回讀'),
  'Gallery illustration names must be verified after database updates');
assert.ok(html.includes('主要立繪名稱未成功保存'),
  'Primary illustration name must be verified after database updates');
assert.ok(html.includes("replace(/^#+/u,'' )") || html.includes("replace(/^#+/u,'')"),
  'Leading hash characters must be stripped before storing tags');
assert.ok(html.includes('normalizeCharacterTagsForRead'),
  'Legacy tags must be normalized on cloud read as well as save');

console.log('Character editor: dynamic phone rows, illustration-name round-trip, and hashtag normalization checks passed.');

const saveStart = html.indexOf('async function saveSupabaseCharacter');
const saveEnd = html.indexOf('const stablePersonaJson', saveStart);
assert.ok(saveStart >= 0 && saveEnd > saveStart, 'Character cloud-save flow must remain identifiable');
const saveFlow = html.slice(saveStart, saveEnd);
assert.match(saveFlow, /select\('name, intro, race, style, tags, phone_settings, visibility/,
  'Save must load the previous AI source fields before writing');
assert.match(saveFlow, /existingPrivateProfileError/,
  'Save must read the previous author-only personality profile before diffing');
assert.match(saveFlow, /characterValueChanged/,
  'Save must compare normalized old/new values rather than triggering on every save');
assert.match(saveFlow, /aiRelevantChanges/,
  'Save must maintain a separate list of AI-impacting field changes');
assert.match(saveFlow, /nonAiChanges/,
  'Save must distinguish display/configuration changes from AI source changes');
assert.match(saveFlow, /reason: isNewCharacter \? 'new_character'/,
  'New characters must be marked for initial AI organization review');
assert.match(saveFlow, /model: 'deepseek\/deepseek-v4-flash-20260423'/,
  'Character data organization must use the confirmed conversation model');
assert.match(saveFlow, /shouldCallModel: false/,
  'This change must classify only; it must not call the model during this phase');
assert.match(saveFlow, /aiOrganizationDecision/ ,
  'The save result must expose the deterministic AI organization decision');
assert.doesNotMatch(saveFlow, /chat\.completions|fetch\(.*openrouter/i,
  'Character save classification must not call the AI provider directly');


assert.match(saveFlow, /runtimeAiChanges/,
  'Phone notice instructions must be classified as runtime AI configuration changes');
assert.match(saveFlow, /runtimeAiChangedFields/,
  'Save result must expose runtime AI configuration changes separately');
assert.match(saveFlow, /requiresDerivedRefresh: isNewCharacter \|\| aiRelevantChanges\.length > 0/,
  'Only new characters or changed source/personality fields should require derived-data refresh');
assert.match(saveFlow, /primaryIllustrationName/,
  'Primary illustration naming must be treated as display metadata, not personality content');
assert.match(saveFlow, /aiProfileFields/,
  'Personality profile fields must be diffed individually instead of as one opaque object');
assert.doesNotMatch(saveFlow, /compareCharacterField\('phone_settings'.*false/,
  'Phone instructions must not be mislabeled as non-AI changes');

console.log('Character save performs deterministic AI-impact diffing without invoking the model.');

