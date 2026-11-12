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

console.log("Story relationship RPC dedupe, illustration write dedupe, group list refresh avoidance, incremental group-turn loading, and phone-state cache checks passed.");
