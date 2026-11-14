import assert from "node:assert/strict";
import fs from "node:fs";

const frontend = fs.readFileSync("index.html", "utf8");
assert.doesNotMatch(frontend, /isPreviewDeployment|enterPreviewTestMode|測試登入（僅本機介面）|不建立帳號、不連線雲端/,
  "temporary preview-only test login must not remain in the production UI source");
const between = (start, end) => {
  const from = frontend.indexOf(start);
  const to = frontend.indexOf(end, from + start.length);
  assert.notEqual(from, -1, "missing source block: " + start);
  assert.notEqual(to, -1, "missing end marker: " + end);
  return frontend.slice(from, to);
};

const cacheCompaction = between("function compactCloudSessionForLocalStorage(session)", "function compactLocalStateForQuota");
assert.match(cacheCompaction, /slice\(-5\)/);
assert.match(cacheCompaction, /pendingIds/);
assert.match(cacheCompaction, /message\.localOnly===true/);
assert.match(cacheCompaction, /!isUuid\(message\.id\)/);
assert.match(cacheCompaction, /cloudSessionDataLoaded:false/);
assert.match(cacheCompaction, /cloudMessagesLoaded:false/);
assert.match(cacheCompaction, /cloudRoleplayMeta/);
const cacheRestore = between("function restoreSessionsForUser(uid)", "function isolateSessionsForUser");
assert.match(cacheRestore, /compactCloudSessionForLocalStorage\(session\)/,
  "restored cloud chats must be compacted before the first conversation render");
const cacheWriter = between("function cacheSessionsForUser(uid)", "function restoreSessionsForUser");
assert.match(cacheWriter, /compactSessionsForLocalStorage/);
const persistWriter = between("function persist()", "const CHAT_HISTORY_CACHE_COMPACTION_KEY");
assert.match(persistWriter, /compactLocalStateForStorage/);
const upgradeMigration = between("const CHAT_HISTORY_CACHE_COMPACTION_KEY", "// 僅在網址明確帶上");
assert.match(upgradeMigration, /state\.sessions=compactSessionsForLocalStorage/);
assert.match(persistWriter, /compactLocalStateForQuota\(baseSnapshot\)/);

const sessionSync = between("async function loadCloudChatSessions(user, options = {})", "async function loadCloudSessionMessages");
assert.doesNotMatch(sessionSync, /from\(['"]chat_messages['"]\)/,
  "login/session-list hydration must never download chat message rows");
assert.match(sessionSync, /session_name:session_data->>name/);
assert.match(sessionSync, /session_last_message_preview:session_data->>lastMessagePreview/);
assert.match(sessionSync, /session_has_user_message:session_data->>hasUserMessage/);
assert.match(sessionSync, /existingHasPlayerMessage/);
assert.match(sessionSync, /parseBool\(marker\)\|\|existingHasPlayerMessage/);
assert.match(sessionSync, /session_pending_turn:session_data->pendingTurn/);
assert.doesNotMatch(sessionSync, /existing\?\.pendingTurn/);
assert.match(sessionSync, /session_archived_at:session_data->>archivedAt/);
assert.match(sessionSync, /onlySessionId/);
assert.match(sessionSync, /void loadChatSessionAuthorProfiles\(user\.id, snapshotAuthorIds\)/,
  "public author profiles must not block chat-list hydration");
assert.doesNotMatch(sessionSync, /await client\.from\(['"]public_profiles['"]\)/,
  "chat-list hydration must not await public profile rows");
assert.match(sessionSync, /readDeletedChatTombstones/);
assert.match(sessionSync, /character_snapshot_author_id:character_snapshot->>authorId/);
assert.match(sessionSync, /character_snapshot_opening:character_snapshot->>opening/);
assert.doesNotMatch(sessionSync, /'character_snapshot'/, "chat-list hydration must not fetch the full image-heavy snapshot");
assert.match(sessionSync, /cloudSnapshotNeedsRepair:!row\.character_snapshot_id/);
assert.match(sessionSync, /compactCloudSessionForLocalStorage\(state\.sessions\[row\.id\]\)/);

const hasUserHelper = between("function hasUserMessage(session)", "function sessionTitle");
assert.match(hasUserHelper, /if\(session\?\.cloudHasUserMessage===true\)return true/);
assert.match(hasUserHelper, /if\(session\?\.cloudHasUserMessage===false\)return false/);
assert.ok(hasUserHelper.indexOf("cloudHasUserMessage===true") < hasUserHelper.indexOf("messages||[]"),
  "persisted marker should avoid scanning the entire transcript for chat-list rendering");

const messageLoader = between("async function loadCloudSessionMessages(sessionId, options = {})", "async function saveChatSessionSafely");
assert.match(messageLoader, /options\.refresh !== true/,
  "an explicit refresh must bypass the already-loaded short circuit");
assert.match(messageLoader, /auth\.getUser\(\)/);
assert.match(messageLoader, /snapshotRequested=!older&&session\.cloudCharacterSnapshotLoaded!==true/);
assert.match(messageLoader, /\.\.\.\(snapshotRequested\?\['character_snapshot'\]:\[\]\)/);
assert.match(messageLoader, /session\.cloudCharacterSnapshotLoaded=true/);
assert.match(messageLoader, /session\.cloudSnapshotNeedsRepair=!row\.character_snapshot\?\.id/);
assert.match(messageLoader, /cloudSynced:true/,
  "messages fetched from Supabase must be marked as already synchronized");
assert.match(messageLoader, /\.eq\('id', sessionId\)\.eq\('user_id', userId\)\.is\('deleted_at', null\)/);
assert.match(messageLoader, /\.eq\('session_id',sessionId\)\.is\('deleted_at',null\)/);
assert.match(messageLoader, /const pageSize=5/);
assert.match(messageLoader, /messageQuery\.limit\(pageSize\)/);
assert.match(messageLoader, /cloudOldestMessageCursor/);
assert.match(messageLoader, /const currentPageIds=new Set\(cloudMessages\.map\(message=>message\.id\)\)/);
assert.match(messageLoader, /cachedMessages=older\?\(session\.messages\|\|\[\]\):/);
assert.match(messageLoader, /currentPageIds\.has\(message\.id\)/,
  "initial refresh must discard stale cached cloud messages outside the newest five-row page");
assert.match(messageLoader, /created_at\.lt\./);
assert.match(messageLoader, /roleplayMeta/);
assert.match(messageLoader, /data\.memories/);
assert.match(messageLoader, /data\.album/);
assert.match(messageLoader, /session\.pendingTurn=data\.pendingTurn/);
assert.doesNotMatch(messageLoader, /session\.pendingTurn\|\|null/);
assert.match(messageLoader, /initialOpeningMessage/);
assert.match(messageLoader, /openingAlreadyStored/);
assert.match(messageLoader, /cloudSessionDataLoaded=true/);
assert.match(messageLoader, /readDeletedChatTombstones/);
assert.match(messageLoader, /session\.cloudMessagesLoading=false/);

const startChat = between("async function startChat(characterId)", "function visibleSessions");
assert.match(startChat, /\.select\('session_id'\)/);
assert.match(startChat, /\.limit\(1\)\.maybeSingle\(\)/);
assert.doesNotMatch(startChat, /\.select\('session_id,content'\)/);
assert.match(startChat, /onlySessionId:existingRow\.id/);
assert.match(startChat, /loadCloudSessionMessages\(existingRow\.id\)/);
assert.doesNotMatch(startChat, /await loadCloudChatSessions\(\{ id:userId \}\);/);

const localSend = between("if (!window.mySupabase || !isUuid(s.characterId) || !isUuid(s.id))", "if (!walletPreflight('single'))");
assert.match(localSend, /s\.cloudHasUserMessage=true/);

const visible = between("function visibleSessions()", "function chatListDate");
assert.match(visible, /cloudHasUserMessage\s*==\s*null/,
  "legacy chat rows without the new marker must remain discoverable");
assert.match(visible, /lastMessageAt\|\|b\.updatedAt/);

const chatData = between("function chatSessionData(s)", "async function saveChatSessionToCloud");
assert.match(chatData, /hasUserMessage:s\.cloudHasUserMessage===true/);
assert.match(chatData, /s\.cloudHasUserMessage===null \? null : false/);
assert.match(chatData, /s\.cloudRoleplayMeta/);

const saveSession = between("async function saveChatSessionToCloud(s, options = {})", "  const row = {");
const saveSessionBody = between("async function saveChatSessionToCloud(s, options = {})", "async function loadChatSessionAuthorProfiles");
assert.match(saveSession, /cloudSessionDataLoaded/);
assert.match(saveSession, /savedData\.memories/);
assert.match(saveSession, /savedData\.album/);
assert.match(saveSession, /savedData\.roleplayMeta/);
assert.match(saveSession, /existingData\.pendingTurn/);
assert.match(saveSession, /existingData\.openingMessage/);
assert.match(saveSession, /existing\.data\.chat_mode==='encounter'/);
assert.match(saveSession, /existing\.data\.status==='archived'/);
assert.match(saveSession, /const currentRowFields=\[/);
assert.match(saveSession, /s\.cloudCharacterSnapshotLoaded===true\?\[\]:\['character_snapshot'\]/);
assert.match(saveSession, /s\.cloudSessionDataLoaded\?\[\]:\['session_data'\]/);
assert.match(saveSessionBody, /if \(!s\.cloudOwned \|\| s\.cloudSnapshotNeedsRepair===true \|\| !priorSnapshot\.id\) row\.character_snapshot=snapshot/);
assert.doesNotMatch(saveSession, /character_snapshot:snapshot, session_data:/);
assert.match(saveSessionBody, /m\.cloudSynced !== true/,
  "saving a chat must not upsert player messages already persisted in Supabase");
assert.match(saveSessionBody, /message\.cloudSynced=true/,
  "successfully upserted player messages must be marked as synchronized");
assert.match(chatData, /lastMessagePreview/);
assert.match(chatData, /lastMessageAt/);
const safeSaver = between("async function saveChatSessionSafely(s)", "async function refreshWalletBalance");
assert.match(safeSaver, /syncedUserMessageIds/,
  "serialized saves must propagate successful message sync markers to the live session");

const searchJump = between("async function jumpToChatSearchHit(button)", "async function returnChatToLatest(kind)");
assert.equal((searchJump.match(/\.limit\(2\)/g)||[]).length,4,
  "single and group search jumps must load only two neighboring messages on each side of the target");
assert.match(searchJump, /s\.cloudHasMoreMessages=\(b\.data\|\|\[\]\)\.length===2/);
assert.match(searchJump, /groupPrototype\.historyHasMore=\(b\.data\|\|\[\]\)\.length===2/);

const renderConversation = between("function renderConversation()", "function formatMessage");
assert.match(renderConversation, /data-chat-history-action/);
assert.match(renderConversation, /lastRenderedConversationId !== s\.id/);
assert.match(renderConversation, /isConversationEntry\|\|!s\.cloudMessagesLoaded/);
assert.match(renderConversation, /loadCloudSessionMessages\(s\.id,\{refresh:true\}\)/,
  "entering a cached conversation must refresh cloud messages once, without refreshing on every rerender");
assert.match(renderConversation, /refresh:button\.dataset\.chatHistoryAction==='retry'/,
  "the retry control must be able to retry a previously loaded session");
const renderMessages = between("function renderMessages(scroll = true)", "function memorySize");
assert.match(renderMessages, /載入更早的訊息/);
assert.match(renderMessages, /重新載入/);
assert.match(renderMessages, /messageInput\.disabled=true/);
assert.match(renderMessages, /sendButton\.disabled=sending\|\|loadingHistory/);

console.log("Chat lazy hydration, single-session loading, pagination, and legacy safety checks passed.");
