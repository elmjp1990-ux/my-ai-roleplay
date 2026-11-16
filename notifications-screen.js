/* POYOZZ notifications screen presentation.
 * Notification persistence and read actions remain owned by the main application.
 */
(function installPoyozzNotifications(global) {
  'use strict';

  let pager = { filterKey: null, limit: 10, observer: null };

  function destroy() {
    pager.observer?.disconnect();
    pager.observer = null;
  }

  function render(dependencies) {
    const { route, state, $, e, timeText, PoyozzListPagination } = dependencies;
    const unread = route.unread;
    const filterKey = unread ? 'unread' : 'all';
    if (pager.filterKey !== filterKey) {
      destroy();
      pager = {
        filterKey,
        limit: PoyozzListPagination?.pageSize('notifications') || 10,
        observer: null
      };
    }
    const filtered = state.notifications.filter(item => !unread || !item.read);
    const list = filtered.slice(0, pager.limit);
    $('view').innerHTML = `<div class="stack">
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
      ${filtered.length > pager.limit ? '<div id="notificationsSentinel" class="small muted" style="text-align:center;padding:16px">向下滑動載入更多通知…</div>' : ''}
    </div>`;
    destroy();
    const sentinel = $('notificationsSentinel');
    if (sentinel) pager.observer = PoyozzListPagination?.observeEnd(sentinel, () => {
      if (route.page !== 'notifications') return;
      pager.limit += PoyozzListPagination?.pageSize('notifications') || 10;
      render(dependencies);
    });
  }

  global.PoyozzNotifications = Object.freeze({ render, destroy });
})(window);
