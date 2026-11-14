import assert from "node:assert/strict";
import fs from "node:fs";

const html=fs.readFileSync("index.html","utf8");
const uiCss=fs.readFileSync("poyozz-ui.css","utf8");
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

assert.match(groupOpen,/\.order\('created_at',\{ascending:false\}\).*\.limit\(5\)/,
  "opening a group must fetch only the newest bounded page in reverse chronological query order");
assert.doesNotMatch(groupOpen,/\.limit\(50\)/,
  "group initial history must not fetch fifty messages");
assert.match(groupOpen,/oldestInitialMessage=initialMessageRows\.at\(-1\)/,
  "the first page must retain a stable cursor at its oldest fetched row");
const singleHistory=between("async function loadCloudSessionMessages(sessionId, options = {})","const chatSessionSaveQueue =");
assert.match(singleHistory,/const pageSize=5;/,
  "single Story and Encounter chats must initially hydrate only five messages per request");
assert.match(singleHistory,/\.limit\(pageSize\)/,
  "single Story and Encounter chat pagination must apply the shared five-message page size");
assert.match(singleHistory,/session\.encounterMode/,
  "the shared single-chat history loader must retain Encounter metadata handling");
assert.doesNotMatch(singleHistory,/\.limit\(50\)|pageSize=50/,
  "single and Encounter chat history must not regress to large initial pages");
const groupHistory=between("async function groupLoadOlderMessages()","async function openGroupBackgroundSettings");
const searchJump=between("async function jumpToChatSearchHit(button)","async function returnChatToLatest(kind)");
assert.equal((searchJump.match(/\.limit\(2\)/g)||[]).length,4,
  "single and group search jumps must load only two neighboring messages on each side of the target");
assert.ok(groupHistory.includes("const oldest=page.at(-1);"),
  "the next cursor must use the oldest row in the descending page to avoid skipping messages");
assert.match(groupHistory,/\.or\(olderFilter\)/,
  "older pages must use a keyset cursor instead of offset pagination");
assert.match(groupHistory,/\.order\('id',\{ascending:false\}\)\.limit\(5\)/,
  "older pages must use a deterministic tie-breaker and a fixed page size");
assert.doesNotMatch(groupHistory,/\.limit\(50\)/,
  "older group history must also remain limited to five messages per request");
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
assert.match(cloudSessions,/pageSize\('chatSessions'\)/,
  "single chat list pages must use the shared ten-row page size");
assert.match(cloudSessions,/\.eq\('session_data->>pinned','true'\)/,
  "pinned single chats must load independently from the unpinned page");
assert.match(cloudSessions,/session_data->>pinned\.eq\.false,session_data->>pinned\.is\.null/,
  "the single chat page query must exclude pinned sessions");
assert.match(cloudSessions,/\.range\(pager\.offset,pager\.offset\+pageSize-1\)/,
  "single chat list continuation must use bounded backend pages");
assert.match(cloudSessions,/if \(!onlySessionId && !pagedList\)/,
  "loading another single-chat page must not evict sessions already loaded from prior pages");
assert.match(html,/loadCloudChatSessions\(currentUser\(\),\{loadMore:true\}\)/,
  "the shared chat-list sentinel must request the next single-chat page");
assert.match(html,/canLoadSessions=chatSessionListPager\.initialLoaded&&chatSessionListPager\.hasMore/,
  "the chat list must keep a continuation sentinel while single-chat pages remain");
assert.match(cloudSessions,/session_last_assistant_message_at:session_data->>lastAssistantMessageAt/,
  "paged session metadata must still include the unread indicator timestamp");
assert.match(cloudSessions,/session_last_read_at:session_data->>lastReadAt/,
  "paged session metadata must still include the read cursor");
assert.match(cloudSessions,/const listSessionSelect=\[/,
  "chat list hydration must use a dedicated compact field projection");
const compactChatListProjection=cloudSessions.slice(cloudSessions.indexOf("const listSessionSelect=["),cloudSessions.indexOf("const sessionSelect=",cloudSessions.indexOf("const listSessionSelect=[")));
assert.doesNotMatch(compactChatListProjection,/session_story_world_state|session_opening_message|session_pending_turn|session_persona/,
  "chat list pages must not transfer story-world state, full opening messages, persona or pending-turn payloads");
assert.match(cloudSessions,/pagedList\?listSessionSelect:fullSessionSelect/,
  "full session metadata must remain available for direct session hydration only");

assert.match(cloudSessions,/pager\.pinnedLoaded=true[\s\S]*pager\.initialLoaded=true/,
  "the pinned set and first unpinned page must be marked loaded only after both queries succeed");
assert.match(cloudSessions,/if \(pagedList && route\.page === 'chat'\) render\(\)/,
  "a completed page must refresh the visible chat list and its continuation sentinel");



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

const groupList=between("async function groupLoadList(force=false,loadMore=false)","async function groupOpen(groupId)");
assert.match(groupList,/pageSize\('groupSessions'\)/,
  "group chat lists must use the shared ten-row page size");
assert.match(groupList,/\.eq\('pinned',true\)/,
  "pinned groups must load independently from the unpinned ten-row page");
assert.match(groupList,/pinned\.eq\.false,pinned\.is\.null/,
  "the paginated group query must exclude pinned rows");
assert.match(groupList,/\.range\(g\.groupListOffset,g\.groupListOffset\+pageSize-1\)/,
  "group list pages must be fetched by the backend in bounded ranges");
assert.match(groupList,/groupHydrateListRows\(newRows,user\.id\)/,
  "member, avatar and preview hydration must be restricted to newly loaded groups");
assert.match(groupList,/g\.groupListHasMore=currentPage\.length===pageSize/,
  "group list continuation must stop when the backend returns a short page");
assert.match(groupList,/mergeUnique\(g\.groups,newRows,group=>group\.id\)/,
  "group list continuation must append without duplicating already loaded groups");
assert.match(html,/chatListSentinel/);
assert.match(html,/groupLoadList\(false,true\)/,
  "the group list sentinel must request the next page");

const authorProfileModule=fs.readFileSync("author-profile.js","utf8");
const followedAuthorsModule=fs.readFileSync("followed-authors.js","utf8");
assert.match(authorProfileModule,/loadAuthorCharacterPage\(authorId,\s*page\.offset\)/,
  "author profile presentation must delegate each page to the app-owned data loader");
assert.match(html,/async function loadPublicAuthorCharacterPage\(authorId,offset=0\)/,
  "author profile character data must be loaded through the app data layer");
assert.match(html,/\.range\(offset,offset\+pageSize-1\)/,
  "author profile data must use bounded twenty-row backend pages");
assert.match(authorProfileModule,/PoyozzListPagination\.observeEnd/,
  "author profile lists must use the shared scroll pagination observer");
assert.match(followedAuthorsModule,/loadPublicAuthorLatestCharacters\(authorIds\)/,
  "followed-author presentation must delegate latest-character hydration to the app data layer");
assert.match(html,/async function loadPublicAuthorLatestCharacters\(authorIds=\[\]\)/,
  "followed-author latest characters must use a centralized app-owned query");
assert.match(html,/\.order\('id',\{ascending:false\}\)\.limit\(4\)/,
  "followed-author cards must fetch only each author's four newest public characters");
assert.doesNotMatch(followedAuthorsModule,/await loadPublicSupabaseCharacters\(\)/,
  "followed-author cards must not trigger a full public-character catalogue fetch");
const paginationModule=fs.readFileSync("list-pagination.js","utf8");
assert.match(paginationModule,/explore:\s*20/);
assert.match(paginationModule,/authorCharacters:\s*20/);
assert.match(paginationModule,/chatSessions:\s*10/);
assert.match(paginationModule,/groupSessions:\s*10/);
assert.match(paginationModule,/encounterMemories:\s*20/);
assert.match(paginationModule,/messages:\s*5/);
assert.match(paginationModule,/function observeEnd/);
const exploreLoader=between("async function loadPublicCharacterRows(offset=0)","// Concurrent login hydrators");
assert.match(html,/publicCharacterPageSize = window\.PoyozzListPagination\.pageSize\('explore'\)/,
  "Explore must use the shared twenty-character page size");
assert.match(exploreLoader,/\.range\(offset,offset\+publicCharacterPageSize-1\)/,
  "Explore public characters must be fetched from Supabase in bounded backend pages");
assert.match(exploreLoader,/mergeUnique\(state\.characters,publicCharacters,character=>character\.id\)/,
  "Explore continuation must append newly fetched characters without duplicating loaded rows");
assert.match(exploreLoader,/window\.loadNextPublicCharacterPage/,
  "Explore must expose a dedicated next-page loader");
assert.match(exploreLoader,/if\(characterId\)[\s\S]*?\.eq\('id',characterId\)/,
  "direct public-character links must hydrate their exact character without scanning the catalogue");
assert.match(html,/loadPublicCharacterById=characterId=>loadPublicSupabaseCharacters\(\{characterId\}\)/,
  "the direct character hydrator must be available to detail and group routes");
const detailPage=between("function renderDetail()","function renderAuthor()");
assert.match(detailPage,/window\.loadPublicCharacterById\(characterId\)/,
  "a directly opened public character detail page must fetch its own row when it is not in the current Explore page");
assert.match(html,/await window\.loadPublicCharacterById\(characterId\)/,
  "opening a public character from a group must hydrate that exact character instead of resetting Explore to page one");

const exploreGrid=between("function renderGrid({append=false}={})","async function loadPublicCharacterPrimaryIllustration");
assert.match(exploreGrid,/list\.slice\(0,limit\)/,
  "Explore must cap visible character cards to the current twenty-item display page");
assert.match(exploreGrid,/pageSize\('explore'\)/,
  "Explore scroll continuation must advance by twenty visible cards");
assert.match(exploreGrid,/PoyozzListPagination\.observeEnd/,
  "Explore must use the shared IntersectionObserver lifecycle rather than a separate observer implementation");

assert.match(exploreGrid,/window\.loadNextPublicCharacterPage\(\)/,
  "Explore must fetch another backend page when the loaded rows are exhausted");
assert.match(exploreGrid,/characterVideoObserver\.unobserve\(previousVideo\)/,
  "Explore pagination must preserve the existing video-node reuse behavior");

const encounterMemory=between("function loadEncounterMemoryList(panel,session)","async function openEncounterMemoryDetail(button)");
assert.match(encounterMemory,/pageSize\('encounterMemories'\)/,
  "Encounter memory lists must use the shared twenty-session page size");
assert.match(encounterMemory,/\.range\(pageStart,pageStart\+pageSize-1\)/,
  "Encounter sessions must be paginated by the backend instead of fetching 200 diary rows");
assert.match(encounterMemory,/\.in\('metadata->>session_id',sessionIds\)/,
  "diary summaries must be hydrated only for the current page of Encounter sessions");
assert.match(encounterMemory,/encounter_archived!=='true'/,
  "unfinished new Encounter sessions must remain hidden from the memory archive");
assert.match(encounterMemory,/PoyozzListPagination\.observeEnd/,
  "Encounter memory lists must load the next twenty sessions when the user reaches the end");
assert.doesNotMatch(encounterMemory,/\.limit\(200\)/,
  "Encounter memory list initialization must not fetch 200 diary records");
assert.match(encounterMemory,/visibleCards=combinedCards\.slice\(0,pageSize\)/,
  "Encounter list rendering must cap each visible page at twenty cards, including legacy rows");
assert.match(encounterMemory,/pager\.buffer=combinedCards\.slice\(pageSize\)/,
  "overflow cards must be buffered for the next page instead of rendering more than twenty initially");
assert.match(encounterMemory,/pager\.hasMore\|\|pager\.buffer\.length/,
  "the Encounter sentinel must remain available while buffered cards remain");
assert.match(encounterMemory,/\.limit\(pageSize\)/,
  "only one compact diary preview per page may be hydrated for Encounter list cards");
assert.match(encounterMemory,/legacyOffset,pager\.legacyOffset\+pageSize-1/,
  "legacy Encounter diary rows must also use bounded backend pagination");
assert.match(encounterMemory,/encounter_place:session_data->>encounterPlace/,
  "Encounter list hydration must select only the required place metadata");
assert.doesNotMatch(encounterMemory,/select\('id,chat_mode,session_data,updated_at'\)/,
  "Encounter list pages must not transfer the entire session_data JSON payload");


console.log("Story relationship RPC dedupe, illustration write dedupe, group list refresh avoidance, incremental group-turn loading, phone-state cache, shared login auth verification, and author-profile hydration reuse checks passed.");


// Exercise the five-message pagination contract against a deterministic 1,000-row fixture.
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
let cursor=orderedFixture[4];
let paged=orderedFixture.slice(0,5);
let pageCount=1;
while(paged.length<fixture.length && pageCount<210) {
  const page=orderedFixture.filter(row=>isOlderThan(row,cursor)).slice(0,5);
  assert.ok(page.length>0,'pagination must continue until the oldest row');
  cursor=page.at(-1);
  paged.push(...page);
  pageCount++;
}
assert.equal(pageCount,200,'1,000 rows at 5 per page must require exactly 200 pages');
assert.equal(paged.length,1000,'all fixture rows must be returned');
assert.equal(new Set(paged.map(row=>row.id)).size,1000,'keyset pages must not duplicate rows');
assert.deepEqual(paged.map(row=>row.id),orderedFixture.map(row=>row.id),
  'keyset pages must preserve deterministic newest-to-oldest database order');
assert.ok(orderedFixture.some((row,index)=>index>0 &&
  row.created_at===orderedFixture[index-1].created_at &&
  row.sequence_no===orderedFixture[index-1].sequence_no),
  'fixture must exercise the UUID tie-breaker for equal timestamp and sequence values');
const firstTwoPages=paged.slice(0,10);
const overlappingNextPage=[...paged.slice(5,10),...paged.slice(10,15)];
const uniqueMerged=[...new Map([...firstTwoPages,...overlappingNextPage].map(row=>[row.id,row])).values()];
assert.equal(uniqueMerged.length,15,'client-side merge must deduplicate overlapping five-message pages');

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
const copyHelper=between('async function copyChatMessageContent(content)','function isLatestEditableChatMessage(');
assert.match(copyHelper,/navigator\.clipboard\.writeText\(text\)/);
assert.match(copyHelper,/showDialog\('複製訊息'/);
assert.match(html,/case 'copy-message':[\s\S]*copyChatMessageContent\(m\.text\)/);
assert.match(html,/case 'copy-group-message':[\s\S]*copyChatMessageContent\(message\.content\)/);
assert.match(html,/function confirmChatMessageDeletion\(\)[\s\S]*return confirm\('確定刪除此訊息？此操作無法復原。'\)/);
assert.match(html,/if \(!s \|\| !message \|\| !confirmChatMessageDeletion\(\)\) break/);
assert.match(html,/if \(action !== 'delete-group-message'\) return;[\s\S]*if \(!confirmChatMessageDeletion\(\)\) return;/);
assert.doesNotMatch(html,/confirm-delete-group-message/,
  'group delete confirmation must use the same single-chat confirmation flow instead of a duplicate modal');
assert.equal((html.match(/confirmChatMessageDeletion\(\)/g)||[]).length,3,
  'single and group delete handlers must share one confirmation helper');
const latestEditHelper=between('function isLatestEditableChatMessage(','function renderMessageActionBar(');
assert.match(latestEditHelper,/allowedTypes\.includes\(message\[typeField\]\)/);
assert.match(latestEditHelper,/messages\.filter\(item=>item\[typeField\]===message\[typeField\]\)\.at\(-1\)/);
assert.match(groupRenderer,/isLatestEditableChatMessage\(g\.messages,m,'type',\['user','character'\],g\.searchJump\)/);
assert.match(singleRenderer,/isLatestEditableChatMessage\(s\.messages,m,'role',\['user','assistant'\],s\.cloudSearchJump\)/);
assert.equal((html.match(/isLatestEditableChatMessage\(/g)||[]).length,7,
  'single and group render/edit handlers must share the same latest-message eligibility rule');
const messageActionHelper=between('function renderMessageActionBar(','function roleplaySegmentHTML(');
assert.match(messageActionHelper,/message-action-bar/);
assert.match(messageActionHelper,/copyAction/);
assert.match(messageActionHelper,/deleteAction/);
assert.match(messageActionHelper,/reportKind/);
assert.match(messageActionHelper,/editAction/);
assert.match(groupRenderer,/renderMessageActionBar\(\{[\s\S]*copy-group-message[\s\S]*delete-group-message[\s\S]*edit-group-message/);
assert.match(singleRenderer,/renderMessageActionBar\(\{[\s\S]*copy-message[\s\S]*delete-message[\s\S]*edit-message/,
  'single and group chats must share one message-action UI renderer while retaining their distinct action handlers');
assert.equal(((groupRenderer+singleRenderer).match(/message-action-bar" aria-label="訊息操作"/g)||[]).length,0,
  'message-action markup must not be duplicated in the two chat renderers');
assert.doesNotMatch(html,/body\.group-chat-page body\.group-chat-page \.composer/,
  'the invalid nested-body group composer selector must be removed');
assert.doesNotMatch(html,/\.message\.user\s*>\s*\.avatar/,
  'the obsolete CSS rule hiding redundant outer player avatars must be removed');
assert.doesNotMatch(html,/body\.group-chat-page \.message-content/,
  'group chat must inherit the single-chat message-content sizing rule');
assert.doesNotMatch(uiCss,/body\.group-chat-page \.message-content/,
  'the shared stylesheet must not redefine message-content sizing for group chat');
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
console.log('Group history fixture passed: 1,000 rows, 200 pages, timestamp/sequence ties, UUID cursor tie-break, no gaps or duplicates, overlapping-page dedupe, group-switch guards, and scroll anchoring.');

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
