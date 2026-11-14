/* POYOZZ notifications list presentation.
 * Notification state, filtering rules, pagination and mutations remain app-owned.
 */
(function (global) {
  'use strict';

  function render({ notifications, unread, limit, e, timeText }) {
    const filtered = (Array.isArray(notifications) ? notifications : [])
      .filter(item => !unread || !item.read);
    const list = filtered.slice(0, Math.max(0, Number(limit) || 0));
    return {
      hasMore: filtered.length > list.length,
      html: `<div class="stack">
        <div class="row between"><h1 style="margin:0">系統通知</h1>
          <button data-action="read-all">全部已讀</button></div>
        <div class="tabs">
          <button class="tab ${!unread ? 'active' : ''}" data-action="notice-tab">全部訊息</button>
          <button class="tab ${unread ? 'active' : ''}" data-action="notice-tab" data-value="unread">未讀訊息</button>
        </div>
        <div>${list.map(item => `<article class="notice">
          <div class="row between"><h3 style="margin:0">${item.read ? '' : '● '}${e(item.title)}</h3>
            ${!item.read ? `<button data-action="read-notice" data-id="${e(item.id)}">已讀</button>` : ''}</div>
          <p class="muted" style="margin:12px 0">${e(item.body)}</p>
          <span class="small muted">${e(timeText(item.at))}</span>
        </article>`).join('') || '<div class="empty">目前沒有訊息。</div>'}</div>
        ${filtered.length > list.length ? '<div id="notificationsSentinel" class="small muted" style="text-align:center;padding:16px">向下滑動載入更多通知…</div>' : ''}
      </div>`,
    };
  }

  global.PoyozzNotificationsView = Object.freeze({ render });
})(window);
