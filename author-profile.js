/* POYOZZ author profile presentation module.
 * Auth, route state, Supabase access, and rendering helpers remain app-owned.
 */
(function (global) {
  'use strict';

  global.PoyozzAuthorProfile = Object.freeze({
    render(dependencies) {
      const {
        route, state, currentUser, author, isUuid, getSupabaseClient,
        publicAuthorProfileLoaded, hydratePublicAuthorProfile,
        $, e, avatar, card, refreshAuthorFollowState
      } = dependencies;
      const a = author(route.id);
      const needsPublicProfile=!!(getSupabaseClient()&&isUuid(route.id)&&!publicAuthorProfileLoaded.has(route.id));
      if(needsPublicProfile)void hydratePublicAuthorProfile(route.id);
      const following = state.following.includes(a.uid);
      const list = state.characters.filter(c => c.visibility === 'public' && c.authorId === a.uid &&
        !String(c.id).startsWith('seed-') && c.cloudPublic !== false && c.localOnly !== true);
      $('view').innerHTML = `
        <div class="stack">
          <section class="panel stack">
            <div class="row">${avatar(a)}
              <div><h1 style="margin:0">@${e(a.nickname)}</h1>
                <p class="small muted" style="margin:6px 0">UID：${e(a.uid)}</p>
              </div>
            </div>
            <p class="prose muted bio-scroll">${e(a.bio || '尚未填寫簡介')}</p>
            <div class="row between wrap">
              <strong id="authorFollowerCount">粉絲 ${Number(a.fans || 0)}</strong>
              <div class="row">
                ${currentUser()?.uid !== a.uid ? `<button data-action="follow"
                  data-id="${e(a.uid)}">${following ? '已追蹤' : '追蹤'}</button>` : ''}
                <button data-action="share" data-kind="author" data-id="${e(a.uid)}">↗ 分享</button>
              </div>
            </div>
          </section>
          <h2>公開角色</h2>
          <div class="grid">${list.map(c => card(c)).join('') || '<div class="empty">目前沒有公開角色。</div>'}</div>
        </div>`;
      if(!needsPublicProfile)void refreshAuthorFollowState(a.uid);
    }
  });
})(window);
