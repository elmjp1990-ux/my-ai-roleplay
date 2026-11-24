import assert from 'node:assert/strict';
import fs from 'node:fs';

const html = fs.readFileSync('index.html', 'utf8');
const uiStyles = fs.readFileSync('poyozz-ui.css', 'utf8');
const phoneStateMigration = fs.readFileSync('supabase/migrations/20261110120000_story_phone_state_and_memory_summary_read.sql', 'utf8');
const storyPrompt = fs.readFileSync('supabase/functions/chat-turn/index.ts', 'utf8');
const groupTurnSource = fs.readFileSync('supabase/functions/group-chat-turn/index.ts', 'utf8');
const memorySummaryWorker = fs.readFileSync('supabase/functions/_shared/story-memory-summary.ts', 'utf8');
const chatReadMigration = fs.readFileSync('supabase/migrations/20261116130000_mark_chat_session_read_and_story_chat_paging.sql', 'utf8');
const generatedStart = html.indexOf('  // Creator notice prompts guide AI generation only; never render raw instructions to players.');
const generatedEnd = html.indexOf('  const phoneHeader=', generatedStart);

assert.ok(generatedStart >= 0 && generatedEnd > generatedStart, 'Phone notification rendering block must exist');
const phoneBlock = html.slice(generatedStart, generatedEnd);

assert.match(phoneBlock, /const noticeSources=isGroup/);
assert.match(phoneBlock,/let storyWorldState=isGroup/,'group and single phone must read the same in-world state shape');
assert.ok(phoneBlock.includes('const initialStoryTime=Date.now()'),'single and group phones must initially show the current real-world time when AI time is absent');
assert.ok(phoneBlock.includes('storyWorldState.storyTime||storyWorldState.story_time||initialStoryTimeText'),'AI-provided in-world time must take precedence over the temporary real-time fallback');
assert.doesNotMatch(phoneBlock,/timeText\(item\.created_at/,'phone notifications must not render real database timestamps');
assert.match(groupTurnSource,/serializeGroupPhoneUpdatesForRpc/,'group phone updates must be serialized to SQL RPC snake_case field names');
assert.match(groupTurnSource,/story_world_state/,'group director must persist shared in-world time and location');
assert.match(groupTurnSource,/不可讀取、推測或使用系統現在時間/,'group director must never substitute current device/system time');
assert.doesNotMatch(phoneBlock, /const notices=savedNotices;/,
  'phone rows must be composed only after configured labels and AI snapshots are joined');
assert.match(phoneBlock, /const configuredRows=configuredPhonePrompts\.slice\(0,8\)\.map/,
  'configured phone labels must always render as primary rows in single and group phones');
assert.match(phoneBlock, /const stateByIndex=new Map\(storyPhoneStates\.map/,
  'AI-generated phone state must be joined to the configured field by field_index');
assert.match(phoneBlock, /const resolvePhoneFieldTitle=value=>replaceRoleplayVariables/,
  'configured {CHAR}/{USER} placeholders must be resolved before matching generated group phone titles');
assert.match(phoneBlock, /const generatedNotice=noticeByTitle\.get\(titleKey\)/,
  'configured phone rows must join generated notifications by canonical title');
assert.match(phoneBlock, /const configuredTitles=new Set\(configuredRows\.map\(item=>phoneTitleKey\(item\.title\)\)\)/,
  'configured title deduplication must use the same canonical key as generated notifications');
assert.match(phoneBlock, /!configuredTitles\.has\(phoneTitleKey\(resolvePhoneFieldTitle\(item\?\.title\|\|''\)\)\)/,
  'generated notifications already represented by configured fields must not render twice');
assert.match(phoneBlock, /generatedNotice\?\.body\|\|state\?\.body\|\|'目前尚未有更新'/,
  'configured rows must show generated content when available and a safe empty state otherwise');
assert.match(phoneBlock, /const savedNotices=\[\.\.\.noticeByTitle\.values\(\)\]/);
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
assert.match(phoneBlock, /configuredPhonePrompts\.slice\(0,8\)\.map/,'Single/group phone must always include configured display labels without exposing AI instructions');
assert.match(phoneBlock, /目前尚未有更新/,'Creator instructions must never be displayed as notification body text');
assert.match(phoneBlock, /const noticeContentHTML=\[configuredNoticeHTML,storyStateHTML,storyEventHTML\]/,
  'configured rows must appear before state snapshots and historical events');
assert.match(phoneBlock, /phoneReadErrors/, 'a failed optional phone RPC must not clear successful phone sections');
assert.match(phoneBlock, /cached\.phoneReadError/, 'per-section phone read errors must survive the short-lived cache');
assert.match(phoneBlock, /const safePhoneRpc=async\(name,args\)/, 'phone RPCs must be awaited through a rejection-safe helper because Supabase builders are thenables');
assert.match(phoneBlock, /catch\(error\)\{return \{data:null,error\};\}/, 'one rejected phone RPC must be isolated from the other reads');
assert.doesNotMatch(phoneBlock, /client\.rpc\([^\n]+\)\.catch\(/, 'do not call catch directly on Supabase thenable query builders');
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
assert.match(uiStyles, /\.phone-modal-backdrop\{[^}]*overscroll-behavior:contain/,
  'phone surface must contain touch overscroll');
assert.match(html, /data-phone-action="close">關閉<\/button>/,
  'phone close control must be labeled 關閉 rather than 完成');
assert.match(html, /function ensurePhoneModalHistoryGuard\(\)/,
  'opening the phone must add a history guard against browser-back gestures');
assert.match(html, /function closePhoneModalWithButton\(modal\)/,
  'the phone must release its history guard only through the explicit close control');
assert.match(html, /if\(document\.querySelector\('\.phone-modal-backdrop'\)\)/,
  'popstate must keep the chat route while the phone panel remains open');
assert.match(html, /if\(event\.target===modal\)return/,
  'tapping the backdrop must not dismiss the phone panel');
assert.ok(!html.includes('.phone-notice-list{max-height:'), 'Phone must not trap scrolling in a nested notice list');
assert.ok(html.includes('function firstSpokenDialoguePreview('), 'Chat preview must parse spoken dialogue separately from narration');
assert.match(html, /storyPhoneRuntimeCache\.delete\(String\(user\.uid\)\+'\:'\+session\.id\);[\s\S]*?await loadStoryMemorySummary\(session\);[\s\S]*?await renderPhoneModal\(\)/,
  'deleting/editing a Story diary entry must invalidate cached phone memory and refresh an open phone panel');
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
assert.match(html,/await markCloudChatSessionRead\(latest\)/,'Opening a conversation must use the narrow read-watermark RPC rather than a full optimistic session save');
assert.match(chatReadMigration,/CREATE OR REPLACE FUNCTION public\.mark_chat_session_read/);
assert.doesNotMatch(chatReadMigration,/SET updated_at\s*=/,'Read watermarks must not change the chat-session version timestamp');
assert.ok(html.includes("if(route.page==='conversation'&&route.id===s.id)s.lastReadAt=assistantAt"),
  'Assistant replies received while their conversation is open must be marked read');

const chatEntriesBlock=html.slice(html.indexOf('function chatEntries()'),html.indexOf('function chatListHTML()'));
assert.ok(chatEntriesBlock.includes('const lastAt=s.lastMessageAt||s.updatedAt||s.messages?.at(-1)?.at||s.startedAt'), 'Chat list must derive lastAt from the session and never reference an undefined last variable');
assert.ok(!chatEntriesBlock.includes('last?.at'), 'Chat list must not reference an undefined last variable');

console.log('Phone notification UI hides creator prompts and renders generated notices only.');

const cityMap = fs.readFileSync('city-map.js', 'utf8');
const editorStart = cityMap.indexOf('const normalizePhoneNoticeRows');
const editorEnd = cityMap.indexOf('const editorCharacterFingerprint', editorStart);
assert.ok(editorStart >= 0 && editorEnd > editorStart, 'Shared phone normalization helpers must exist in the extracted city-map module');
const editorHelpers = cityMap.slice(editorStart, editorEnd) +
  html.slice(html.indexOf('function renderPhoneSettingsFields'), html.indexOf('function saveEditorDraft()'));
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
const coreUtils = fs.readFileSync('core-utils.js', 'utf8');
assert.match(saveFlow, /classifyCharacterProfileChanges/,
  'Character save must delegate deterministic AI-impact classification to the shared pure helper');
assert.match(saveFlow, /aiOrganizationDecision/,
  'The save result must expose the deterministic AI organization decision');
assert.match(saveFlow, /aiOrganizationDecision\.requiresDerivedRefresh === true/,
  'The save flow must queue derived refresh only when the shared classifier says source content changed');
assert.match(saveFlow, /enqueue_character_profile_organization/,
  'Character save must enqueue the idempotent profile refresh instead of calling the model inline');
assert.match(saveFlow, /existingPrivateProfileError/,
  'Save must read the previous author-only personality profile before classifying changes');
assert.match(saveFlow, /verifiedPrivateInfo/,
  'Private personality and private-info fields must be read back after save');
assert.doesNotMatch(saveFlow, /chat\.completions|fetch\(.*openrouter/i,
  'Character save classification must not call the AI provider directly');

assert.match(coreUtils, /function classifyCharacterProfileChanges/,
  'Shared core utilities must own the field-level AI-impact classifier');
assert.match(coreUtils, /const changed = \(a, b\) => JSON\.stringify\(stable\(a\)\) !== JSON\.stringify\(stable\(b\)\)/,
  'Field comparison must normalize object key order before detecting changes');
assert.match(coreUtils, /const compareSource = \(key, a, b\)/,
  'Source fields must distinguish content changes from format-only changes');
assert.match(coreUtils, /const fields = \['coreTraits','values','speechStyle','behaviorRules','likes','dislikes','boundaries','relationshipPacing','occupation'\]/,
  'Personality source fields must be diffed individually');
assert.match(coreUtils, /compare\(runtime, 'phone_settings'/,
  'Phone notice instructions must be classified as runtime AI configuration changes');
assert.match(coreUtils, /compare\(nonAi, 'personality_profile\.primaryIllustrationName'/,
  'Illustration naming must remain display metadata, not a personality refresh trigger');
assert.match(coreUtils, /requiresDerivedRefresh: refresh, shouldCallModel: false/,
  'The classifier must queue only when meaningful AI source changes and never call the model during save');
assert.match(coreUtils, /model: 'deepseek\/deepseek-v4-flash-20260423'/,
  'Character data organization must retain the confirmed conversation model');
assert.match(coreUtils, /new_character_source_fields_available/);
assert.match(coreUtils, /new_character_ai_source_present/);
assert.match(coreUtils, /openingMessagePolicy: 'runtime_only_no_profile_refresh'/,
  'Opening message edits must remain runtime-only and not rebuild the derived profile');
assert.match(coreUtils, /runtimeAiChangedFields: runtime\.map/);
assert.match(coreUtils, /nonAiChangedFields: nonAi\.map/);
assert.match(coreUtils, /changedFields: ai\.map/);



assert.match(phoneBlock, /get_story_world_state/, 'Story phone must read the persisted contextual time and location');
assert.match(phoneBlock, /依開場情境推定中/, 'Story phone must show a contextual initial location fallback');
assert.match(phoneBlock, /initialStoryTimeText/, 'Story phone must show the temporary current-time fallback before the first AI turn');


// PR #256 regression coverage: preserve runtime state and use a neutral graphite phone surface.
assert.match(phoneBlock, /noticeSources=isGroup/);
assert.match(phoneBlock, /noticeByTitle/);
assert.match(phoneBlock, /Object\.values\(worldStateResult\.data\)\.some/);
assert.match(uiStyles, /\.phone-screen \{[\s\S]*?linear-gradient\(155deg,#252a31 0%,#15191e 54%,#0c0f13 100%\)/);
assert.match(uiStyles, /phone-notification-card \{[^}]*background:rgba\(155,162,172/);
console.log('PR #256 phone state preservation and graphite iPhone styling checks passed.');

assert.match(phoneBlock,/const savedNotices=\[\.\.\.noticeByTitle\.values\(\)\]/);
assert.match(html,/get_group_memory_summaries/,'Group Sweet Diary must read persisted AI summaries');
assert.match(groupTurnSource,/processDueGroupMemorySummary/,'Group turns must invoke the shared five-turn AI summary pipeline');
assert.match(memorySummaryWorker,/export async function processDueGroupMemorySummary/,'The shared worker must implement group summaries');
assert.doesNotMatch(html,/每 5 個已完成的群組回合，由 AI 整理一則/,'Group diary must not show internal batch progress or length hints');
assert.match(html,/把重要的瞬間，好好收藏/,'Group diary heading must match single Story');
assert.match(html,/目前還沒有日記產生，再多多聊天對話吧/,'Group diary uses the same no-entry message as single Story');
assert.ok(html.includes('function phoneNoticeIconPresentation(value)'), 'configured phone notice title prefixes must select their own icon');
assert.ok(html.includes("const icon=match?.[0]||'🔔'"), 'missing author icon must fall back to the bell');
assert.ok(html.includes('storyPhoneRuntimeCache.delete(String(user.uid)'), 'Story summary edit must use the scoped user id and refresh immediately');


const phoneDedupStart=html.indexOf('const phoneContentKeys=');
const phoneDedupEnd=html.indexOf('function phoneNoticeIconPresentation',phoneDedupStart);
assert.ok(phoneDedupStart>=0&&phoneDedupEnd>phoneDedupStart,'Phone content deduplication must be part of the phone rendering path');
const phoneDedup=html.slice(phoneDedupStart,phoneDedupEnd);
assert.match(phoneDedup,/normalize\('NFKC'\)/,'Phone content identity must normalize Unicode variants');
assert.ok(phoneDedup.includes("replace(/\\s+/g,' ')"),'Phone content identity must collapse actual whitespace');
assert.match(phoneDedup,/keys\.push\('body:'\+normalizedBody\)/,'Phone rows with alternate titles must still deduplicate identical meaningful bodies');
assert.match(phoneDedup,/const hasRenderedPhoneContent=/,'Phone rows must use one shared cross-source deduplication helper');
assert.match(phoneDedup,/extraStoryStates=storyPhoneStates[\s\S]*?hasRenderedPhoneContent/,'Phone state snapshots must not repeat configured notification content');
assert.match(phoneDedup,/storyEventsToShow=storyPhoneEvents\.filter[\s\S]*?hasRenderedPhoneContent/,'Phone event rows must not repeat content already shown in configured notices or state snapshots');
console.log('Phone notice/state/event cross-source duplicate-content regression checks passed.');
