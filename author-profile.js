/* POYOZZ author profile presentation module.
 * Auth, route state, Supabase access, and rendering helpers remain app-owned.
 */
(function (global) {
  'use strict';

  const authorPages = new Map();
  const CHARACTER_FIELDS = 'id,author_id,name,gender,age,avatar_url,avatar_video_path,is_nsfw,visibility,review_status,intro,race,style,tags,created_at,first_published_at,latest_eligible';

  function pageFor(authorId, pagination) {
    if (!authorPages.has(authorId)) {
      authorPages.set(authorId, {
        characters: [], offset: 0, hasMore: true, loading: false,
        loaded: false, observer: null, pageSize: pagination.pageSize('explore')
      });
    }
    return authorPages.get(authorId);
  }

  async function loadAuthorCharacters(authorId, page, dependencies) {
    if (page.loading || !page.hasMore) return;
    const client = dependencies.getSupabaseClient();
    if (!client) return;
    page.loading = true;
    try {
      const result = await dependencies.loadAuthorCharacterPage(authorId, page.offset);
      const mapped = Array.isArray(result?.items) ? result.items : [];
      page.characters = dependencies.PoyozzListPagination.mergeUnique(
        page.characters, mapped, character => character.id
      );
      dependencies.state.characters = dependencies.PoyozzListPagination.mergeUnique(
        dependencies.state.characters, mapped, character => character.id
      );
      page.offset += mapped.length;
      page.hasMore = result?.hasMore === true;
      page.loaded = true;
    } catch (error) {
      page.error = error;
      throw error;
    } finally {
      page.loading = false;
    }
  }

  global.PoyozzAuthorProfile = Object.freeze({
    render(dependencies) {
      const {
        route, state, currentUser, author, isUuid, getSupabaseClient,
        publicAuthorProfileLoaded, hydratePublicAuthorProfile,
        $, e, avatar, card, refreshAuthorFollowState, PoyozzListPagination,
        rerender
      } = dependencies;
      const authorId = route.id;
      const a = author(authorId);
      const needsPublicProfile = !!(getSupabaseClient() && isUuid(authorId) && !publicAuthorProfileLoaded.has(authorId));
      if (needsPublicProfile) void hydratePublicAuthorProfile(authorId);
      const following = state.following.includes(a.uid);
      const page = pageFor(authorId, PoyozzListPagination);
      if(!page.loaded&&typeof dependencies.loadAuthorCharacterPage!=='function'){
        page.characters=state.characters.filter(character=>
          character.visibility==='public'&&character.authorId===authorId&&
          !String(character.id).startsWith('seed-')&&character.cloudPublic!==false&&character.localOnly!==true
        );
        page.loaded=true;page.hasMore=false;
      }

      const renderPage = () => {
        if (route.page !== 'author' || route.id !== authorId) return;
        page.observer?.disconnect();
        const list = page.characters;
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
            <div class="grid" id="authorCharacterGrid">${list.map(character => card(character)).join('') ||
              (page.loaded ? '<div class="empty">目前沒有公開角色。</div>' : '<div class="empty">正在載入公開角色…</div>')}</div>
            ${page.hasMore ? '<div id="authorCharacterSentinel" class="small muted" style="text-align:center;padding:12px">繼續往下滑動，載入更多角色…</div>' : ''}
          </div>`;
        const sentinel = $('authorCharacterSentinel');
        if (sentinel && !page.loading) {
          page.observer = PoyozzListPagination.observeEnd(sentinel, async () => {
            try {
              await loadAuthorCharacters(authorId, page, dependencies);
              rerender();
            } catch (error) {
              console.warn('作者公開角色載入失敗：', error?.message || error);
            }
          });
        }
      };

      renderPage();
      if (!page.loaded && !page.loading && typeof dependencies.loadAuthorCharacterPage==='function') {
        void loadAuthorCharacters(authorId, page, dependencies).then(() => {
          if (route.page === 'author' && route.id === authorId) rerender();
        }).catch(error => {
          console.warn('作者公開角色載入失敗：', error?.message || error);
          if (route.page === 'author' && route.id === authorId) {
            const grid = $('authorCharacterGrid');
            if (grid) grid.innerHTML = '<div class="empty">公開角色載入失敗，請稍後再試。</div>';
          }
        });
      }
      if (!needsPublicProfile) void refreshAuthorFollowState(a.uid);
    }
  });
})(window);
