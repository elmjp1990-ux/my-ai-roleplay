import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const between = (start, end) => {
  const from = html.indexOf(start);
  assert.notEqual(from, -1, `missing source marker: ${start}`);
  const to = html.indexOf(end, from + start.length);
  assert.notEqual(to, -1, `missing end marker: ${end}`);
  return html.slice(from, to);
};

const chatSessionData = between('function chatSessionData(s) {', 'async function saveChatSessionToCloud(s, options = {})');
const listHydration = between('async function loadCloudChatSessions(user) {', 'async function saveChatSessionSafely(s)');
const singleSessionLoader = between('async function loadCloudChatSessionMessages(session, options = {}) {', 'async function ensureCompleteCloudChatHistory(session) {');
const completeHistoryGuard = between('async function ensureCompleteCloudChatHistory(session) {', 'async function loadCloudChatSessions(user) {');
const startChat = between('async function startChat(characterId) {', 'function visibleSessions() {');
const renderConversation = between('function renderConversation() {', 'function formatMessage(text) {');
const renderMessages = between('function renderMessages(scroll = true) {', 'function memorySize(list) {');
const messageSubmit = between("case 'message': {", "case 'group-persona-settings': {");

assert.match(html, /const CHAT_HISTORY_PAGE_SIZE = 50;/, 'page size must be bounded at 50');
assert.doesNotMatch(listHydration, /from\(['"]chat_messages['"]\)/, 'login/session-list hydration must not fetch message bodies');
assert.match(listHydration, /messagesLoaded:/, 'session metadata must track lazy hydration state');
assert.match(listHydration, /openingMessage/, 'opening message recovery must remain intact');
assert.match(listHydration, /pendingTurn:/, 'pending turn recovery must remain intact');
assert.match(listHydration, /memories:Array\.isArray\(data\.memories\)/, 'memory summaries must remain hydrated');
assert.match(listHydration, /cloudRoleplayMeta:roleplayMeta/, 'roleplay display metadata must remain available');

assert.match(singleSessionLoader, /\.eq\('session_id', session\.id\)/, 'message query must be scoped to one session');
assert.match(singleSessionLoader, /\.limit\(CHAT_HISTORY_PAGE_SIZE \+ 1\)/, 'message query must have a bounded page size');
assert.match(singleSessionLoader, /query\.lt\('created_at', session\.messagesCursor\)/, 'older messages must use cursor pagination');
assert.match(singleSessionLoader, /previousComplete \|\| !session\.messagesHasMore/, 'refreshing a cached complete history must not mark it partial');
assert.match(singleSessionLoader, /renderMessages\(older \|\| wasLoaded \? false : true\)/, 'first page must scroll to newest messages while refreshes preserve scroll');
assert.match(singleSessionLoader, /readDeletedChatTombstones\(uid\)\.sessions\[session\.id\]/, 'deleted-session tombstones must be checked');
assert.match(singleSessionLoader, /session\.cloudOwnerUid !== uid/, 'session owner must be checked before loading');
assert.match(singleSessionLoader, /currentUser\(\)\?\.uid !== uid/, 'account switches must invalidate stale message reads');
assert.match(singleSessionLoader, /new Map\(existing\.map\(message => \[message\.id, message\]\)\)/, 'pagination must deduplicate message IDs');

assert.match(completeHistoryGuard, /while \(session\.messagesHasMore === true\)/, 'full context must be recoverable page by page');
assert.match(completeHistoryGuard, /if \(pending\) await pending/, 'turn submission must wait for in-flight first-page hydration');
assert.match(renderConversation, /loadCloudChatSessionMessages\(s,\{refresh:true\}\)/, 'conversation opening must refresh the selected session only');
assert.match(renderMessages, /load-older-messages/, 'older-message control must be rendered');
assert.match(html, /case 'load-older-messages'/, 'older-message action must be wired');
assert.match(messageSubmit, /ensureCompleteCloudChatHistory\(s\)/, 'turn submission must restore full history before continuing');
assert.match(startChat, /\.select\('session_id'\)/, 'start-chat lookup must not download full message content');
assert.match(html, /lastMessagePreview:/, 'new session saves must persist a lightweight list preview');
assert.match(chatSessionData, /s\.messagesComplete === false && s\.cloudRoleplayMeta/, 'partial history saves must preserve remote roleplay metadata');
assert.match(chatSessionData, /s\.messagesComplete === false \? \(s\.lastMessagePreview/, 'partial history saves must preserve the latest remote preview');

console.log('Chat history lazy-pagination regression checks passed.');
