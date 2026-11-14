/* POYOZZ followed-authors presentation module.
 * The app retains ownership of auth, Supabase access, state, routing, and persistence.
 * Followed authors are fetched from the backend in ten-row pages.
 */
(function (global) {
  'use strict';

  let pager = null;
  let renderGeneration = 0;

  global.PoyozzFollowedAuthors = Object.freeze({
    async render(dependencies) {
      const { $, currentUser, getRoute, getSupabaseClient, isUuid, state, author, ICON, e, avatar, card, persist, toast, loadPublicAuthorLatestCharacters } = dependencies;
      const user = currentUser();
      if (!user) return;
      const generation = ++renderGeneration;
      pager?.observer?.disconnect();
      pager = {
        userId:user.uid, offset:0, pageSize:global.PoyozzListPagination.pageSize('followedAuthors'), hasMore:true, loading:false,
        total:0, generation, observer:null, client:getSupabaseClient()
      };
      $('view').innerHTML = '<div class="stack"><div class="followed-authors-title-row"><button type="button" class="ghost followed-authors-back" data-action="back" aria-label="返回上一頁" title="返回上一頁">'+ICON.back+'</button><h1>喜愛作者</h1></div><div class="empty">正在載入追蹤作者…</div></div>';
      await loadPage(dependencies, false);
    }
  });

  async function loadPage(deps, append) {
    const { $, currentUser, getRoute, isUuid, state, author, ICON, e, avatar, card, persist, toast, loadPublicAuthorLatestCharacters } = deps;
    const current = pager;
    if (!current || current.loading || (!current.hasMore && append)) return;
    if (currentUser()?.uid !== current.userId || getRoute()?.page !== 'followed-authors') return;
    current.loading = true;
    try {
      let authors = [];
      let pageAuthorIds = [];
      if (current.client && isUuid(current.userId)) {
        const {data:follows,error,count} = await current.client
          .from('author_follows').select('author_id,created_at',{count:'exact'})
          .eq('follower_id',current.userId)
          .order('created_at',{ascending:false})
          .order('author_id',{ascending:false})
          .range(current.offset,current.offset+current.pageSize-1);
        if (error) throw new Error('讀取追蹤作者失敗：'+error.message);
        pageAuthorIds=[...new Set((follows||[]).map(row=>row.author_id).filter(Boolean))];
        current.total=Number(count??current.total??0);
        if (!append) state.following=[];
        state.following=[...new Set([...(state.following||[]),...pageAuthorIds])];
        if (pageAuthorIds.length) {
          const {data:profiles,error:profilesError}=await current.client
            .from('public_profiles').select('id,handle,nickname,avatar_url,bio,follower_count')
            .in('id',pageAuthorIds);
          if (profilesError) throw new Error('讀取作者資料失敗：'+profilesError.message);
          const byId=new Map((profiles||[]).map(profile=>[profile.id,profile]));
          authors=pageAuthorIds.map(id=>{
            const profile=byId.get(id)||{};
            const fallbackHandle='user_'+String(id).replace(/-/g,'').slice(0,12);
            const info={uid:id,handle:profile.handle||fallbackHandle,
              nickname:profile.nickname||profile.handle||'PersonaX 使用者',
              avatar:profile.avatar_url||'',bio:profile.bio||'',fans:Number(profile.follower_count||0)};
            state.authors[id]=info;
            return info;
          });
        }
      } else {
        const all=(state.following||[]);
        pageAuthorIds=all.slice(current.offset,current.offset+current.pageSize);
        current.total=all.length;
        authors=pageAuthorIds.map(id=>author(id));
      }
      if (currentUser()?.uid!==current.userId || getRoute()?.page!=='followed-authors' || pager!==current) return;

      let charactersByAuthor;
      if(current.client&&pageAuthorIds.length&&typeof loadPublicAuthorLatestCharacters==='function') {
        charactersByAuthor=await loadPublicAuthorLatestCharacters(pageAuthorIds);
      } else {
        charactersByAuthor=new Map();
        for(const info of authors) {
          const items=state.characters.filter(character=>character.visibility==='public'&&character.authorId===info.uid&&
            !String(character.id).startsWith('seed-')&&character.cloudPublic!==false&&character.localOnly!==true&&!character.deletedAt)
            .sort((a,b)=>Number(b.firstPublishedAt||b.createdAt||0)-Number(a.firstPublishedAt||a.createdAt||0));
          charactersByAuthor.set(info.uid,{items:items.slice(0,4),total:items.length});
        }
      }
      if (currentUser()?.uid!==current.userId || getRoute()?.page!=='followed-authors' || pager!==current) return;

      const html=authors.map(info=>{
        const entry=charactersByAuthor.get(info.uid)||{items:[],total:0};
        const latest=(entry.items||[]).slice(0,4);
        const profileButton='<button type="button" class="followed-author-profile-link" data-action="author" data-id="'+e(info.uid)+'" aria-label="前往作者 '+e(info.nickname||'作者')+' 的頁面">'+avatar(info)+'</button>';
        return '<section class="panel stack followed-author-card" style="gap:14px">'+
          '<div class="row between" style="align-items:center;gap:12px"><div class="row" style="min-width:0;gap:10px">'+profileButton+
          '<div style="min-width:0"><button type="button" class="followed-author-name" data-action="author" data-id="'+e(info.uid)+'">'+e(info.nickname||'PersonaX 使用者')+'</button>'+
          '<span class="small muted" style="display:block">公開角色 '+entry.total+' 名</span></div></div>'+
          (entry.total>4?'<button type="button" class="followed-author-more" data-action="author" data-id="'+e(info.uid)+'">MORE</button>':'')+'</div>'+
          (latest.length?'<div class="grid">'+latest.map(character=>card(character)).join('')+'</div>':'<div class="empty">目前沒有公開角色。</div>')+
          '</section>';
      }).join('');

      current.offset+=pageAuthorIds.length;
      current.hasMore=pageAuthorIds.length===current.pageSize;
      current.loading=false;
      if(append) {
        const container=$('followedAuthorsItems');
        if(container&&html)container.insertAdjacentHTML('beforeend',html);
      } else {
        $('view').innerHTML='<div class="stack"><div class="followed-authors-title-row"><button type="button" class="ghost followed-authors-back" data-action="back" aria-label="返回上一頁" title="返回上一頁">'+ICON.back+'</button><div class="row between"><h1 style="margin:0">喜愛作者</h1><span class="small muted">'+current.total+' 位作者</span></div></div>'+
          '<div id="followedAuthorsItems" class="stack">'+(html||'<div class="empty">你還沒有追蹤任何作者。到作者頁點擊「追蹤」，就會在這裡看到作者與最新公開角色。</div>')+'</div>'+
          (current.hasMore?'<div id="followedAuthorsSentinel" class="small muted" style="padding:14px;text-align:center">繼續往下滑動，載入更多作者…</div>':'')+'</div>';
      }
      if(current.hasMore) observeNextPage(deps,current);
      else document.getElementById('followedAuthorsSentinel')?.remove();
      persist();
    } catch(error) {
      current.loading=false;
      console.error('喜愛作者載入失敗：',error);
      if(!append) $('view').innerHTML='<div class="stack"><div class="followed-authors-title-row"><button type="button" class="ghost followed-authors-back" data-action="back" aria-label="返回上一頁" title="返回上一頁">'+ICON.back+'</button><h1>喜愛作者</h1></div><div class="empty">讀取失敗，請重新整理後再試。</div></div>';
      toast(error.message||'讀取喜愛作者失敗。');
    }
  }

  function observeNextPage(deps,current) {
    current.observer?.disconnect();
    const sentinel=document.getElementById('followedAuthorsSentinel');
    if(!sentinel)return;
    current.observer=global.PoyozzListPagination.observeEnd(sentinel,()=>{
      if(pager!==current||current.loading||!current.hasMore)return;
      current.observer?.disconnect();
      void loadPage(deps,true);
    },{rootMargin:'220px 0px'});
  }
})(window);
