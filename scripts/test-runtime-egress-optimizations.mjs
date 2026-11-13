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

const groupSend=between("async function groupSendMock()","async function groupRefreshList()");
assert.match(groupSend,/data:turnId,error/,"group turn RPC result must retain the stable turn ID");
assert.match(groupSend,/\.eq\('turn_id',turnId\)/,
  "after sending, only the persisted turn's messages may be fetched");
assert.doesNotMatch(groupSend,/\.eq\('group_id',activeGroupId\)\.is\('deleted_at',null\)\s*\.order\('created_at'/,
  "after sending, the client must not refetch the full group history");
assert.match(groupSend,/existingMessageIds/,"idempotent retries must not append duplicate local messages");
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
assert.match(groupRenderer,/anchor\.scrollTop\+\(groupMessages\.scrollHeight-anchor\.scrollHeight\)/,
  'prepending older messages must compensate for the added content height');
assert.match(groupRenderer,/if\(groupMessages\.isConnected\)/,
  'scroll restoration must not touch a detached message pane');

console.log('Group history fixture passed: 1,000 rows, 20 pages, timestamp/sequence ties, UUID cursor tie-break, no gaps or duplicates, overlapping-page dedupe, group-switch guards, and scroll anchoring.');
