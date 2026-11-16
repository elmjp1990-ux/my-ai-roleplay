import assert from 'node:assert/strict';
import fs from 'node:fs';

const html = fs.readFileSync('index.html', 'utf8');
const uiStyles = fs.readFileSync('poyozz-ui.css', 'utf8');
const phoneStateMigration = fs.readFileSync('supabase/migrations/20261110120000_story_phone_state_and_memory_summary_read.sql', 'utf8');
const storyPrompt = fs.readFileSync('supabase/functions/chat-turn/index.ts', 'utf8');
const generatedStart = html.indexOf('  // Creator notice prompts guide AI generation only; never render raw instructions to players.');
const generatedEnd = html.indexOf('  const phoneHeader=', generatedStart);

assert.ok(generatedStart >= 0 && generatedEnd > generatedStart, 'Phone notification rendering block must exist');
const phoneBlock = html.slice(generatedStart, generatedEnd);

assert.match(phoneBlock, /const generated=isGroup\?/);
assert.match(phoneBlock, /const savedNotices=Array.isArray\(generated\)/);
assert.match(phoneBlock, /const noticeLines=notices\.map/);
assert.match(phoneBlock, /get_story_phone_state/, 'Story phone must load current configured field state separately');
assert.match(phoneBlock, /get_story_phone_events/, 'Story phone must load genuine event history separately');
assert.match(phoneBlock, /storyStateHTML/, 'Story phone must render current field snapshots in a dedicated section');
assert.match(phoneBlock, /const noticeContentHTML=/, 'Phone notifications and genuine Story events must share one notification section');
assert.doesNotMatch(phoneBlock, /📨 故事新通知/, 'Phone must not render a duplicate Story notification heading');
assert.match(phoneBlock, /storyEventHTML/, 'Story phone must include genuine events in the unified notification list');
assert.match(phoneStateMigration, /CREATE TABLE IF NOT EXISTS public\.story_phone_states/);
assert.match(phoneStateMigration, /ON CONFLICT \(session_id, field_index\) DO UPDATE/);
assert.match(phoneStateMigration, /IS DISTINCT FROM EXCLUDED\.body/,
  'Unchanged phone field values must not be refreshed on every turn');
assert.match(phoneStateMigration, /e\.event_type <> 'notification'/,
  'Replaceable status snapshots must be hidden from historical event output');
assert.match(storyPrompt, /每個手機欄位的 body 必須以簡短的一行為主/);
assert.match(storyPrompt, /沒有新資訊或劇情變化時，原樣延續最近狀態/);
assert.match(phoneBlock, /目前還沒有新的通知/);
assert.match(phoneBlock, /configuredPhonePrompts\.slice\(0,8\)\.map/,'Group phone may use configured notice labels only as display titles when no generated notice exists');
assert.match(phoneBlock, /body:'目前尚未有更新'/,'Creator instructions must never be displayed as notification body text');
assert.doesNotMatch(phoneBlock, /body:String\(row\)|body:row/,'Raw creator instructions must never be rendered as player-facing notification bodies');

assert.ok(html.includes('session.storyWorldState'), 'Phone must read the latest saved story-world state');
assert.ok(html.includes('故事時間尚未確認'), 'Unknown story time must remain explicitly unknown rather than use a hard-coded clock');
assert.ok(!html.includes('星期五　🕧 19:30'), 'Phone must not show a hard-coded fictional time');
assert.ok(uiStyles.includes('overflow-y:auto;overflow-x:hidden'), 'Phone content body must scroll independently in the extracted UI stylesheet');
assert.match(uiStyles, /\.phone-device-head\{[^}]*flex-shrink:0/);
assert.match(uiStyles, /\.phone-member-switch\{[^}]*flex-shrink:0/);
assert.match(uiStyles, /\.phone-bar\{[^}]*flex-shrink:0/);
assert.match(uiStyles, /\.phone-close-row\{[^}]*flex-shrink:0/,
  'Phone header, member switch, bar, and close control must remain fixed');
assert.ok(!html.includes('.phone-notice-list{max-height:'), 'Phone must not trap scrolling in a nested notice list');
assert.ok(html.includes('function firstSpokenDialoguePreview('), 'Chat preview must parse spoken dialogue separately from narration');
assert.ok(html.includes('角色暫時沒有對白'), 'Narration-only replies must use the no-dialogue fallback');
assert.ok(html.includes('function latestAssistantPreview('), 'Chat preview must select the latest assistant message');
assert.match(html, /latestAssistantSuggestionMessage/,
  'Cloud roleplay metadata must identify the latest assistant message with suggestions');
assert.match(html, /message === latestAssistantSuggestionMessage/,
  'Cloud roleplay metadata must persist suggestions on the exact latest assistant message');
assert.match(html, /latestAssistantSuggestions/,
  'Cloud hydration must restore suggestions from the latest assistant turn before session fallback');
assert.match(html, /suggestedReplies:message\.suggestedReplies\.slice\(0,3\)/,
  'Assistant-turn suggestion metadata must be bounded to three options');
assert.ok(html.includes('const preview=latestAssistantPreview(s)'), 'Single-chat list must not use the latest player message or narration');
assert.ok(html.includes('firstSpokenDialoguePreview(item.preview.content)'), 'Group previews must also strip narration');
assert.ok((html.includes('if(s.activeTurnInFlight)') || html.includes('if (s.activeTurnInFlight)') || html.includes('if(s.pendingTurn)') ) && html.includes('正在回覆'), 'Transient active turn must display a character reply indicator');
assert.ok(html.includes('typing-dots') && html.includes('po-typing'), 'Reply indicator must animate its ellipsis');
assert.ok(!html.includes('🟢'), 'Reply indicator must not add a redundant green status dot');

assert.ok(html.includes("return value||'你有新訊息'"), 'Narration-only assistant replies must show the new-message fallback');
assert.ok(html.includes("return session?.cloudMessagesLoaded===false?'點擊載入最近訊息':'你有新訊息'"),
  'Missing spoken dialogue must never fall back to narration');
assert.ok(html.includes('lastAssistantMessageAt') && html.includes('lastReadAt'), 'Unread state must track assistant messages and read watermark');
assert.ok(html.includes('chat-unread-pill') && html.includes('新訊息'), 'Unread sessions must show the compact new-message pill');
assert.ok(html.includes('if(isConversationEntry)') && html.includes('saveChatSessionSafely(s)'), 'Opening a conversation must mark it read and sync its watermark');
assert.ok(html.includes("if(route.page==='conversation'&&route.id===s.id)s.lastReadAt=assistantAt"),
  'Assistant replies received while their conversation is open must be marked read');

const chatEntriesBlock=html.slice(html.indexOf('function chatEntries()'),html.indexOf('function chatListHTML()'));
assert.ok(chatEntriesBlock.includes('const lastAt=s.lastMessageAt||s.updatedAt||s.messages?.at(-1)?.at||s.startedAt'), 'Chat list must derive lastAt from the session and never reference an undefined last variable');
assert.ok(!chatEntriesBlock.includes('last?.at'), 'Chat list must not reference an undefined last variable');

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
assert.match(saveFlow, /new_character_source_fields_available/,
  'New characters with no meaningful AI source fields must not trigger model organization');
assert.match(saveFlow, /new_character_ai_source_present/,
  'New characters with populated AI source fields may require derived organization');
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
assert.match(saveFlow, /const requiresDerivedRefresh = aiRelevantChanges\.length > 0/,
  'Derived refresh must be triggered only by meaningful AI source/personality fields');
assert.match(saveFlow, /compareCharacterField\(nonAiChanges, 'name'/,
  'Character renaming must be treated as metadata and must not trigger model organization');
assert.match(saveFlow, /primaryIllustrationName/,
  'Primary illustration naming must be treated as display metadata, not personality content');
assert.match(saveFlow, /aiProfileFields/,
  'Personality profile fields must be diffed individually instead of as one opaque object');
assert.doesNotMatch(saveFlow, /compareCharacterField\('phone_settings'.*false/,
  'Phone instructions must not be mislabeled as non-AI changes');

console.log('Character save performs deterministic AI-impact diffing without invoking the model.');


assert.match(phoneBlock, /get_story_world_state/, 'Story phone must read the persisted contextual time and location');
assert.match(phoneBlock, /依開場情境推定中/, 'Story phone must show a contextual initial location fallback');
assert.match(phoneBlock, /initialStoryTimeText/, 'Story phone must show the session start time before the first AI turn');
