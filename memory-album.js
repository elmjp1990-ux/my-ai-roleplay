(function(){
  const BUCKET='personax-memory-photos';
  const urlCache=new WeakMap();
  const dateLabel=value=>{const d=new Date(value);return Number.isNaN(d.getTime())?'日期不明':d.toLocaleDateString('zh-TW',{year:'numeric',month:'2-digit',day:'2-digit'});};
  function albumMount(type,id){
    return '<section class="memory-album-stack" data-memory-album-type="'+e(type)+'" data-memory-album-id="'+e(id)+'">'+
      '<p class="small muted" style="margin:0 0 12px">回憶相簿可保存一年，請記得即時下載哦</p>'+
      '<div class="panel stack" style="gap:10px;padding:12px;margin-bottom:14px">'+
      '<label class="field"><span>回憶名稱</span><input id="memoryAlbumCaption" maxlength="80" placeholder="例如：第一次遇見"></label>'+
      '<label class="field"><span>上傳回憶相片（JPEG、PNG、WebP，單張上限 10 MB）</span><input id="memoryAlbumFile" type="file" accept="image/jpeg,image/png,image/webp" data-album-type="'+e(type)+'" data-album-id="'+e(id)+'"></label></div>'+
      '<div id="memoryAlbumItems" class="memory-album-items"><div class="empty">正在讀取回憶相簿…</div></div></section>';
  }
  const albumPageStates=new Map(),MAX_ALBUM_PAGE_STATES=8;
  function getAlbumPageState(key){const pager=albumPageStates.get(key);if(pager){albumPageStates.delete(key);albumPageStates.set(key,pager);}return pager||null;}
  function rememberAlbumPageState(key,pager){albumPageStates.delete(key);albumPageStates.set(key,pager);while(albumPageStates.size>MAX_ALBUM_PAGE_STATES)albumPageStates.delete(albumPageStates.keys().next().value);}
  async function loadAlbum(type,chatId,options={}){
    const mount=$('memoryAlbumItems');if(!mount)return;
    const client=window.mySupabase;
    if(!client||!currentUser()?.uid){mount.innerHTML='<div class="empty">請先登入，才能查看與保存回憶相片。</div>';return;}
    const key=type+':'+chatId;
    let pager=getAlbumPageState(key);
    if(!options.loadMore||!pager){pager=window.PoyozzListPagination.createState('memoryPhotos',{ids:new Set()});rememberAlbumPageState(key,pager);mount.innerHTML='';}
    if(pager.loading||!pager.hasMore)return;
    pager.loading=true;
    const uid=currentUser()?.uid;
    try{
      const {data:{user},error:authError}=await client.auth.getUser();
      if(authError||!user||user.id!==uid||currentUser()?.uid!==uid)throw new Error('登入狀態驗證失敗，請重新登入。');
      const pageSize=window.PoyozzListPagination?.pageSize('memoryPhotos')||10;
      const {data,error}=await client.from('chat_memory_photos').select('id,owner_id,chat_type,session_id,group_id,storage_path,caption,created_at,expires_at')
        .eq('owner_id',user.id).eq('chat_type',type).eq(type==='single'?'session_id':'group_id',chatId)
        .eq('status','active').is('deleted_at',null).gt('expires_at',new Date().toISOString())
        .order('created_at',{ascending:false}).order('id',{ascending:false})
        .range(pager.offset,pager.offset+pageSize-1);
      if(error)throw error;
      if(!mount.isConnected||currentUser()?.uid!==uid)return;
      const rows=(data||[]).filter(photo=>!pager.ids.has(photo.id));
      const cards=await Promise.all(rows.map(async photo=>{
        let imageUrl='';
        try{imageUrl=await getMemoryPhotoSignedUrl(photo.storage_path)||'';}catch(signedError){console.warn('相簿簽名網址取得失敗',signedError?.message);}
        pager.ids.add(photo.id);
        const thumbnail=imageUrl
          ? '<button type="button" class="memory-photo-thumb" data-action="memory-photo-open" data-id="'+e(photo.id)+'" aria-label="開啟相片"><img src="'+e(imageUrl)+'" alt="'+e(photo.caption||'回憶相片')+'" loading="lazy"></button>'
          : '<div class="memory-photo-thumb" style="display:grid;place-items:center;color:var(--muted);font-size:11px;padding:6px;text-align:center">圖片檔案遺失<br>仍可刪除紀錄</div>';
        return {
          photo,
          cached:{url:imageUrl,photo},
          html:'<article class="memory-photo-row">'+thumbnail+
            '<div class="memory-photo-details"><div class="memory-photo-title-edit"><strong>'+e(photo.caption||'回憶快照')+'</strong>'+(imageUrl?'<button type="button" class="ghost memory-photo-icon" data-action="memory-photo-edit" data-id="'+e(photo.id)+'" aria-label="修改標題" title="修改標題">✎</button>':'')+'</div><span class="small muted">'+e(dateLabel(photo.created_at))+'</span><span class="memory-photo-expiry">到期日：'+e(dateLabel(photo.expires_at))+'</span></div>'+
            '<div class="memory-photo-actions"><button type="button" class="ghost memory-photo-icon" data-action="memory-photo-delete" data-id="'+e(photo.id)+'" aria-label="刪除相片" title="刪除相片">🗑</button></div></article>'
        };
      }));
      if(!mount.isConnected||currentUser()?.uid!==uid)return;
      const html=cards.map(card=>card.html).join('');
      if(html){
        mount.insertAdjacentHTML('beforeend',html);
        const renderedRows=mount.querySelectorAll('.memory-photo-row');
        cards.forEach((card,index)=>urlCache.set(renderedRows[renderedRows.length-cards.length+index],card.cached));
      }
      pager.offset+=((data||[]).length);
      pager.hasMore=(data||[]).length===pageSize;
      mount.querySelector('[data-memory-photos-more]')?.remove();
      if(pager.hasMore){
        mount.insertAdjacentHTML('beforeend','<button type="button" class="button secondary" data-memory-photos-more data-album-type="'+e(type)+'" data-album-id="'+e(chatId)+'">載入更多相片</button>');
      }else if(!pager.ids.size){
        mount.innerHTML='<div class="empty">目前還沒有回憶相片哦</div>';
      }
    }catch(err){
      console.error('讀取回憶相簿失敗',err);
      mount.querySelector('[data-memory-photos-more]')?.remove();
      if(!pager.ids.size)mount.innerHTML='<div class="empty">相簿讀取失敗：'+e(err.message||'請稍後重試。')+'</div>';
      else mount.insertAdjacentHTML('beforeend','<div class="empty">載入更多相片失敗，請稍後再試。</div>');
    }finally{pager.loading=false;}
  }
  async function compressMemoryImage(file){
    const result=await window.PoyozzImageCompression.compress(file,{
      decoder:'bitmap',
      maxEdge:1200,
      targetBytes:450*1024,
      minScale:.25,
      scaleFactor:.85,
      maxOutputBytes:1024*1024,
      contextAttributes:{alpha:false},
      formats:[{type:'image/webp',qualities:[.80,.72,.64,.56,.48],background:'#fff'}],
      rejectOnEncodeFailure:true,
      decodeError:'目前裝置無法讀取圖片。',
      contextError:'目前裝置無法壓縮圖片。',
      encodeError:'圖片壓縮失敗。',
      tooLargeError:'圖片壓縮後仍超過 1 MB，請改選較小的圖片。'
    });
    return new File([result.blob],(file.name.replace(/\.[^.]+$/,'')||'memory-photo')+'.webp',{type:'image/webp',lastModified:Date.now()});
  }
  // Future AI-generated memory images must use this same mobile-first encoder before Storage upload.
  window.compressMemoryImageForStorage=compressMemoryImage;
  function setAlbumUploadStatus(input,message,isError=false){
    const stack=input.closest('.memory-album-stack');
    if(!stack)return;
    let status=stack.querySelector('[data-memory-upload-status]');
    if(!status){
      status=document.createElement('div');status.dataset.memoryUploadStatus='true';
      status.className='small';status.setAttribute('role','status');status.setAttribute('aria-live','polite');
      const items=stack.querySelector('#memoryAlbumItems');
      if(items)stack.insertBefore(status,items);else stack.appendChild(status);
    }
    status.textContent=message;
    status.style.color=isError?'var(--danger, #b42318)':'var(--muted, #667085)';
  }
  async function uploadAlbum(input){
    const type=input.dataset.albumType,chatId=input.dataset.albumId,file=input.files?.[0];
    if(!file)return;
    const caption=$('memoryAlbumCaption')?.value.trim()||'回憶快照';
    if(!['single','group'].includes(type)||!isUuid(chatId)){input.value='';toast('無法確認相片所屬聊天，請重新開啟相簿。');return;}
    if(!['image/jpeg','image/png','image/webp'].includes(file.type)){input.value='';toast('相片格式僅支援 JPEG、PNG 或 WebP。');return;}
    if(file.size>10*1024*1024){input.value='';toast('單張相片不可超過 10 MB，請先壓縮後再上傳。');return;}
    const client=window.mySupabase;
    if(!client||!currentUser()?.uid){input.value='';toast('請先登入後再上傳相片。');return;}
    let path='';
    input.disabled=true;
    setAlbumUploadStatus(input,'正在壓縮並上傳相片，請稍候…');
    toast('正在上傳回憶相片，請稍候…');
    try{
      const {data:{user},error:authError}=await client.auth.getUser();
      if(authError||!user||user.id!==currentUser()?.uid)throw new Error('登入狀態驗證失敗，請重新登入。');
      const compressed=await compressMemoryImage(file);
      const ext='webp';
      path=user.id+'/'+type+'/'+chatId+'/'+(crypto.randomUUID?crypto.randomUUID():id())+'.'+ext;
      const {error:upError}=await client.storage.from(BUCKET).upload(path,compressed,{contentType:'image/webp',upsert:false,cacheControl:'3600'});
      if(upError)throw upError;
      const created=new Date(),expires=new Date(created);expires.setFullYear(expires.getFullYear()+1);
      const {error:dbError}=await client.from('chat_memory_photos').insert({
        owner_id:user.id,chat_type:type,session_id:type==='single'?chatId:null,group_id:type==='group'?chatId:null,
        storage_path:path,caption:caption.slice(0,80),created_at:created.toISOString(),expires_at:expires.toISOString(),status:'active'
      });
      if(dbError)throw dbError;
      input.value='';if($('memoryAlbumCaption'))$('memoryAlbumCaption').value='';
      toast('回憶相片已保存。保存期限為一年，實際自動清理排程仍待完成。');
      setAlbumUploadStatus(input,'上傳成功，正在更新相簿…');
      await loadAlbum(type,chatId);
      setAlbumUploadStatus(input,'相片已保存並更新相簿。');
    }catch(err){
      if(path){const {error:cleanup}=await client.storage.from(BUCKET).remove([path]);if(cleanup)console.error('清理未完成上傳檔案失敗',cleanup.message);}
      console.error('回憶相片上傳失敗',err);
      setAlbumUploadStatus(input,'上傳失敗：'+(err.message||'請稍後重試。'),true);
      toast('相片上傳失敗：'+(err.message||'請稍後重試。'));
    }finally{
      input.disabled=false;
    }
  }
  async function applySingleMemoryPhotoBackground(session,panel){
    const client=window.mySupabase,uid=currentUser()?.uid;
    const match=String(session?.background||'').match(/^memory-photo:([0-9a-f-]{36})$/i);
    if(!client||!uid||!match||session.cloudOwnerUid!==uid){panel.style.setProperty('--chat-photo','none');return;}
    try{
      const {data:photo,error}=await client.from('chat_memory_photos').select('id,storage_path')
        .eq('id',match[1]).eq('owner_id',uid).eq('chat_type','single').eq('session_id',session.id)
        .eq('status','active').is('deleted_at',null).gt('expires_at',new Date().toISOString()).maybeSingle();
      if(error)throw error;
      if(!photo){session.background='none';persist();panel.style.setProperty('--chat-photo','none');return;}
      const signedUrl=await getMemoryPhotoSignedUrl(photo.storage_path);
      if(!signedUrl)throw new Error('無法取得背景圖片。');
      if(currentSession()?.id===session.id)panel.style.setProperty('--chat-photo','url('+JSON.stringify(signedUrl)+')');
    }catch(err){console.error('讀取單聊相簿背景失敗',err);panel.style.setProperty('--chat-photo','none');}
  }
  async function applyGroupMemoryPhotoBackground(group,panel){
    const client=window.mySupabase,uid=currentUser()?.uid,photoId=group?.backgroundMemoryPhotoId;
    if(!client||!uid||!photoId||groupPrototype.active?.id!==group.id){panel.style.setProperty('--chat-photo','none');return;}
    try{
      const {data:photo,error}=await client.from('chat_memory_photos').select('id,storage_path')
        .eq('id',photoId).eq('owner_id',uid).eq('chat_type','group').eq('group_id',group.id)
        .eq('status','active').is('deleted_at',null).gt('expires_at',new Date().toISOString()).maybeSingle();
      if(error)throw error;
      if(!photo){
        panel.style.setProperty('--chat-photo','none');
        const {data:cleared,error:clearError}=await client.from('chat_groups')
          .update({background_mode:'none',background_memory_photo_id:null,updated_at:new Date().toISOString()})
          .eq('id',group.id).eq('owner_id',uid).eq('background_mode','memory').eq('background_memory_photo_id',photoId)
          .select('id').maybeSingle();
        if(clearError)console.warn('失效群組背景已回退畫面，但資料庫設定清理失敗',clearError.message);
        if(cleared&&groupPrototype.active?.id===group.id){group.backgroundMode='none';group.backgroundMemoryPhotoId=null;}
        return;
      }
      const signedUrl=await getMemoryPhotoSignedUrl(photo.storage_path);
      if(!signedUrl)throw new Error('無法取得群組背景圖片。');
      if(groupPrototype.active?.id===group.id)panel.style.setProperty('--chat-photo','url('+JSON.stringify(signedUrl)+')');
    }catch(err){console.error('讀取群組相簿背景失敗',err);panel.style.setProperty('--chat-photo','none');}
  }
  window.applySingleMemoryPhotoBackground=applySingleMemoryPhotoBackground;
  window.applyGroupMemoryPhotoBackground=applyGroupMemoryPhotoBackground;
  const chatRenderLifecycle=window.PoyozzChatRenderLifecycle;
  if(chatRenderLifecycle){
    chatRenderLifecycle.register('afterSingleConversation','memory-album.single-background',({session,panel})=>{
      const targetSession=session||currentSession(),targetPanel=panel||$('view').querySelector('.chat-main');
      if(targetPanel&&String(targetSession?.background||'').startsWith('memory-photo:'))void applySingleMemoryPhotoBackground(targetSession,targetPanel);
    });
    chatRenderLifecycle.register('afterGroupConversation','memory-album.group-background',({group,panel})=>{
      const targetGroup=group||groupPrototype.active,targetPanel=panel||$('view').querySelector('.chat-main');
      if(!targetPanel)return;
      if(targetGroup?.backgroundMode==='memory'&&targetGroup.backgroundMemoryPhotoId)void applyGroupMemoryPhotoBackground(targetGroup,targetPanel);
      else if((targetGroup?.backgroundMode||'avatar')==='none')targetPanel.style.setProperty('--chat-photo','none');
      else applyGroupChatBackground();
    });
    chatRenderLifecycle.register('renderSingleOverlay','memory-album.single-overlay',({kind,session,panel})=>{
      if(kind!=='album')return false;
      const targetSession=session||currentSession(),targetPanel=panel||$('view').querySelector('.chat-main');
      if(!targetSession||!targetPanel)return false;
      targetPanel.querySelectorAll('.chat-overlay').forEach(node=>node.remove());
      const overlay=document.createElement('section');overlay.className='chat-overlay';overlay.setAttribute('aria-label','回憶相簿');
      overlay.innerHTML='<div class="overlay-heading"><button class="ghost" data-action="back" aria-label="返回">'+ICON.back+'</button><div><h2>回憶相簿</h2><p class="small muted" style="margin:0">回憶相簿可保存一年，請記得即時下載哦</p></div></div>'+albumMount('single',targetSession.id);
      targetPanel.appendChild(overlay);
      void loadAlbum('single',targetSession.id);
      return true;
    });
    chatRenderLifecycle.register('renderGroupOverlay','memory-album.group-overlay',({kind,group,panel})=>{
      if(kind!=='album')return false;
      const targetGroup=group||groupPrototype.active,targetPanel=panel||$('view').querySelector('.chat-main');
      if(!targetGroup||!targetPanel)return false;
      targetPanel.querySelectorAll('.chat-overlay').forEach(node=>node.remove());
      const overlay=document.createElement('section');overlay.className='chat-overlay';overlay.setAttribute('aria-label','群組回憶相簿');
      overlay.innerHTML='<div class="overlay-heading"><button class="ghost" data-action="back" aria-label="返回">'+ICON.back+'</button><div><h2>回憶相簿</h2><p class="small muted" style="margin:0">回憶相簿可保存一年，請記得即時下載哦</p></div></div>'+albumMount('group',targetGroup.id);
      targetPanel.appendChild(overlay);
      void loadAlbum('group',targetGroup.id);
      return true;
    });
  }
  renderChatAlbumPage=function(){
    const s=currentSession();
    const content=s&&s.cloudOwned&&s.cloudOwnerUid===currentUser()?.uid?albumMount('single',s.id):
      '<section class="panel"><p class="muted">請先開啟一段已同步的聊天，再從聊天頁進入該段對話的回憶相簿。</p></section>';
    $('view').innerHTML='<div class="stack form-width"><div class="row between" style="align-items:center;gap:12px"><h1 style="margin:4px 0 0">回憶相簿</h1><button type="button" data-action="nav" data-page="chat">返回聊天</button></div>'+content+'</div>';
    if(s&&s.cloudOwned&&s.cloudOwnerUid===currentUser()?.uid)void loadAlbum('single',s.id);
  };
  if(route.page==='conversation'&&String(currentSession()?.background||'').startsWith('memory-photo:')){
    const panel=$('view').querySelector('.chat-main');if(panel)void applySingleMemoryPhotoBackground(currentSession(),panel);
  }
  async function downloadCompressedMemoryPhoto(cached){
    try{const client=window.mySupabase;let url=cached.url;let response=await fetch(url);if(!response.ok){invalidateMemoryPhotoSignedUrl(cached.photo.storage_path,cached.photo.owner_id);url=await getMemoryPhotoSignedUrl(cached.photo.storage_path);if(!url)throw new Error('下載連結失效。');response=await fetch(url);}if(!response.ok)throw new Error('下載連結已失效，請重新開啟相簿後再試。');const blob=await response.blob(),objectUrl=URL.createObjectURL(blob);const a=document.createElement('a');a.href=objectUrl;a.download=(cached.photo.caption||'personax-memory')+'.webp';document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(objectUrl),1500);}catch(error){toast('下載失敗：'+(error.message||'請重新開啟相簿後再試。'));}
  }
  document.addEventListener('change',event=>{
    const input=event.target;
    if(input?.id==='memoryAlbumFile')void uploadAlbum(input);
  });
  document.addEventListener('click',event=>{
    const more=event.target.closest('[data-memory-photos-more]');
    if(!more)return;
    more.disabled=true;
    void loadAlbum(more.dataset.albumType,more.dataset.albumId,{loadMore:true});
  });
  document.addEventListener('click',async event=>{
    const button=event.target.closest('[data-action="memory-photo-open"],[data-action="memory-photo-download"],[data-action="memory-photo-background"],[data-action="memory-photo-edit"],[data-action="memory-photo-delete"],[data-action="memory-photo-save-title"],[data-action="memory-photo-cancel-title"]');
    if(!button)return;
    const row=button.closest('.memory-photo-row');
    const cached=row&&urlCache.get(row);
    const action=button.dataset.action;
    if(!cached){toast('相簿資料已更新，請重新開啟相簿後再試。');return;}
    if(!cached.url && action!=='memory-photo-delete'){toast('圖片檔案目前無法讀取，仍可刪除這筆相簿紀錄。');return;}
    if(button.dataset.action==='memory-photo-edit'){
      const row=button.closest('.memory-photo-row'),details=row?.querySelector('.memory-photo-details');if(!details)return;const photo=cached.photo;
      details.innerHTML='<div class="memory-photo-title-edit"><input class="field" maxlength="80" value="'+e(photo.caption||'')+'" aria-label="相片標題" data-memory-title-input="'+e(photo.id)+'"><button type="button" class="ghost memory-photo-icon" data-action="memory-photo-save-title" data-id="'+e(photo.id)+'" title="儲存">✓</button><button type="button" class="ghost memory-photo-icon" data-action="memory-photo-cancel-title" data-id="'+e(photo.id)+'" title="取消">✕</button></div><span class="small muted">'+e(dateLabel(photo.created_at))+'</span><span class="memory-photo-expiry">到期日：'+e(dateLabel(photo.expires_at))+'</span>';details.querySelector('input')?.focus();return;
    }
    if(button.dataset.action==='memory-photo-cancel-title'){void loadAlbum(cached.photo.chat_type,cached.photo.session_id||cached.photo.group_id);return;}
    if(button.dataset.action==='memory-photo-save-title'){
      const value=button.closest('.memory-photo-row')?.querySelector('[data-memory-title-input]')?.value.trim();if(!value){toast('請輸入相片名稱。');return;}
      const client=window.mySupabase;const {data:{user},error:authError}=await client.auth.getUser();if(authError||!user||user.id!==cached.photo.owner_id){toast('請確認登入帳號。');return;}
      const {data,error}=await client.from('chat_memory_photos').update({caption:value.slice(0,80)}).eq('id',cached.photo.id).eq('owner_id',user.id).select('id,caption').maybeSingle();
      if(error||!data){toast('標題儲存失敗：'+(error?.message||'資料庫未確認更新。'));return;}cached.photo.caption=data.caption;toast('相片名稱已更新。');void loadAlbum(cached.photo.chat_type,cached.photo.session_id||cached.photo.group_id);return;
    }
    if(button.dataset.action==='memory-photo-delete'){
      if(!confirm('刪除後不可復原哦，確認要刪除嗎?'))return;const client=window.mySupabase,uid=currentUser()?.uid,photo=cached.photo;if(!client||uid!==photo.owner_id){toast('請確認登入帳號。');return;}
      const {data:deleted,error}=await client.rpc('soft_delete_chat_memory_photo',{p_photo_id:photo.id});
      if(error){console.error('相簿刪除 RPC 失敗',error);toast('刪除失敗：'+error.message);return;}
      invalidateMemoryPhotoSignedUrl(photo.storage_path,uid);
      const {error:removeError}=await client.storage.from(BUCKET).remove([photo.storage_path]);if(removeError)console.warn('相片紀錄已移出相簿，但儲存檔案清理失敗',removeError.message);
      invalidateMemoryPhotoSignedUrl(photo.storage_path,uid);
      if(photo.chat_type==='single'){const session=state.sessions[photo.session_id];if(session?.background==='memory-photo:'+photo.id){session.background='none';persist();}}
      else{
        const group=groupPrototype.active;
        if(group?.backgroundMemoryPhotoId===photo.id){
          group.backgroundMode='none';group.backgroundMemoryPhotoId=null;applyGroupChatBackground();
        }
        const {error:backgroundClearError}=await client.from('chat_groups')
          .update({background_mode:'none',background_memory_photo_id:null,updated_at:new Date().toISOString()})
          .eq('id',photo.group_id).eq('owner_id',uid).eq('background_mode','memory').eq('background_memory_photo_id',photo.id);
        if(backgroundClearError)console.warn('相片已刪除，但群組背景設定清理失敗',backgroundClearError.message);
      }
      toast('回憶相片已刪除。');void loadAlbum(photo.chat_type,photo.session_id||photo.group_id);return;
    }
    if(button.dataset.action==='memory-photo-background'){
      const photo=cached.photo,client=window.mySupabase,uid=currentUser()?.uid;
      if(!client||!uid||photo.owner_id!==uid){toast('請確認登入帳號與相片擁有者一致。');return;}
      try{
        if(photo.chat_type==='single'){
          const session=state.sessions[photo.session_id];
          if(!session||!session.cloudOwned||session.cloudOwnerUid!==uid){toast('這不是目前帳號擁有的已同步聊天。');return;}
          const previous=session.background;session.background='memory-photo:'+photo.id;
          if(!persist()){session.background=previous;return;}
          const synced=await saveChatSessionSafely(session);
          if(!synced){session.background=previous;persist();render();toast('背景同步失敗，已還原原設定。');return;}
          render();toast('已將這張回憶相片設為聊天背景。');
        }else{
          const group=groupPrototype.active;
          if(!group||group.id!==photo.group_id){toast('請先開啟這張照片所屬的群組。');return;}
          const {data,error}=await client.from('chat_groups').update({background_mode:'memory',background_memory_photo_id:photo.id,updated_at:new Date().toISOString()})
            .eq('id',group.id).eq('owner_id',uid).select('id').maybeSingle();
          if(error||!data)throw error||new Error('資料庫未確認群組背景已儲存。');
          group.memoryPhotos=Array.isArray(group.memoryPhotos)?group.memoryPhotos.filter(item=>item.id!==photo.id):[];group.memoryPhotos.unshift({...photo,image_url:cached.url});group.backgroundMode='memory';group.backgroundMemoryPhotoId=photo.id;render();toast('已將這張回憶相片設為群組背景。');
        }
      }catch(err){console.error('設定回憶相片背景失敗',err);toast('背景設定失敗：'+(err.message||'請稍後再試。'));}
      return;
    }
    if(button.dataset.action==='memory-photo-open'){
      let viewer=document.querySelector('.memory-viewer');if(viewer){viewer.remove();return;}
      viewer=document.createElement('div');viewer.className='memory-viewer';viewer.innerHTML='<img src="'+e(cached.url)+'" alt="回憶相片" data-memory-viewer-image><div class="memory-viewer-controls"><button type="button" data-action="memory-viewer-download" aria-label="下載壓縮相片" title="下載">⬇</button><button type="button" data-action="memory-viewer-close" aria-label="關閉" title="關閉">✕</button></div>';
      viewer.addEventListener('click',ev=>{if(ev.target===viewer){viewer.remove();return;}if(ev.target.matches('[data-memory-viewer-image]'))viewer.querySelector('.memory-viewer-controls')?.classList.toggle('visible');});
      viewer.querySelector('[data-action="memory-viewer-close"]').addEventListener('click',()=>viewer.remove());viewer.querySelector('[data-action="memory-viewer-download"]').addEventListener('click',()=>downloadCompressedMemoryPhoto(cached));document.body.appendChild(viewer);return;
    }else{
      const ext=(cached.photo.storage_path.split('.').pop()||'jpg').replace(/[^a-z0-9]/gi,'')||'jpg';
      try {
        const response=await fetch(cached.url);
        if(!response.ok)throw new Error('下載連結已失效，請重新開啟相簿。');
        const blob=await response.blob(),objectUrl=URL.createObjectURL(blob);
        const a=document.createElement('a');a.href=objectUrl;a.download=(cached.photo.caption||'personax-memory')+'.'+ext;
        document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(objectUrl),1000);
      } catch(error) { toast('下載失敗：'+(error.message||'請重新開啟相簿後再試。')); }
    }
  });
})();
