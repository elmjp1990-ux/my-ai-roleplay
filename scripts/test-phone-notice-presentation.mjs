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
assert.match(phoneEditor, /<span>名稱<\\/span>/, 'Phone notice row must label the display name');
assert.match(phoneEditor, /AI 內容生成指示/, 'Phone notice row must label the AI content instruction');
assert.match(phoneEditor, /visibleRows\\.length<=1/, 'Phone editor must retain at least one row');
assert.match(phoneEditor, /visibleRows\\.length>=8/, 'Phone editor must cap rows at eight');
assert.match(html, /primaryIllustrationName:f\\.get\\('primaryIllustrationName'\\)/,
  'Primary illustration name must be included in the persisted personality profile');
assert.match(html, /draftIllustrations=draftIllustrations\\.slice\\(0,5\\)\\.map/,
  'Gallery names typed in the form must be copied to the objects passed to cloud sync');
assert.match(html, /立繪名稱寫入後無法回讀/,
  'Gallery illustration names must be verified after database updates');
assert.match(html, /主要立繪名稱未成功保存/,
  'Primary illustration name must be verified after database updates');
assert.match(html, /replace\\(\\/\\^#\\+\\/u,''\\)/,
  'Leading hash characters must be stripped before storing tags');
assert.match(html, /normalizeCharacterTagsForRead/,
  'Legacy tags must be normalized on cloud read as well as save');

console.log('Character editor: dynamic phone rows, illustration-name round-trip, and hashtag normalization checks passed.');
