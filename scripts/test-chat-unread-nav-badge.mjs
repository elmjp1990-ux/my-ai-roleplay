import fs from 'node:fs';
import assert from 'node:assert/strict';

const html = fs.readFileSync('index.html', 'utf8');
const between = (start, end) => {
  const a = html.indexOf(start);
  const b = html.indexOf(end, a);
  assert.ok(a >= 0 && b > a, 'Missing section ' + start);
  return html.slice(a, b);
};

const nav = between('function chatNavUnreadCount(){', 'function renderShell() {');
assert.match(nav, /chatHasUnreadAssistantMessage/);
assert.match(nav, /groupPreviewLastAssistantAt/);
assert.match(nav, /groupChatReadAt/);
assert.match(nav, /count>99\?'99\+'/);
assert.match(nav, /99 則以上未讀訊息/);
assert.ok(html.includes('nav-unread-badge'));
assert.ok(html.includes("page === 'chat' ? '<span class=\"nav-icon-wrap\">'+ICON.chat+chatNavUnreadBadge()+'</span>' : ICON["));
assert.ok(html.includes('.nav-icon-wrap{position:relative'));
assert.doesNotMatch(html, /\\\\n\\.nav-btn/);

const send = between('async function groupSendTurn() {', 'async function groupRefreshList()');
assert.match(send, /g\.groupPreviews\[activeGroupId\]=\{group_id:activeGroupId/);
assert.match(send, /refreshChatEntryList\(\);\s*renderShell\(\);/);

console.log('Chat unread badge and group reply refresh contracts passed.');
