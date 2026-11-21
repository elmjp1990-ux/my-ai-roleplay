/* Cloud-backed Encounter history. Loads ten records at a time and hydrates only bounded previews. */
(function(global){
  'use strict';
  const PAGE_SIZE=10;
  const excludedMessages=new Set(['[POYOZZ_ENCOUNTER_DISCOVERY_EVENT]','（請接續目前的故事。）']);
  const cleanSummary=value=>String(value||'')
    .replaceAll('你說：「[POYOZZ_ENCOUNTER_DISCOVERY_EVENT]」。','你選擇讓角色主動發現你。')
    .replaceAll('[POYOZZ_ENCOUNTER_DISCOVERY_EVENT]','你選擇讓角色主動發現你')
    .replaceAll('（請接續目前的故事。）','')
    .trim();
  const renderHistory=(person,sessions,escapeHTML,placeNames)=>{
    const rows=Array.isArray(sessions)?sessions:[];
    const cards=rows.map(session=>{
      const when=new Date(Number(session.startedAt)||Date.now()).toLocaleDateString('zh-TW',{year:'numeric',month:'2-digit',day:'2-digit'});
      const venue=placeNames[session.encounterPlace]||'城市相遇';
      const preview=cleanSummary(session.lastMessagePreview||session.encounterSummary||(session.archived?'本次相遇已結束，尚未產生文字摘要':'')).slice(0,50);
      return '<article class="city-encounter-history-item"><div class="city-encounter-history-heading"><strong>'+escapeHTML(when)+' · '+escapeHTML(venue)+'</strong></div>'+(session.archived?'<span class="city-encounter-history-status">已結束</span>':'')+(preview?'<p>'+escapeHTML(preview)+'</p>':'')+'</article>';
    }).join('');
    const empty=!rows.length&&!person.encounterHistoryLoading
      ?'<p>目前還沒有已保存的相遇紀錄。完成「與他相遇」對話後，紀錄會顯示在這裡。</p>'
      :'';
    const loading=person.encounterHistoryLoading
      ?'<p class="small muted">'+(rows.length?'正在載入更早的相遇紀錄…':'正在讀取雲端相遇紀錄…')+'</p>'
      :'';
    const error=person.encounterHistoryError?'<p role="alert">'+escapeHTML(person.encounterHistoryError)+'</p>':'';
    const sentinel=person.encounterHistoryHasMore
      ?'<div data-encounter-history-sentinel="true" class="small muted" style="padding:12px;text-align:center">繼續往下滑動，載入更早的相遇紀錄…</div>'
      :'';
    return empty+cards+loading+error+sentinel;
  };
  const loadCloudHistory=async(person,currentUser,client,{append=false}={})=>{
    if(!person||person.encounterHistoryLoading)return;
    if(append&&person.encounterHistoryHasMore===false)return;
    const uid=currentUser?.()?.uid;
    if(!append){
      person.encounterHistoryOffset=0;
      person.encounterHistoryCloud=[];
      person.encounterHistoryHasMore=true;
    }
    person.encounterHistoryLoading=true;
    person.encounterHistoryError='';
    try{
      if(!client||!uid){
        person.encounterHistoryCloud=[];
        person.encounterHistoryHasMore=false;
        person.encounterHistoryLoaded=true;
        return;
      }
      const {data:authData,error:authError}=await client.auth.getUser();
      if(authError||authData?.user?.id!==uid||currentUser()?.uid!==uid)throw new Error('登入狀態已變更，請重新登入。');
      const offset=Number(person.encounterHistoryOffset)||0;
      const {data:rows,error}=await client.from('chat_sessions')
        .select('id,chat_mode,created_at,updated_at,encounter_place:session_data->>encounterPlace,encounter_summary:session_data->>encounterSummary,last_message_preview:session_data->>lastMessagePreview,session_archived:session_data->>archived,session_started_at:session_data->>startedAt,encounter_ended_at:session_data->>encounterEndedAt,session_has_user_message:session_data->>hasUserMessage')
        .eq('user_id',uid).eq('character_id',person.id)
        .or('chat_mode.eq.encounter,session_data->>encounterMode.eq.true')
        .is('deleted_at',null).order('updated_at',{ascending:false}).order('id',{ascending:false})
        .range(offset,offset+PAGE_SIZE-1);
      if(error)throw error;
      const batch=Array.isArray(rows)?rows:[];
      if(currentUser()?.uid!==uid)throw new Error('登入狀態已變更，請重新登入。');
      const ids=batch.map(row=>row.id),latestBySession=new Map(),playerMessageSessions=new Set();
      if(ids.length){
        const {data:messages,error:messageError}=await client.from('chat_messages')
          .select('session_id,content')
          .in('session_id',ids).eq('role','user').is('deleted_at',null)
          .order('created_at',{ascending:false}).limit(PAGE_SIZE);
        if(messageError)throw messageError;
        for(const message of messages||[]){
          const rawContent=String(message.content||'').trim();
          if(excludedMessages.has(rawContent))continue;
          const preview=cleanSummary(rawContent).slice(0,50);
          if(!preview)continue;
          playerMessageSessions.add(message.session_id);
          if(!latestBySession.has(message.session_id))latestBySession.set(message.session_id,'你：'+preview);
        }
      }
      const page=batch.filter(row=>row.session_has_user_message==='true'||playerMessageSessions.has(row.id)).map(row=>{
        const endedAt=Number(row.encounter_ended_at)||null;
        return {
          id:row.id,encounterMode:true,characterId:person.id,
          archived:row.session_archived==='true'||!!endedAt,encounterEndedAt:endedAt,
          startedAt:Number(row.session_started_at)||Date.parse(row.created_at)||0,
          encounterPlace:row.encounter_place||'',
          encounterSummary:cleanSummary(row.encounter_summary||''),
          lastMessagePreview:latestBySession.get(row.id)||cleanSummary(row.last_message_preview||'').slice(0,50),
          messages:[]
        };
      });
      const previous=append?(person.encounterHistoryCloud||[]):[];
      const known=new Set(previous.map(item=>item.id));
      person.encounterHistoryCloud=[...previous,...page.filter(item=>!known.has(item.id))];
      person.encounterHistoryOffset=offset+batch.length;
      person.encounterHistoryHasMore=batch.length===PAGE_SIZE;
      person.encounterHistoryLoaded=true;
      person.encounterHistoryLoadedAt=Date.now();
    }catch(error){
      person.encounterHistoryError=error?.message||'讀取相遇紀錄失敗。';
      throw error;
    }finally{person.encounterHistoryLoading=false;}
  };
  const attachHistoryObserver=(person,currentUser,client,render,isActive,onError)=>{
    person.encounterHistoryObserver?.disconnect();
    const sentinel=document.querySelector('.city-encounter-history-list [data-encounter-history-sentinel]');
    if(!sentinel||person.encounterHistoryHasMore===false)return;
    person.encounterHistoryObserver=global.PoyozzListPagination?.observeEnd(sentinel,()=>{
      if(person.encounterHistoryLoading||!isActive?.())return;
      void loadCloudHistory(person,currentUser,client,{append:true})
        .then(()=>{if(isActive?.()){render?.();attachHistoryObserver(person,currentUser,client,render,isActive,onError);}})
        .catch(error=>{if(isActive?.()){render?.();onError?.(error);}});
    },{rootMargin:'180px 0px'});
  };
  const openHistory=(person,currentUser,client,render,isActive,onError)=>{
    if(!person||person.encounterHistoryLoading)return;
    person.encounterHistoryObserver?.disconnect();
    const request=loadCloudHistory(person,currentUser,client);
    render?.();
    void request.then(()=>{
      if(isActive?.()){
        render?.();
        attachHistoryObserver(person,currentUser,client,render,isActive,onError);
      }
    }).catch(error=>{
      if(isActive?.())render?.();
      onError?.(error);
    });
  };
  global.PoyozzEncounterHistory=Object.freeze({renderHistory,loadCloudHistory,openHistory});
})(window);
