/* Cloud-backed Encounter history. Reads session metadata and a bounded latest-message preview only. */
(function(global){
  'use strict';
  const PAGE_SIZE=50;
  const excludedMessages=new Set(['[POYOZZ_ENCOUNTER_DISCOVERY_EVENT]','（請接續目前的故事。）']);
  const cleanSummary=value=>String(value||'')
    .replaceAll('你說：「[POYOZZ_ENCOUNTER_DISCOVERY_EVENT]」。','你選擇讓角色主動發現你。')
    .replaceAll('[POYOZZ_ENCOUNTER_DISCOVERY_EVENT]','你選擇讓角色主動發現你')
    .replaceAll('（請接續目前的故事。）','')
    .trim();
  const renderHistory=(person,sessions,escapeHTML,placeNames)=>{
    if(person.encounterHistoryLoading)return '<p>正在讀取雲端相遇紀錄…</p>';
    if(person.encounterHistoryError)return '<p role="alert">'+escapeHTML(person.encounterHistoryError)+'</p>';
    if(!sessions.length)return '<p>目前還沒有已保存的相遇紀錄。完成「與他相遇」對話後，紀錄會顯示在這裡。</p>';
    return sessions.map(session=>{
      const when=new Date(Number(session.startedAt)||Date.now()).toLocaleDateString('zh-TW',{year:'numeric',month:'2-digit',day:'2-digit'});
      const venue=placeNames[session.encounterPlace]||'城市相遇';
      const preview=cleanSummary(session.lastMessagePreview||'').slice(0,50);
      return '<article class="city-encounter-history-item"><div class="city-encounter-history-heading"><strong>'+escapeHTML(when)+' · '+escapeHTML(venue)+'</strong></div>'+(preview?'<p>'+escapeHTML(preview)+'</p>':'')+'</article>';
    }).join('');
  };
  const loadCloudHistory=async(person,currentUser,client)=>{
    if(!person||person.encounterHistoryLoading)return;
    person.encounterHistoryLoading=true;
    person.encounterHistoryError='';
    const uid=currentUser?.()?.uid;
    try{
      if(!client||!uid){person.encounterHistoryCloud=[];person.encounterHistoryLoaded=true;return;}
      const {data:authData,error:authError}=await client.auth.getUser();
      if(authError||authData?.user?.id!==uid||currentUser()?.uid!==uid)throw new Error('登入狀態已變更，請重新登入。');
      const rows=[];
      let offset=0;
      while(true){
        const {data:page,error}=await client.from('chat_sessions')
          .select('id,chat_mode,session_data,created_at,updated_at')
          .eq('user_id',uid).eq('character_id',person.id)
          .or('chat_mode.eq.encounter,session_data->>encounterMode.eq.true')
          .is('deleted_at',null).order('updated_at',{ascending:false}).order('id',{ascending:false})
          .range(offset,offset+PAGE_SIZE-1);
        if(error)throw error;
        const batch=Array.isArray(page)?page:[];
        rows.push(...batch);
        if(batch.length<PAGE_SIZE)break;
        offset+=PAGE_SIZE;
      }
      if(currentUser()?.uid!==uid)throw new Error('登入狀態已變更，請重新登入。');
      const ids=rows.map(row=>row.id),latestBySession=new Map();
      if(ids.length){
        const {data:messages,error:messageError}=await client.from('chat_messages')
          .select('session_id,role,content,created_at,deleted_at')
          .in('session_id',ids).is('deleted_at',null)
          .order('created_at',{ascending:false}).limit(200);
        if(!messageError){
          for(const message of messages||[]){
            if(latestBySession.has(message.session_id))continue;
            const speaker=message.role==='user'?'你':(person.name||'角色');
            const text=cleanSummary(message.content||'').slice(0,50);
            if(text&&!excludedMessages.has(text))latestBySession.set(message.session_id,speaker+'：'+text);
          }
        }
      }
      person.encounterHistoryCloud=rows.map(row=>{
        const data=row.session_data&&typeof row.session_data==='object'&&!Array.isArray(row.session_data)?row.session_data:{};
        const endedAt=Number(data.encounterEndedAt)||null;
        return {
          id:row.id,encounterMode:true,characterId:person.id,
          archived:data.archived===true||!!endedAt,encounterEndedAt:endedAt,
          startedAt:Number(data.startedAt)||Date.parse(row.created_at)||0,
          encounterPlace:data.encounterPlace||data.encounter?.locationKey||'',
          encounterSummary:'',
          lastMessagePreview:latestBySession.get(row.id)||cleanSummary(data.lastMessagePreview||'').slice(0,50),
          messages:[]
        };
      });
      person.encounterHistoryLoaded=true;
      person.encounterHistoryLoadedAt=Date.now();
    }catch(error){
      person.encounterHistoryError=error?.message||'讀取相遇紀錄失敗。';
      throw error;
    }finally{person.encounterHistoryLoading=false;}
  };
  const openHistory=(person,currentUser,client,render,isActive,onError)=>{
    if(!person||person.encounterHistoryLoading)return;
    const request=loadCloudHistory(person,currentUser,client);
    render?.();
    void request.then(()=>{if(!isActive||isActive())render?.();}).catch(error=>onError?.(error));
  };
  global.PoyozzEncounterHistory=Object.freeze({renderHistory,loadCloudHistory,openHistory});
})(window);
