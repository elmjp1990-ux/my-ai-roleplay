/* Cloud-backed Encounter history. Queries only the two newest sessions and
   their latest user messages when the history panel is opened. */
(function(global){
  'use strict';
  const excludedMessages=new Set(['[POYOZZ_ENCOUNTER_DISCOVERY_EVENT]','（請接續目前的故事。）']);
  const getSessions=(person,localSessions,currentUser)=>{
    const uid=currentUser?.()?.uid||'';
    const local=Object.values(localSessions||{}).filter(session=>
      session?.encounterMode&&session.characterId===person.id&&
      (!session.cloudOwned||session.cloudOwnerUid===uid));
    const cloud=Array.isArray(person.encounterHistoryCloud)?person.encounterHistoryCloud:[];
    return [...new Map([...cloud,...local].map(session=>[session.id,session])).values()]
      .sort((a,b)=>(Number(b.startedAt)||0)-(Number(a.startedAt)||0)).slice(0,2);
  };
  const renderHistory=(person,sessions,escapeHTML,placeNames)=>{
    if(person.encounterHistoryLoading)return '<p>正在讀取雲端相遇紀錄…</p>';
    if(!sessions.length)return '<p>目前還沒有已保存的相遇紀錄。完成「與他相遇」對話後，紀錄會顯示在這裡。</p>';
    return sessions.map(session=>{
      const when=new Date(Number(session.startedAt)||Date.now()).toLocaleDateString('zh-TW',{year:'numeric',month:'2-digit',day:'2-digit'});
      const venue=placeNames[session.encounterPlace]||'城市相遇';
      const lastUser=(session.messages||[]).filter(message=>message.role==='user'&&!excludedMessages.has(String(message.content||message.text||'').trim())).at(-1)?.content||session.encounterSummary;
      const summary=lastUser?'對話片段：'+String(lastUser).slice(0,90):'兩人在'+venue+'相遇，故事仍待續。';
      return '<article class="city-encounter-history-item"><strong>'+escapeHTML(when)+' · '+escapeHTML(venue)+'</strong><p>'+escapeHTML(summary)+'</p></article>';
    }).join('');
  };
  const loadCloudHistory=async(person,currentUser,client)=>{
    if(!person||person.encounterHistoryLoaded||person.encounterHistoryLoading)return;
    person.encounterHistoryLoading=true;
    person.encounterHistoryError='';
    const uid=currentUser?.()?.uid;
    try{
      if(!client||!uid){person.encounterHistoryCloud=[];person.encounterHistoryLoaded=true;return;}
      const {data:authData,error:authError}=await client.auth.getUser();
      if(authError||authData?.user?.id!==uid||currentUser()?.uid!==uid)throw new Error('登入狀態已變更，請重新登入。');
      const {data:rows,error}=await client.from('chat_sessions')
        .select('id,session_data,created_at,updated_at')
        .eq('user_id',uid).eq('character_id',person.id).eq('chat_mode','encounter')
        .is('deleted_at',null).order('updated_at',{ascending:false}).limit(2);
      if(error)throw error;
      if(currentUser()?.uid!==uid)throw new Error('登入狀態已變更，請重新登入。');
      person.encounterHistoryCloud=await Promise.all((rows||[]).map(async row=>{
        const data=row.session_data&&typeof row.session_data==='object'&&!Array.isArray(row.session_data)?row.session_data:{};
        const {data:messages,error:messageError}=await client.from('chat_messages')
          .select('role,content,created_at').eq('session_id',row.id).eq('role','user')
          .is('deleted_at',null).order('created_at',{ascending:false}).limit(3);
        if(messageError)throw messageError;
        const lastUser=(messages||[]).find(message=>!excludedMessages.has(String(message.content||'').trim()));
        return {
          id:row.id,encounterMode:true,characterId:person.id,archived:data.archived===true,
          startedAt:Number(data.startedAt)||Date.parse(row.created_at)||0,
          encounterPlace:data.encounterPlace||data.encounter?.locationKey||'',
          messages:lastUser?[{role:'user',content:lastUser.content,createdAt:lastUser.created_at}]:[]
        };
      }));
      person.encounterHistoryLoaded=true;
    }catch(error){
      person.encounterHistoryError=error?.message||'讀取相遇紀錄失敗。';
      throw error;
    }finally{person.encounterHistoryLoading=false;}
  };
  global.PoyozzEncounterHistory=Object.freeze({getSessions,renderHistory,loadCloudHistory});
})(window);
