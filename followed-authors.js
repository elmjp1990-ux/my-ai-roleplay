/* POYOZZ followed-authors presentation module.
 * The app retains ownership of auth, Supabase access, state, routing, and persistence.
 */
(function (global) {
  'use strict';

  global.PoyozzFollowedAuthors = Object.freeze({
    async render(dependencies) {
      const { $, currentUser, getRoute, getSupabaseClient, isUuid, state, loadPublicSupabaseCharacters, author, ICON, e, avatar, card, persist, toast } = dependencies;
        const user = currentUser();
        if (!user) return;
        $('view').innerHTML = '<div class="stack"><div class="followed-authors-title-row"><button type="button" class="ghost followed-authors-back" data-action="back" aria-label="返回上一頁" title="返回上一頁">'+ICON.back+'</button><h1>喜愛作者</h1></div><div class="empty">正在載入追蹤作者…</div></div>';
      
        try {
          let authors = [];
          const client = getSupabaseClient();
          if (client && isUuid(user.uid)) {
            const {data: follows, error: followsError} = await client
              .from('author_follows').select('author_id, created_at')
              .eq('follower_id', user.uid).order('created_at', {ascending:false});
            if (followsError) throw new Error('讀取追蹤作者失敗：' + followsError.message);
            const authorIds = [...new Set((follows || []).map(row => row.author_id).filter(Boolean))];
            state.following = authorIds;
            if (authorIds.length) {
              const {data: profiles, error: profilesError} = await client
                .from('public_profiles').select('id, handle, nickname, avatar_url, bio, follower_count')
                .in('id', authorIds);
              if (profilesError) throw new Error('讀取作者資料失敗：' + profilesError.message);
              const byId = new Map((profiles || []).map(profile => [profile.id, profile]));
              authors = authorIds.map(id => {
                const profile = byId.get(id) || {};
                const fallbackHandle = 'user_' + String(id).replace(/-/g, '').slice(0, 12);
                const authorInfo = {
                  uid:id,
                  handle:profile.handle || fallbackHandle,
                  nickname:profile.nickname || profile.handle || 'PersonaX 使用者',
                  avatar:profile.avatar_url || '',
                  bio:profile.bio || '',
                  fans:Number(profile.follower_count || 0)
                };
                state.authors[id] = authorInfo;
                return authorInfo;
              });
            }
            await loadPublicSupabaseCharacters();
          } else {
            authors = (state.following || []).map(id => author(id));
          }
      
          if (getRoute()?.page !== 'followed-authors' || currentUser()?.uid !== user.uid) return;
          const html = authors.map(authorInfo => {
            const characters = state.characters
              .filter(character => character.visibility === 'public' &&
                character.authorId === authorInfo.uid &&
                !String(character.id).startsWith('seed-') &&
                character.cloudPublic !== false && character.localOnly !== true &&
                !character.deletedAt)
              .sort((a,b) => Number(b.firstPublishedAt || b.createdAt || 0) -
                Number(a.firstPublishedAt || a.createdAt || 0));
            const latest = characters.slice(0, 4);
            const authorPageButton = `<button type="button" class="followed-author-profile-link" data-action="author" data-id="${e(authorInfo.uid)}" aria-label="前往作者 ${e(authorInfo.nickname || '作者')} 的頁面">${avatar(authorInfo)}</button>`;
            return `<section class="panel stack followed-author-card" style="gap:14px">
              <div class="row between" style="align-items:center;gap:12px">
                <div class="row" style="min-width:0;gap:10px">
                  ${authorPageButton}
                  <div style="min-width:0">
                    <button type="button" class="followed-author-name" data-action="author" data-id="${e(authorInfo.uid)}">${e(authorInfo.nickname || 'PersonaX 使用者')}</button>
                    <span class="small muted" style="display:block">公開角色 ${characters.length} 名</span>
                  </div>
                </div>
                ${characters.length > 4 ? `<button type="button" class="followed-author-more" data-action="author" data-id="${e(authorInfo.uid)}">MORE</button>` : ''}
              </div>
              ${latest.length ? `<div class="grid">${latest.map(character => card(character)).join('')}</div>` : '<div class="empty">目前沒有公開角色。</div>'}
            </section>`;
          }).join('');
          $('view').innerHTML = `<div class="stack"><div class="followed-authors-title-row"><button type="button" class="ghost followed-authors-back" data-action="back" aria-label="返回上一頁" title="返回上一頁">${ICON.back}</button><div class="row between"><h1 style="margin:0">喜愛作者</h1><span class="small muted">${authors.length} 位作者</span></div></div>
            ${html || '<div class="empty">你還沒有追蹤任何作者。到作者頁點擊「追蹤」，就會在這裡看到作者與最新公開角色。</div>'}
          </div>`;
          persist();
        } catch (error) {
          console.error('喜愛作者載入失敗：', error);
          $('view').innerHTML = '<div class="stack"><div class="followed-authors-title-row"><button type="button" class="ghost followed-authors-back" data-action="back" aria-label="返回上一頁" title="返回上一頁">'+ICON.back+'</button><h1>喜愛作者</h1></div><div class="empty">讀取失敗，請重新整理後再試。</div></div>';
          toast(error.message || '讀取喜愛作者失敗。');
        }
    }
  });
})(window);
