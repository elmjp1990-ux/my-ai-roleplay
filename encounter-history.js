(function(g){
'use strict';
const N=10,skip=new Set(['[POYOZZ_ENCOUNTER_DISCOVERY_EVENT]','（請接續目前的故事。）']);
const clean=v=>String(v||'').replaceAll('你說：「[POYOZZ_ENCOUNTER_DISCOVERY_EVENT]」。','你選擇讓角色主動發現你。').replaceAll('[POYOZZ_ENCOUNTER_DISCOVERY_EVENT]','你選擇讓角色主動發現你').replaceAll('（請接續目前的故事。）','').trim();
const renderHistory=(p,rows,esc,places)=>{
 rows=Array.isArray(rows)?rows:[];
 const cards=rows.map(s=>{
  const date=new Date(Number(s.startedAt)||Date.now()).toLocaleDateString('zh-TW',{year:'numeric',month:'2-digit',day:'2-digit'});
  const venue=places[s.encounterPlace]||'城市相遇',preview=clean(s.lastMessagePreview||s.encounterSummary||(s.archived?'本次相遇已結束，尚未產生文字摘要':'')).slice(0,50);
  return '<article class="city-encounter-history-item"><div class="city-encounter-history-heading"><strong>'+esc(date)+' · '+esc(venue)+'</strong></div>'+(s.archived?'<span class="city-encounter-history-status">已結束</span>':'')+(preview?'<p>'+esc(preview)+'</p>':'')+'</article>';
 }).join('');
 return (!rows.length&&!p.encounterHistoryLoading?'<p>目前還沒有已保存的相遇紀錄。完成「與他相遇」對話後，紀錄會顯示在這裡。</p>':'')+cards+(p.encounterHistoryLoading?'<p class="small muted">'+(rows.length?'正在載入更早的相遇紀錄…':'正在讀取雲端相遇紀錄…')+'</p>':'')+(p.encounterHistoryError?'<p role="alert">'+esc(p.encounterHistoryError)+'</p>':'')+(p.encounterHistoryHasMore?'<div data-encounter-history-sentinel="true" class="small muted" style="padding:12px;text-align:center">繼續往下滑動，載入更早的相遇紀錄…</div>':'');
};
const loadCloudHistory=async(p,currentUser,client,{append=false}={})=>{
 if(!p||p.encounterHistoryLoading||append&&p.encounterHistoryHasMore===false)return;
 const uid=currentUser?.()?.uid;
 if(!append){p.encounterHistoryOffset=0;p.encounterHistoryCloud=[];p.encounterHistoryHasMore=true;}
 p.encounterHistoryLoading=true;p.encounterHistoryError='';
 try{
  if(!client||!uid){p.encounterHistoryCloud=[];p.encounterHistoryHasMore=false;p.encounterHistoryLoaded=true;return;}
  const {data:a,error:ae}=await client.auth.getUser();
  if(ae||a?.user?.id!==uid||currentUser()?.uid!==uid)throw Error('登入狀態已變更，請重新登入。');
  const offset=Number(p.encounterHistoryOffset)||0;
  const {data:rows,error}=await client.from('chat_sessions').select('id,chat_mode,created_at,updated_at,encounter_place:session_data->>encounterPlace,encounter_summary:session_data->>encounterSummary,last_message_preview:session_data->>lastMessagePreview,session_archived:session_data->>archived,session_started_at:session_data->>startedAt,encounter_ended_at:session_data->>encounterEndedAt,session_has_user_message:session_data->>hasUserMessage').eq('user_id',uid).eq('character_id',p.id).or('chat_mode.eq.encounter,session_data->>encounterMode.eq.true').is('deleted_at',null).order('updated_at',{ascending:false}).order('id',{ascending:false}).range(offset,offset+N-1);
  if(error)throw error;
  const batch=Array.isArray(rows)?rows:[];
  if(currentUser()?.uid!==uid)throw Error('登入狀態已變更，請重新登入。');
  const ids=batch.filter(r=>r.session_has_user_message!=='true').map(r=>r.id),hasPlayer=new Set();
  if(ids.length){
   const {data:msgs,error:me}=await client.from('chat_messages').select('session_id').in('session_id',ids).eq('role','user').is('deleted_at',null).not('content','ilike','%POYOZZ_ENCOUNTER_DISCOVERY_EVENT%').neq('content','（請接續目前的故事。）').order('created_at',{ascending:false}).limit(N);
   if(me)throw me;
   for(const m of msgs||[])if(m.session_id)hasPlayer.add(m.session_id);
  }
  const page=batch.filter(r=>r.session_has_user_message==='true'||hasPlayer.has(r.id)).map(r=>{
   const ended=Number(r.encounter_ended_at)||null;
   return {id:r.id,encounterMode:true,characterId:p.id,archived:r.session_archived==='true'||!!ended,encounterEndedAt:ended,startedAt:Number(r.session_started_at)||Date.parse(r.created_at)||0,encounterPlace:r.encounter_place||'',encounterSummary:clean(r.encounter_summary||''),lastMessagePreview:clean(r.last_message_preview||'').slice(0,50),messages:[]};
  });
  const prev=append?p.encounterHistoryCloud||[]:[],seen=new Set(prev.map(x=>x.id));
  p.encounterHistoryCloud=[...prev,...page.filter(x=>!seen.has(x.id))];p.encounterHistoryOffset=offset+batch.length;p.encounterHistoryHasMore=batch.length===N;p.encounterHistoryLoaded=true;p.encounterHistoryLoadedAt=Date.now();
 }catch(e){p.encounterHistoryError=e?.message||'讀取相遇紀錄失敗。';throw e;}
 finally{p.encounterHistoryLoading=false;}
};
const observe=(p,user,client,render,active,onError)=>{
 p.encounterHistoryObserver?.disconnect();
 const el=document.querySelector('.city-encounter-history-list [data-encounter-history-sentinel]');
 if(!el||p.encounterHistoryHasMore===false)return;
 p.encounterHistoryObserver=g.PoyozzListPagination?.observeEnd(el,()=>{
  if(p.encounterHistoryLoading||!active?.())return;
  void loadCloudHistory(p,user,client,{append:true}).then(()=>{if(active?.()){render?.();observe(p,user,client,render,active,onError);}}).catch(e=>{if(active?.())render?.();onError?.(e);});
 },{rootMargin:'180px 0px'});
};
const openHistory=(p,user,client,render,active,onError)=>{
 if(!p||p.encounterHistoryLoading)return;
 p.encounterHistoryObserver?.disconnect();
 const request=loadCloudHistory(p,user,client);render?.();
 void request.then(()=>{if(active?.()){render?.();observe(p,user,client,render,active,onError);}}).catch(e=>{if(active?.())render?.();onError?.(e);});
};
g.PoyozzEncounterHistory=Object.freeze({renderHistory,loadCloudHistory,openHistory});
})(window);
