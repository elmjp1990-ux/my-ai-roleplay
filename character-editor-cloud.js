(() => {
 const refreshOwnedCharacterForEditor = async ({characterId,client,currentUser,getVerifiedAuthUser,state,normalizePersonalityProfile,normalizeCharacterTagsForRead,persist}) => {
  const uid=currentUser()?.uid;
  if(!client||!uid||!characterId)throw new Error('請先登入，再讀取角色雲端設定。');
  const verified=await getVerifiedAuthUser(uid);
  if(!verified||currentUser()?.uid!==uid)throw new Error('登入狀態已變更，請重新開啟角色編輯頁。');
  const [characterResult,privateResult,storyResult]=await Promise.all([
    client.from('characters')
      .select('id,author_id,name,gender,age,avatar_url,avatar_video_path,is_nsfw,visibility,review_status,intro,race,style,tags,worldview_tags,phone_settings,nsfw_workplace_warning,created_at,first_published_at,latest_eligible,rights_confirmed,deleted_at,deletion_reason')
      .eq('id',characterId).eq('author_id',uid).is('deleted_at',null).maybeSingle(),
    client.from('character_private_info')
      .select('character_id,private_info,personality_profile')
      .eq('character_id',characterId).eq('author_id',uid).maybeSingle(),
    client.from('character_stories')
      .select('id,story_name,opening_message,visibility,created_at')
      .eq('character_id',characterId)
      .order('created_at',{ascending:false}).order('id',{ascending:false}).limit(1).maybeSingle()
  ]);
  if(characterResult.error)throw new Error('讀取角色基本資料失敗：'+characterResult.error.message);
  if(privateResult.error)throw new Error('讀取角色人格與私密設定失敗：'+privateResult.error.message);
  if(storyResult.error)throw new Error('讀取角色開場白失敗：'+storyResult.error.message);
  const row=characterResult.data;
  if(!row)throw new Error('找不到這個角色，或目前帳號沒有編輯權限。');
  if(currentUser()?.uid!==uid)throw new Error('登入狀態已變更，已停止更新角色資料。');
  const existing=state.characters.find(item=>item.id===characterId)||{};
  const privateRow=privateResult.data||null;
  const story=storyResult.data||null;
  const refreshed={
    ...existing,
    id:row.id,authorId:row.author_id,name:row.name||'未命名角色',
    gender:row.gender||'ambiguous',age:row.age==null?'':String(row.age),
    image:existing.image||row.avatar_url||'',
    avatarVideoPath:row.avatar_video_path||existing.avatarVideoPath||'',
    visibility:row.visibility||'private',intro:row.intro??'',
    opening:story?.opening_message??'',
    race:row.race??'',style:row.style??'',
    privateInfo:privateRow?.private_info??existing.privateInfo??'',
    personalityProfile:normalizePersonalityProfile(privateRow?.personality_profile??existing.personalityProfile),
    phoneSettings:row.phone_settings&&typeof row.phone_settings==='object'?row.phone_settings:{},
    worldviewTags:window.PoyozzCityMap.normalizeWorldviewTags(Array.isArray(row.worldview_tags)?row.worldview_tags:[]),
    tags:normalizeCharacterTagsForRead(Array.isArray(row.tags)?row.tags:[]),
    nsfwWorkplaceWarning:row.nsfw_workplace_warning===true,
    isNSFW:row.is_nsfw===true,rightsConfirmed:row.rights_confirmed===true,
    firstPublishedAt:row.first_published_at?new Date(row.first_published_at).getTime():null,
    latestEligible:row.latest_eligible!==false
  };
  state.characters=state.characters.map(item=>item.id===characterId?refreshed:item);
  persist();
  return refreshed;
}
 const createEditorCloudRefreshController = ({refresh,isCurrent,onReady,onError}) => {
   let state={characterId:null,status:'idle',error:null,promise:null,requestId:0};
   let sequence=0;
   const getState=()=>state;
   const start=characterId=>{
     if(!characterId)return;
     const requestId=++sequence;
     state={characterId,status:'loading',error:null,promise:null,requestId};
     const promise=Promise.resolve().then(()=>refresh(characterId));
     state.promise=promise;
     promise.then(value=>{
       if(state.requestId===requestId&&isCurrent(characterId)){
         state={characterId,status:'ready',error:null,promise:null,requestId};onReady(value);
       }
     }).catch(error=>{
       if(state.requestId===requestId&&isCurrent(characterId)){
         state={characterId,status:'error',error,promise:null,requestId};onError(error);
       }
     });
   };
   return {getState,start};
 };
 const renderEditorCloudStatus = (state,escapeHTML) => {
   if(state.status==='loading')return '<div class="panel form-width"><h2>正在讀取角色雲端設定…</h2><p class="muted">請稍候片刻。</p></div>';
   if(state.status==='error')return '<div class="panel form-width"><h2>角色設定暫時無法載入</h2><p class="muted">'+escapeHTML(state.error?.message||'雲端資料讀取失敗')+'</p><button type="button" class="primary" data-action="retry-editor-cloud">重新讀取角色設定</button></div>';
   return '';
 };

 window.PoyozzCharacterEditorCloud = Object.freeze({
  refreshOwnedCharacterForEditor,
  createEditorCloudRefreshController,
  renderEditorCloudStatus
 });
})();
