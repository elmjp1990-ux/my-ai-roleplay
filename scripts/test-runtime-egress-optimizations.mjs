import assert from "node:assert/strict";
import fs from "node:fs";

const html=fs.readFileSync("index.html","utf8");
const between=(start,end)=>{
  const from=html.indexOf(start),to=html.indexOf(end,from+start.length);
  assert.notEqual(from,-1,"missing source block: "+start);
  assert.notEqual(to,-1,"missing end marker: "+end);
  return html.slice(from,to);
};

const turn=between("async function executePendingChatTurn(s)","function toast(text)");
assert.doesNotMatch(turn,/await loadStoryRelationshipState\(s\)/,
  "settled Story turns must not fetch relationship state a second time after render");
assert.match(turn,/storyPhoneRuntimeCache\.delete\(String\(user\.uid\|\|''\)\+':'\+s\.id\)/,
  "a settled Story turn must invalidate the in-memory phone state cache");

const conversation=between("function renderConversation()","function formatMessage");
assert.match(conversation,/if \(s\.storyMode\) void loadStoryRelationshipState\(s\)/,
  "the relationship meter must still refresh through the normal render path");

const groupOpen=between("async function groupOpen(groupId)","async function openGroupBackgroundSettings");
assert.match(groupOpen,/const groupListWasLoaded=g\.groupsLoaded===true/);
assert.match(groupOpen,/if\(groupListWasLoaded\)\{/);
assert.match(groupOpen,/g\.groupMembers\[group\.id\]/);
assert.match(groupOpen,/archived_at/);
assert.match(groupOpen,/if\(group\.archived_at\)/,
  "opening an archived group must not reinsert it into the visible list");
assert.doesNotMatch(groupOpen,/void groupLoadList\(true\)/,
  "opening a group must not force a full group-list/member/preview reload");

assert.match(groupOpen,/\.order\('created_at',\{ascending:false\}\).*\.limit\(50\)/,
  "opening a group must fetch only the newest bounded page in reverse chronological query order");
assert.match(groupOpen,/oldestInitialMessage=initialMessageRows\.at\(-1\)/,
  "the first page must retain a stable cursor at its oldest fetched row");
const groupHistory=between("async function groupLoadOlderMessages()","async function openGroupBackgroundSettings");
assert.ok(groupHistory.includes("const oldest=page.at(-1);"),
  "the next cursor must use the oldest row in the descending page to avoid skipping messages");
assert.match(groupHistory,/\.or\(olderFilter\)/,
  "older pages must use a keyset cursor instead of offset pagination");
assert.match(groupHistory,/\.order\('id',\{ascending:false\}\)\.limit\(50\)/,
  "older pages must use a deterministic tie-breaker and a fixed page size");
assert.match(groupHistory,/existing=new Set/,
  "overlapping page results must not duplicate already loaded messages");
assert.match(groupHistory,/historyScrollAnchor=before/,
  "loading older messages must preserve the reader's scroll position");
assert.match(html,/data-action="group-history-load-older"/,
  "the group conversation must expose a control for loading older history");
assert.match(html,/case 'group-history-load-older':groupLoadOlderMessages\(\);break;/,
  "the delegated action handler must load older group messages");

const groupSend=between("async function groupSendTurn()","async function groupRefreshList()");
assert.match(groupSend,/functions\.invoke\('group-chat-turn'/,"group sends must use the server-authoritative AI Edge Function");
assert.match(groupSend,/requestKey,content/,"group sends must reuse a stable idempotency key and exact message content");
assert.match(groupSend,/\.eq\('turn_id',turnId\)/,
  "after sending, only the persisted turn's messages may be fetched");
assert.doesNotMatch(groupSend,/\.eq\('group_id',activeGroupId\)\.is\('deleted_at',null\)\s*\.order\('created_at'/,
  "after sending, the client must not refetch the full group history");
assert.match(groupSend,/existingMessageIds/,"idempotent retries must not append duplicate local messages");
assert.match(groupSend,/responseBody\?\.status==='refunded'[\s\S]*await refreshWalletBalance\(\)[\s\S]*g\.pendingRequest=null/,
  "a lost refund response followed by an idempotent retry must refresh the wallet and release the pending request key");
assert.match(groupSend,/responseBody\?\.status==='content_rejected'/,
  "a retried content rejection must be presented as refunded instead of a generic failure");
assert.match(groupSend,/g\.messages=\[\.\.\.\(g\.messages\|\|\[\]\),\.\.\.newMessages\.filter/,
  "new turn messages must append to the existing complete history");

const phoneStart=html.indexOf("async function renderPhoneModal()");
assert.notEqual(phoneStart,-1,"missing Story phone modal function");
const phone=html.slice(phoneStart,phoneStart+18000);
assert.match(phone,/cacheIsFresh/);
assert.match(phone,/Date\.now\(\)-cached\.fetchedAt<15000/);
assert.match(phone,/storyPhoneRuntimeCache\.get\(cacheKey\)/);
assert.match(phone,/storyPhoneRuntimeCache\.set\(cacheKey/);
assert.match(phone,/storyPhoneRuntimeCache\.size>100/);


const profileSave=between("async function saveSupabaseProfile(account)","async function savePersonaPresets(account)");
assert.match(profileSave,/rpc\('save_my_profile'/);
assert.match(profileSave,/rpc\('get_my_private_profile_data'/,
  "profile save must retain owner-scoped private-field verification");
assert.match(profileSave,/stablePersonaJson\(privateData\.persona_presets/);
const personaSave=between("async function savePersonaPresets(account)","async function loginWithGoogle()");
assert.match(personaSave,/await saveSupabaseProfile\(account\)/);
assert.doesNotMatch(personaSave,/\.rpc\(/,
  "persona save must not repeat the private-profile verification RPC already performed by saveSupabaseProfile");

const illustrations=between("async function syncCharacterIllustrations(character,userId)","async function ");
assert.match(illustrations,/oldGalleryById=new Map\(oldGallery\.map\(row=>\[row\.id,row\]\)\)/,
  "illustration sync must reuse the already-loaded gallery metadata for change detection");
assert.match(illustrations,/insertedGallery\.includes\(item\.id\)\|\|\(previous&&String\(previous\.display_name\|\|''\)===expectedName\)/,
  "new rows and unchanged labels must not trigger redundant UPDATE requests");
assert.match(illustrations,/expectedGalleryNames=new Map/,
  "persisted gallery labels must still be verified after synchronization");

const authCoalescer=between("const verifiedAuthUserInflight = new Map()","async function loadSupabaseCharacters(user)");
assert.match(authCoalescer,/client\.auth\.getUser\(\)/,
  "concurrent login hydration must still verify the current user with Supabase");
assert.match(authCoalescer,/verifiedAuthUserInflight\.get\(expectedUid\)/,
  "concurrent auth verification for the same UID must share the in-flight request");
assert.match(authCoalescer,/verifiedAuthUserInflight\.delete\(expectedUid\)/,
  "auth verification must not be cached after the request settles");
const ownerLoader=between("async function loadSupabaseCharacters(user)","async function getCharacterIllustrationSignedUrl");
assert.match(ownerLoader,/getVerifiedAuthUser\(user\.id\)/,
  "owner character hydration must use the shared verified-auth request");
const cloudSessions=between("async function loadCloudChatSessions(user, options = {})","async function ");
assert.match(cloudSessions,/getVerifiedAuthUser\(user\.id\)/,
  "chat session hydration must use the shared verified-auth request");
assert.doesNotMatch(ownerLoader,/client\.auth\.getUser\(\)/,
  "owner hydration must not issue its own duplicate auth verification");
assert.doesNotMatch(cloudSessions,/client\.auth\.getUser\(\)/,
  "chat hydration must not issue its own duplicate auth verification");
const chatAuthorProfiles=between("async function loadChatSessionAuthorProfiles(uid, authorIds)", "async function loadCloudChatSessions");
assert.match(chatAuthorProfiles,/publicAuthorProfileLoaded\.add\(profile\.id\)/,
  "chat-list profile hydration must populate the shared loaded-profile cache to avoid refetching the same author on detail navigation");


const groupEdge=fs.readFileSync("supabase/functions/group-chat-turn/index.ts","utf8");
const groupMigration=fs.readFileSync("supabase/migrations/20261114180000_group_ai_single_orchestrator.sql","utf8");
const speakerParser=fs.readFileSync("supabase/functions/_shared/group-speaker-output.ts","utf8");
const sharedOpenRouter=fs.readFileSync("supabase/functions/_shared/openrouter-chat-completions.ts","utf8");
assert.match(sharedOpenRouter,/deepseek\/deepseek-v4-flash-20260423/,"single and group chat must share the approved DeepSeek V4 Flash model");
assert.match(groupEdge,/parseGroupTurnEnvelope\(provider\.result\.text, speakers\)/,"the single model response must validate speaker IDs and per-character phone states");
assert.match(groupEdge,/requestOpenRouterChatCompletion\(/,"group chat must reuse the shared OpenRouter client");
assert.match(sharedOpenRouter,/provider: \{ only: \["deepinfra"\], allow_fallbacks: false, data_collection: "deny" \}/,"all chat modes must share the approved no-data-collection provider restriction");
assert.match(sharedOpenRouter,/AbortController/,"the shared provider request must retain a bounded timeout");
assert.match(groupEdge,/findPrivateContextLeak/,"group output must pass private-context leak screening");
assert.match(groupEdge,/requestOpenRouterChatCompletion\(/,"group turns must call the shared provider request helper");
assert.match(groupMigration,/reserve_group_chat_turn/);
assert.match(groupMigration,/complete_group_chat_turn/);
assert.match(groupMigration,/refund_group_chat_turn/);
assert.match(groupMigration,/status IN \('reserved', 'settled', 'refunded'\)/);
assert.match(groupMigration,/GRANT EXECUTE ON FUNCTION public\.reserve_group_chat_turn[\s\S]*TO service_role/);
assert.match(groupMigration,/g\.deleted_at IS NULL/,
  "new group reservations must reject soft-deleted groups while holding the parent lock");
assert.match(groupEdge,/\.is\("deleted_at", null\)/,
  "the Edge Function must not load context from a group deleted after reservation");
const completeRpc=groupMigration.slice(groupMigration.indexOf("CREATE OR REPLACE FUNCTION public.complete_group_chat_turn"),groupMigration.indexOf("CREATE OR REPLACE FUNCTION public.refund_group_chat_turn"));
assert.match(completeRpc,/SELECT g\.deleted_at INTO v_group_deleted_at[\s\S]*FOR UPDATE[\s\S]*group_deleted_during_generation/,
  "completion must lock the parent and reject writes when deletion won the generation race");
const refundRpc=groupMigration.slice(groupMigration.indexOf("CREATE OR REPLACE FUNCTION public.refund_group_chat_turn"),groupMigration.indexOf("REVOKE ALL ON FUNCTION public.reserve_group_chat_turn"));
assert.match(refundRpc,/FROM public\.chat_groups g WHERE g\.id = v_group_id FOR UPDATE/,
  "refund must use parent-first locking while remaining available for soft-deleted groups");
assert.match(groupMigration,/wallet_transactions_group_turn_idempotency_uidx/,
  "group charge/refund ledger entries must have a unique per-turn operation/currency guard");
assert.match(groupEdge,/const TIMEOUT_MS = 55_000/,
  "group AI generation must have a fixed 55-second server-side deadline");
assert.match(groupEdge,/error\.name === "AbortError"[\s\S]*refund\(admin, user\.id, turnId, "provider_timeout"\)[\s\S]*status: refunded\.confirmed \? "timed_out" : "needs_reconciliation"/,
  "a confirmed server-side AI timeout must refund the reserved player charge");
assert.match(groupSend,/status==='timed_out'[\s\S]*費用已全額退還，沒有扣款/,
  "players must be told clearly that a timed-out group request was refunded");
assert.match(groupMigration,/v_cost := v_member_count \* 3/,
  "group price must remain 3 credits per character");
assert.match(groupMigration,/v_silver := LEAST\(COALESCE\(v_wallet\.silver_coins, 0\), v_cost\)/,
  "silver coins must be consumed before diamonds");
assert.match(groupMigration,/v_diamonds := v_cost - v_silver/,
  "diamonds must cover only the remaining group-turn cost");
assert.match(groupMigration,/v_charge\.status = 'refunded'[\s\S]*RETURN QUERY SELECT 'refunded'/,
  "repeating a refund must return the prior refund without crediting the wallet again");
assert.match(groupMigration,/v_charge\.status = 'settled' OR v_turn\.status = 'completed'[\s\S]*completed_group_turn_cannot_be_refunded/,
  "a settled/completed turn must never be refundable");
assert.match(groupMigration,/SET status = 'settled'[\s\S]*WHERE group_turn_id = p_turn_id AND status = 'reserved'/,
  "settlement must transition only a reserved charge");
assert.match(speakerParser,/\[：:\]/,"speaker parser must accept full-width and ASCII colons");
assert.match(speakerParser,/角色名稱：/,"speaker parser must document explicit character-name labels");
assert.doesNotMatch(html,/append_chat_group_mock_turn/,"frontend must no longer call the deterministic mock RPC");
assert.match(html,/group_chat_turn_charge: '群組聊天回覆扣款'/,"wallet history must label group turn charges");
assert.match(html,/group_chat_turn_refund: '群組聊天失敗退款'/,"wallet history must label group turn refunds");

console.log("Story relationship RPC dedupe, illustration write dedupe, group list refresh avoidance, incremental group-turn loading, phone-state cache, shared login auth verification, and author-profile hydration reuse checks passed.");


// Exercise the pagination contract against a deterministic 1,000-row fixture.
// This mirrors the database's DESC ordering and the three-part keyset predicate.
const makeUuid=n=>'00000000-0000-4000-8000-'+n.toString(16).padStart(12,'0');
const fixture=Array.from({length:1000},(_,index)=>({
  id:makeUuid(index+1),
  // Deliberately create timestamp ties and repeated per-turn sequence numbers.
  created_at:new Date(Date.UTC(2026,10,1,0,0,Math.floor(index/7))).toISOString(),
  sequence_no:index%4,
  turn_id:'turn-'+Math.floor(index/4),
  ordinal:index
}));
const compareDesc=(a,b)=>
  b.created_at.localeCompare(a.created_at) ||
  b.sequence_no-a.sequence_no ||
  b.id.localeCompare(a.id);
const isOlderThan=(row,cursor)=>
  row.created_at<cursor.created_at ||
  (row.created_at===cursor.created_at && row.sequence_no<cursor.sequence_no) ||
  (row.created_at===cursor.created_at && row.sequence_no===cursor.sequence_no && row.id<cursor.id);
const orderedFixture=[...fixture].sort(compareDesc);
let cursor=orderedFixture[49];
let paged=orderedFixture.slice(0,50);
let pageCount=1;
while(paged.length<fixture.length && pageCount<30) {
  const page=orderedFixture.filter(row=>isOlderThan(row,cursor)).slice(0,50);
  assert.ok(page.length>0,'pagination must continue until the oldest row');
  cursor=page.at(-1);
  paged.push(...page);
  pageCount++;
}
assert.equal(pageCount,20,'1,000 rows at 50 per page must require exactly 20 pages');
assert.equal(paged.length,1000,'all fixture rows must be returned');
assert.equal(new Set(paged.map(row=>row.id)).size,1000,'keyset pages must not duplicate rows');
assert.deepEqual(paged.map(row=>row.id),orderedFixture.map(row=>row.id),
  'keyset pages must preserve deterministic newest-to-oldest database order');
assert.ok(orderedFixture.some((row,index)=>index>0 &&
  row.created_at===orderedFixture[index-1].created_at &&
  row.sequence_no===orderedFixture[index-1].sequence_no),
  'fixture must exercise the UUID tie-breaker for equal timestamp and sequence values');
const mergedWithOverlap=[...paged.slice(0,50),...paged.slice(40,90)];
const uniqueMerged=[...new Map(mergedWithOverlap.map(row=>[row.id,row])).values()];
assert.equal(uniqueMerged.length,90,'client-side merge must deduplicate overlapping pages');

assert.match(groupHistory,/requestId!==g\.openRequestId\|\|g\.active\?\.id!==groupId\|\|currentUser\(\)\?\.uid!==uid/,
  'an older-page response must be discarded after group/account switching');
assert.match(groupHistory,/g\.historyError=groupFriendlyError\(error\)/,
  'older-page failures must remain retryable and visible rather than corrupting history');
const groupRenderer=between('function renderGroupConversation()','let groupBackgroundTimer=null');
const singleRenderer=between('function renderMessages(scroll = true)','if(s.activeTurnInFlight)');
assert.match(groupRenderer,/const outerAvatar=isSystem \? '<span class="avatar avatar-fallback">系<\/span>' : '';/,
  'group messages may render a system avatar, but must not create a separate player avatar');
assert.doesNotMatch(groupRenderer,/avatar-fallback player-avatar/,
  'group player messages must not create an outer “you” avatar');
assert.doesNotMatch(singleRenderer,/outerAvatar/,
  'single chat player messages must not allocate or render a redundant outer avatar');
const messageActionHelper=between('function renderMessageActionBar(','function roleplaySegmentHTML(');
assert.match(messageActionHelper,/message-action-bar/);
assert.match(messageActionHelper,/copyAction/);
assert.match(messageActionHelper,/deleteAction/);
assert.match(messageActionHelper,/reportKind/);
assert.match(messageActionHelper,/editAction/);
assert.match(groupRenderer,/renderMessageActionBar\(\{[\s\S]*copy-group-message[\s\S]*delete-group-message[\s\S]*edit-group-message/);
assert.match(singleRenderer,/renderMessageActionBar\(\{[\s\S]*copy-message[\s\S]*delete-message[\s\S]*edit-message/,
  'single and group chats must share one message-action UI renderer while retaining their distinct action handlers');
assert.equal((html.match(/message-action-bar" aria-label="訊息操作"/g)||[]).length,0,
  'message-action markup must not be duplicated in the two chat renderers');
assert.doesNotMatch(html,/body\.group-chat-page body\.group-chat-page \.composer/,
  'the invalid nested-body group composer selector must be removed');
assert.doesNotMatch(html,/\.message\.user\s*>\s*\.avatar/,
  'the obsolete CSS rule hiding redundant outer player avatars must be removed');
assert.doesNotMatch(html,/body\.group-chat-page \.message-content/,
  'group chat must inherit the single-chat message-content sizing rule');
assert.match(groupRenderer,/roleplaySegmentHTML\(segment,\{summonedByPlayer\}\)/);
assert.match(singleRenderer,/roleplaySegmentHTML\(segment, \{summonedByPlayer\}\)/,
  'single and group chat must share the same roleplay segment renderer rather than duplicate avatar logic');
const scrollAnchorHelper=between('function captureChatScrollAnchor(pane)','async function loadCloudSessionMessages');
assert.match(scrollAnchorHelper,/pane\.scrollTop=anchor\.scrollTop\+Math\.max\(0,pane\.scrollHeight-anchor\.scrollHeight\)/,
  'prepending older messages must compensate for added content height when the original anchor is unavailable');
assert.match(groupRenderer,/restoreChatScrollAnchor\(groupMessages,anchor\)/,
  'group history rendering must restore the saved visible-message anchor after prepending older messages');
assert.match(groupRenderer,/if\(groupMessages\.isConnected&&route\.page==='group'/,
  'scroll restoration must not touch a detached message pane');


// Group transaction recovery / watchdog static contract checks.
assert.match(groupMigration,/CREATE OR REPLACE FUNCTION public\.expire_group_chat_turn\([\s\S]*?RETURNS TABLE\(status text, balance_silver integer, balance_diamonds integer\)/,
  "a per-turn database expiration primitive must return the authoritative refund state and balances");
const expireRpc=groupMigration.slice(groupMigration.indexOf("CREATE OR REPLACE FUNCTION public.expire_group_chat_turn"),groupMigration.indexOf("CREATE OR REPLACE FUNCTION public.run_group_chat_turn_watchdog"));
assert.match(expireRpc,/FROM public\.chat_groups g WHERE g\.id = v_group_id FOR UPDATE[\s\S]*FROM public\.chat_group_turns t[\s\S]*FOR UPDATE[\s\S]*FROM public\.chat_group_turn_charges c[\s\S]*FOR UPDATE[\s\S]*FROM public\.wallet_accounts w[\s\S]*FOR UPDATE/,
  "timeout recovery must lock parent -> turn -> charge -> wallet in the global order");
assert.match(expireRpc,/clock_timestamp\(\) < v_turn\.processing_started_at \+ interval '55 seconds'/,
  "watchdog must re-check the 55-second deadline after acquiring locks");
assert.match(expireRpc,/status = 'refunded'[\s\S]*failure_code = 'provider_timeout_watchdog'/,
  "watchdog must atomically mark the charge refunded and persist a recoverable timeout reason");
assert.match(expireRpc,/silver_coins = w\.silver_coins \+ v_charge\.silver_charged[\s\S]*diamonds = w\.diamonds \+ v_charge\.diamonds_charged/,
  "watchdog must restore the exact originally reserved currency split");
assert.match(groupMigration,/CREATE OR REPLACE FUNCTION public\.run_group_chat_turn_watchdog\(p_batch_size integer DEFAULT 100\)/,
  "a bounded database-side watchdog batch must exist");
assert.match(groupMigration,/CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog[\s\S]*cron\.schedule\([\s\S]*'\* \* \* \* \*'[\s\S]*public\.run_group_chat_turn_watchdog\(100\)/,
  "the database watchdog must be scheduled independently every minute");
assert.match(groupMigration,/public\.expire_group_chat_turn\(v_expired\.user_id, v_expired\.id\)/,
  "new reservations after reload must first expire abandoned turns that crossed the deadline");
assert.match(groupMigration,/SET processing_started_at = COALESCE\(processing_started_at, created_at, now\(\)\)[\s\S]*WHERE status = 'processing' AND processing_started_at IS NULL/,
  "legacy processing turns must receive a start timestamp so the watchdog can recover them");
assert.match(completeRpc,/clock_timestamp\(\) >= v_turn\.processing_started_at \+ interval '55 seconds'[\s\S]*group_turn_deadline_exceeded/,
  "completion must reject replies that lose the deadline race after acquiring transaction locks");
assert.match(groupEdge,/admin\.rpc\("expire_group_chat_turn"/,
  "same-key retries must proactively recover an expired processing turn without waiting for cron");
assert.match(groupEdge,/provider_timeout_watchdog/,
  "idempotent retries must preserve the watchdog timeout outcome");
assert.match(groupEdge,/const processingDeadlineAt = Date\.now\(\) \+ TIMEOUT_MS - 1000/,
  "context loading must consume the same absolute request deadline with a one-second safety margin");
assert.match(groupEdge,/const providerTimeoutMs = processingDeadlineAt - Date\.now\(\)[\s\S]*timeoutMs: providerTimeoutMs/,
  "provider timeout must use only the remaining turn budget rather than restarting a fresh 55 seconds");
assert.match(groupMigration,/poyozz-group-watchdog-cron-history-cleanup[\s\S]*interval '7 days'/,
  "the cron run-history cleanup must prevent unbounded pg_cron diagnostics growth");
assert.match(groupEdge,/group_turn_deadline_exceeded[\s\S]*status: refunded\.confirmed \? "timed_out"/,
  "completion losing the deadline race must refund and report a timeout");
assert.match(groupSend,/responseBody\?\.status==='timed_out'[\s\S]*pendingRequest=null/,
  "the client must clear the old idempotency key only after a confirmed timeout refund");

console.log('Group watchdog, deadline race, abandoned-request recovery, idempotent timeout status, and exact-currency refund checks passed.');
console.log('Group history fixture passed: 1,000 rows, 20 pages, timestamp/sequence ties, UUID cursor tie-break, no gaps or duplicates, overlapping-page dedupe, group-switch guards, and scroll anchoring.');

const groupPhoneMigration = fs.readFileSync('supabase/migrations/20261114180000_group_ai_single_orchestrator.sql', 'utf8');
const groupPhoneFunction = fs.readFileSync('supabase/functions/group-chat-turn/index.ts', 'utf8');
const groupPhoneParser = fs.readFileSync('supabase/functions/_shared/group-turn-envelope.ts', 'utf8');
const groupPhoneUI = fs.readFileSync('index.html', 'utf8');
const groupPhoneStyles = fs.readFileSync('poyozz-ui.css', 'utf8');
assert.match(groupPhoneMigration, /ADD COLUMN IF NOT EXISTS phone_notifications jsonb NOT NULL DEFAULT '\[\]'::jsonb/);
assert.match(groupPhoneMigration, /p_phone_updates jsonb/);
assert.match(groupPhoneMigration, /SET phone_notifications = v_phone_notifications/);
assert.match(groupPhoneMigration, /GRANT EXECUTE ON FUNCTION public\.complete_group_chat_turn\(uuid, uuid, jsonb, jsonb\) TO service_role/);
assert.match(groupPhoneFunction, /parseGroupTurnEnvelope/);
assert.match(groupPhoneFunction, /phone_settings/);
assert.match(groupPhoneFunction, /p_phone_updates: parsed\.phoneUpdates/);
assert.match(groupPhoneFunction, /phone_updates: parsed\.phoneUpdates/);
assert.match(groupPhoneParser, /phoneById\.size !== speakers\.length/);
assert.match(groupPhoneUI, /character\.phoneNotifications\|\|group\.phoneNotificationsByCharacter/);
assert.match(groupPhoneUI, /phone-device-head--group/);
assert.match(groupPhoneUI, /phone_notifications/);
assert.match(groupPhoneUI, /initialStoryTime=Number\(isGroup\?/);
assert.match(groupPhoneUI, /phoneHeader\+/);
assert.match(groupPhoneStyles, /phone-device-head--group \.phone-member-switch/);
