import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync('notifications-view.js', 'utf8');
const context = { window: {} };
vm.runInNewContext(source, context);
const view = context.window.PoyozzNotificationsView;
assert.equal(typeof view?.render, 'function');

const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, char => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
}[char]));
const notifications = [
  { id: '1', title: '<unsafe>', body: 'First', at: '2026-11-15T00:00:00Z', read: false },
  { id: '2', title: 'Read', body: 'Second', at: '2026-11-14T00:00:00Z', read: true },
  { id: '3', title: 'Third', body: 'Third body', at: '2026-11-13T00:00:00Z', read: false },
];
const all = view.render({
  notifications, unread: false, limit: 2, e: escapeHtml, timeText: value => String(value),
});
assert.equal(all.hasMore, true);
assert.match(all.html, /&lt;unsafe&gt;/);
assert.match(all.html, /data-action="read-all"/);
assert.match(all.html, /data-action="read-notice" data-id="1"/);
assert.match(all.html, /notificationsSentinel/);
assert.doesNotMatch(all.html, /data-id="3"/);

const unread = view.render({
  notifications, unread: true, limit: 10, e: escapeHtml, timeText: value => String(value),
});
assert.equal(unread.hasMore, false);
assert.match(unread.html, /data-value="unread"/);
assert.match(unread.html, /First/);
assert.match(unread.html, /Third body/);
assert.doesNotMatch(unread.html, /Second/);

const empty = view.render({
  notifications: [], unread: false, limit: 10, e: escapeHtml, timeText: value => String(value),
});
assert.match(empty.html, /目前沒有訊息/);
assert.equal(empty.hasMore, false);
assert.equal(/\bfetch\s*\(|\.from\s*\(|\.rpc\s*\(/.test(source), false,
  'presentation module must not own network or database access');

console.log('Notifications view module contract passed.');
