/* POYOZZ comment rendering module.
 * Comment fetching, privacy filtering, and mutations remain app-owned.
 */
(function (global) {
  'use strict';

  global.PoyozzCommentRenderer = Object.freeze({
    render(dependencies) {
      const {
        $, state, route, currentUser, currentCharacter,
        author, avatar, e, timeText, cloudCommentHydrationCache
      } = dependencies;
      if (!document.getElementById('whisper-redacted-style')) {
        const style=document.createElement('style');style.id='whisper-redacted-style';
        style.textContent='.whisper-redacted-avatar{background:#e5e7eb!important;color:#6b7280!important;display:flex;align-items:center;justify-content:center;font-weight:700;border:1px solid #d1d5db}';
        document.head.appendChild(style);
      }
      if (!$('comments')) return;
      const allComments = state.comments[route.id] || [];
      const cacheUid=currentUser()?.uid||null;
      const cacheKey=(cacheUid||'anonymous')+':'+route.id;
      const cached=cloudCommentHydrationCache.get(cacheKey);
      if(cached)cached.rows=allComments;
      const character = currentCharacter();
      const uid = currentUser()?.uid;
      const list = allComments;
      $('comments').innerHTML = list.map(c => {
        const a = author(c.authorId);
        const liked = (c.likes || []).includes(uid);
        const parent = allComments.find(p => p.id === c.parentId);
        return `
          <article class="comment ${c.parentId ? 'reply' : ''}">
            <div class="row">
              ${c.redacted && c.whisper && !c.parentId ? '<div class="avatar whisper-redacted-avatar" aria-label="悄悄話">悄</div>' : avatar(a)}
              <div class="grow">
                ${c.redacted && c.whisper && !c.parentId ? '<span class="small muted">悄悄話</span>' : `<button class="author-link" data-action="author" data-id="${e(a.uid)}">@${e(a.nickname)}</button>${character && c.authorId === character.authorId ? '<span class="small muted" style="margin-left:6px">(作者)</span>' : ''}${c.whisper ? '<span class="comment-whisper-label" style="margin-left:6px">悄悄話</span>' : ''}`}
                <div class="small muted">${e(timeText(c.at))}${c.edited ? ' · 已修改' : ''}</div>
              </div>
            </div>
            ${parent && !c.redacted ? `<p class="small muted" style="margin:10px 0">回覆 @${e(author(parent.authorId).nickname)}</p>` : ''}
            <p class="prose ${c.deleted ? 'muted' : ''}" style="margin:12px 0">
              ${c.deleted ? '該筆評論已被刪除' : e(c.text)}
            </p>
            ${!c.deleted && !c.redacted ? `<div class="comment-like-row"><button class="comment-like-button ${liked ? 'on' : ''}" data-action="comment-like" data-id="${e(c.id)}" aria-pressed="${liked}"><span class="like-symbol">${liked ? '♥' : '♡'}</span><span>${(c.likes || []).length}</span></button></div><div class="comment-tools">
              <button data-action="reply" data-id="${e(c.id)}">回覆</button>
              <button data-action="translation">翻譯</button>
              <button data-action="comment-menu" data-id="${e(c.id)}">⋯</button>
            </div>` : ''}
          </article>`;
      }).join('') || '<div class="empty">還沒有評論。</div>';
    }
  });
})(window);
