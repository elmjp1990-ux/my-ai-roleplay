(function (global) {
 'use strict';

 let activeMapCleanup = null;
 let activeSceneRefresh = null;
 let activeScheduleRefresh = null;
 let activeVenueRefresh = null;
 const CITY_MAP_WEATHER_CACHE_TTL_MS = 50 * 60 * 1000;
 const CITY_MAP_SCENES_CACHE_TTL_MS = 30 * 60 * 1000;
 const cityMapMemoryCache = new Map();
 const cityCharacterAffinityCache = new Map();
 const cityCharacterAffinityPending = new Map();
 const readCityMapCache = (key, ttlMs) => {
 const now = Date.now();
 let entry = cityMapMemoryCache.get(key) || null;
 if (!entry) {
 try {
 const raw = sessionStorage.getItem('poyozz-city-map-' + key + '-v1');
 const parsed = raw ? JSON.parse(raw) : null;
 if (parsed && Number.isFinite(parsed.cachedAt) && Object.prototype.hasOwnProperty.call(parsed, 'data')) {
 entry = parsed;
 cityMapMemoryCache.set(key, entry);
 }
 } catch { /* Storage can be unavailable in private or restricted contexts. */ }
 }
 return entry ? { data: entry.data, fresh: now - entry.cachedAt < ttlMs } : null;
 };
 const writeCityMapCache = (key, data) => {
 const entry = { cachedAt: Date.now(), data };
 cityMapMemoryCache.set(key, entry);
 try { sessionStorage.setItem('poyozz-city-map-' + key + '-v1', JSON.stringify(entry)); } catch { /* In-memory cache remains available. */ }
 };
 const destroyActiveMap = () => {
 if (!activeMapCleanup) return;
 const cleanup = activeMapCleanup;
 activeMapCleanup = null;
 activeSceneRefresh = null;
 activeScheduleRefresh = null;
 activeVenueRefresh = null;
 cleanup();
 };

 global.PoyozzCityMap = Object.freeze({
 destroy: destroyActiveMap,
 refreshScenes() {
 return activeSceneRefresh ? activeSceneRefresh() : Promise.resolve();
 },
 refreshSchedules() {
 return activeScheduleRefresh ? activeScheduleRefresh() : Promise.resolve();
 },
 render(dependencies) {
 destroyActiveMap();
 const {
 $, state, accessible, escapeHTML, safeImage, characterAvatarMarkup, currentUser, toast, go, requireLogin,
 persist, hydratePublicCharacterIllustrations, characterVideoObserver,
 releaseCharacterVideo, hydrateCharacterVideo, loadCloudChatSessions,
 setEncounterLifecycleState, createEncounterSession, loadCityCharacterPage, loadCityCharacterSchedules
 } = dependencies;
 const findResumableEncounterSession=async(characterId,placeKey)=>{
 const client=window.mySupabase,user=currentUser?.();
 if(!client||!user?.uid)return null;
 const {data:authData,error:authError}=await client.auth.getUser();
 if(authError||authData?.user?.id!==user.uid||currentUser()?.uid!==user.uid)return null;
 const today=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Taipei',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
 const {data:rows,error}=await client.from('chat_sessions')
 .select('id,character_id,chat_mode,encounter_place:session_data->>encounterPlace,encounter_day:session_data->>encounterDay,encounter_started_at:session_data->>startedAt,encounter_left_at:session_data->>encounterTemporarilyLeftAt,encounter_archived:session_data->>archived,encounter_ended_at:session_data->>encounterEndedAt,updated_at')
 .eq('user_id',user.uid).eq('character_id',characterId).eq('chat_mode','encounter')
 .is('deleted_at',null).order('updated_at',{ascending:false}).limit(8);
 if(error)throw new Error('讀取暫離相遇紀錄失敗：'+error.message);
 const candidate=(rows||[]).find(row=>{
 const startedAt=Number(row.encounter_started_at)||Date.parse(row.encounter_started_at)||0;
 const day=String(row.encounter_day||startedAt&&new Date(startedAt).toLocaleDateString('en-CA',{timeZone:'Asia/Taipei'})||'');
 return row.character_id===characterId&&row.encounter_place===placeKey&&day===today&&
 Number(row.encounter_left_at)>0&&row.encounter_archived!=='true'&&
 !(Number(row.encounter_ended_at)>0);
 });
 if(!candidate)return null;
 await loadCloudChatSessions(user,{onlySessionId:candidate.id,listPage:false});
 if(currentUser()?.uid!==user.uid)return null;
 const hydrated=state.sessions?.[candidate.id];
 return hydrated?.cloudOwned===true&&hydrated?.cloudOwnerUid===user.uid&&
 hydrated?.encounterMode===true&&hydrated?.encounterPlace===placeKey&&
 Number(hydrated?.encounterTemporarilyLeftAt)>0&&!hydrated?.archived&&
 !(Number(hydrated?.encounterEndedAt)>0)?hydrated:null;
 };

 document.querySelectorAll('#cityMapPeople').forEach(modal=>modal.remove());
 document.body.classList.remove('city-location-active');
 document.body.classList.add('city-map-mode');
 const view=$('view');
  view.innerHTML=`
    <section class="city-map-stage" id="cityMapStage" aria-label="POYOZZ 城市地圖">
      <div class="city-map-world" id="cityMapWorld" aria-label="可拖曳地圖">
        <div class="city-map-river"></div>
        <div class="city-map-road r1"></div><div class="city-map-road r2"></div><div class="city-map-road r3"></div>
        <div class="city-map-block cafe"></div><div class="city-map-block school"></div><div class="city-map-block park"></div><div class="city-map-block shop"></div><div class="city-map-block home"></div>
        <svg class="city-building-layer" id="cityBuildingLayer" viewBox="0 0 1662 932" preserveAspectRatio="none" aria-label="城市地點玻璃圓形圖標">
          <!-- Marker anchors follow the user's annotated city-map reference; icons are specific to each place type. -->
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="waterfront" transform="translate(1392 638)" tabindex="0" role="button" aria-label="水岸港區"><circle class="city-marker-hit-area" r="38" fill="transparent"/><circle class="city-marker-glass" r="23"/><text class="city-marker-glyph city-marker-emoji" x="0" y="1" text-anchor="middle" dominant-baseline="central" font-size="18">🌊</text></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="commercial" transform="translate(1303 44)" tabindex="0" role="button" aria-label="辦公大樓"><circle class="city-marker-hit-area" r="38" fill="transparent"/><circle class="city-marker-glass" r="23"/><text class="city-marker-glyph city-marker-emoji" x="0" y="1" text-anchor="middle" dominant-baseline="central" font-size="18">🏢</text></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="airport" transform="translate(425 124)" tabindex="0" role="button" aria-label="機場"><circle class="city-marker-hit-area" r="38" fill="transparent"/><circle class="city-marker-glass" r="23"/><text class="city-marker-glyph city-marker-emoji" x="0" y="1" text-anchor="middle" dominant-baseline="central" font-size="18">✈️</text></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="university" transform="translate(280 365)" tabindex="0" role="button" aria-label="校園"><circle class="city-marker-hit-area" r="38" fill="transparent"/><circle class="city-marker-glass" r="23"/><text class="city-marker-glyph city-marker-emoji" x="0" y="1" text-anchor="middle" dominant-baseline="central" font-size="18">🎓</text></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="park" transform="translate(423 474)" tabindex="0" role="button" aria-label="中央公園"><circle class="city-marker-hit-area" r="38" fill="transparent"/><circle class="city-marker-glass" r="23"/><text class="city-marker-glyph city-marker-emoji" x="0" y="1" text-anchor="middle" dominant-baseline="central" font-size="18">🌳</text></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="shopping-street" transform="translate(672 646)" tabindex="0" role="button" aria-label="商店街"><circle class="city-marker-hit-area" r="38" fill="transparent"/><circle class="city-marker-glass" r="23"/><text class="city-marker-glyph city-marker-emoji" x="0" y="1" text-anchor="middle" dominant-baseline="central" font-size="18">🛍️</text></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="department-store" transform="translate(1039 280)" tabindex="0" role="button" aria-label="百貨公司"><circle class="city-marker-hit-area" r="38" fill="transparent"/><circle class="city-marker-glass" r="23"/><text class="city-marker-glyph city-marker-emoji" x="0" y="1" text-anchor="middle" dominant-baseline="central" font-size="18">🏬</text></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="hospital" transform="translate(1245 450)" tabindex="0" role="button" aria-label="中央醫院"><circle class="city-marker-hit-area" r="38" fill="transparent"/><circle class="city-marker-glass" r="23"/><text class="city-marker-glyph city-marker-emoji" x="0" y="1" text-anchor="middle" dominant-baseline="central" font-size="18">🏥</text></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="night-bar" transform="translate(632 294)" tabindex="0" role="button" aria-label="夜間酒吧"><circle class="city-marker-hit-area" r="38" fill="transparent"/><circle class="city-marker-glass" r="23"/><text class="city-marker-glyph city-marker-emoji" x="0" y="1" text-anchor="middle" dominant-baseline="central" font-size="18">🍸</text></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="live-house" transform="translate(862 410)" tabindex="0" role="button" aria-label="展演空間"><circle class="city-marker-hit-area" r="38" fill="transparent"/><circle class="city-marker-glass" r="23"/><text class="city-marker-glyph city-marker-emoji" x="0" y="1" text-anchor="middle" dominant-baseline="central" font-size="18">🎸</text></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="luxury-apartment" transform="translate(1580 236)" tabindex="0" role="button" aria-label="高級公寓"><circle class="city-marker-hit-area" r="38" fill="transparent"/><circle class="city-marker-glass" r="23"/><text class="city-marker-glyph city-marker-emoji" x="0" y="1" text-anchor="middle" dominant-baseline="central" font-size="18">🏙️</text></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="apartment" transform="translate(666 440)" tabindex="0" role="button" aria-label="308公寓"><circle class="city-marker-hit-area" r="38" fill="transparent"/><circle class="city-marker-glass" r="23"/><text class="city-marker-glyph city-marker-emoji" x="0" y="1" text-anchor="middle" dominant-baseline="central" font-size="18">🏠</text></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="convenience-store" transform="translate(465 700)" tabindex="0" role="button" aria-label="便利商店"><circle class="city-marker-hit-area" r="38" fill="transparent"/><circle class="city-marker-glass" r="23"/><text class="city-marker-glyph city-marker-emoji" x="0" y="1" text-anchor="middle" dominant-baseline="central" font-size="18">🏪</text></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="private-club" transform="translate(789 191)" tabindex="0" role="button" aria-label="高級會所"><circle class="city-marker-hit-area" r="38" fill="transparent"/><circle class="city-marker-glass" r="23"/><text class="city-marker-glyph city-marker-emoji" x="0" y="1" text-anchor="middle" dominant-baseline="central" font-size="18">🥂</text></g>
        </svg>

      </div>
      <div class="city-map-ui" id="cityMapUI">
        <aside class="city-map-info">
          <h2 class="city-map-title"><img src="./LOGO_WEBLOGO.webp" alt="POYOZZ"> <span>城市</span></h2>
          <div id="cityMapDate">台灣時間</div>
          <div class="city-map-weather"><span>🌤️</span><span id="cityMapWeather">天氣資料待串接</span><span id="cityMapTemp">溫度待串接</span><span id="cityMapRainChance">降雨機率</span></div>
          <p>這座城市充滿各種可能，也許今天你會在某個角落遇見特別的那個人。</p>
          <button class="city-map-traditional" data-action="city-traditional">⌖ 傳統探索模式</button>
        </aside>
        <div class="city-map-zoom"><button type="button" data-action="city-zoom-in" aria-label="放大地圖">＋</button><button type="button" data-action="city-zoom-out" aria-label="縮小地圖">−</button></div>
        <div class="city-map-bottom">
          <button data-action="city-traditional">✧<br>探索</button><button data-action="nav" data-page="create">✎<br>創建</button><button data-action="nav" data-page="chat">☏<br>聊天</button><button data-action="nav" data-page="shop">◇<br>商店</button><button data-action="nav" data-page="profile">♡<br>我的</button>
        </div>
      </div>
      <div class="city-map-empty">拖曳探索 · 雙指縮放 · 雙擊空白處沉浸</div>
      <section class="city-location-modal" id="cityMapPeople" hidden aria-modal="true" role="dialog" aria-labelledby="cityMapPlaceTitle">
      <button class="city-location-backdrop" type="button" data-action="city-close" aria-label="關閉地點資訊"></button>
      <div class="city-location-glass">
        <div class="city-location-header" role="group" aria-label="場景標題列">
          <div class="city-location-title-row"><span class="city-location-scene-icon city-location-title-icon" id="cityMapPlaceIcon" aria-hidden="true">☕</span><h2 id="cityMapPlaceTitle">咖啡廳</h2><span class="city-location-subtitle" id="cityMapPlaceSubtitle"></span></div>
          <button type="button" class="city-location-close" data-action="city-close" aria-label="關閉場景視窗">×</button>
        </div>
        <div class="city-location-rule"></div>
        <div class="city-location-section-title">當前角色 <span id="cityMapPeopleCount">依公開角色排程顯示</span></div>
        <div class="city-location-avatar-strip" id="cityMapAvatarStrip" aria-label="目前在場角色"><p class="city-location-empty">目前尚無符合此地點與台灣時間的公開角色排程。</p></div>
        <div class="city-location-rule"></div>
        <div class="city-location-detail" id="cityMapPresenceList">
          <div class="city-location-scene-icon" aria-hidden="true">📍</div>
          <h3 id="cityMapVenueHeading">選擇地點以查看場景</h3>
          <p id="cityMapVenueDescription">點選地圖上的地點後，這裡會顯示對應的場景介紹。</p>
          <div class="city-location-news" id="cityMapVenueNews"><span class="city-location-event-label">最新消息</span><div class="city-location-news-items"><p>📣 查看這個場景的最新消息。</p></div></div>
        </div>
        <section class="city-character-card" id="cityCharacterCard" hidden aria-live="polite">
          <div class="city-character-card-head"><span class="city-character-page-label" id="cityCharacterPageLabel">角色狀態 · 01 / 02</span><button type="button" class="city-character-card-close" data-action="city-character-close" aria-label="返回場地資訊">×</button></div>
          <div class="city-character-card-body" id="cityCharacterCardBody"></div>
          <div class="city-character-card-footer">
            <button type="button" class="city-character-page-button" data-action="city-character-prev" aria-label="上一頁">‹</button>
            <span class="city-character-page-dots"><i class="active"></i><i></i></span>
            <button type="button" class="city-character-page-button" data-action="city-character-next" aria-label="下一頁">›</button>
          </div>
        </section>
      </div>
    </section>
    </section>`;
 document.body.classList.remove('city-map-mode-immersive');
 const stage=$('cityMapStage'),world=$('cityMapWorld');
 stage.classList.add('is-loading');
 const mapAspect=2752/1536;
 let scale=1,tx=0,ty=0,pointers=new Map(),start=null,lastTap=0,lastTapX=0,lastTapY=0,moved=false;
 const sizeWorld=()=>{const sw=stage.clientWidth,sh=stage.clientHeight;const nav=$('cityMapUI')?.querySelector('.city-map-bottom');const navExtra=Math.max(76,(nav?.offsetHeight||68)+12);const h=Math.max(sh+navExtra,sw/mapAspect);const w=h*mapAspect;world.style.width=w+'px';world.style.height=h+'px';world.style.left=((sw-w)/2)+'px';world.style.top=((sh-h)/2)+'px';world.style.backgroundSize='100% 100%';};
 sizeWorld();
 const apply=()=>{world.style.transform='translate('+tx+'px,'+ty+'px) scale('+scale+')';};
 const clamp=()=>{scale=Math.max(1,Math.min(2.25,scale));const maxX=Math.max(0,(world.offsetWidth*scale-stage.clientWidth)/2);const maxY=Math.max(0,(world.offsetHeight*scale-stage.clientHeight)/2);tx=Math.max(-maxX,Math.min(maxX,tx));ty=Math.max(-maxY,Math.min(maxY,ty));apply();};
 const zoomBy=f=>{scale*=f;clamp();};
 stage.addEventListener('pointerdown',e=>{
 const direct=e.target instanceof Element?e.target.closest('[data-action="city-landmark"]'):null;
 const marker=direct||[...stage.querySelectorAll('[data-action="city-landmark"]')].find(node=>{
 const r=node.getBoundingClientRect();
 return e.clientX>=r.left-8&&e.clientX<=r.right+8&&e.clientY>=r.top-8&&e.clientY<=r.bottom+8;
 });
 if(marker){e.stopPropagation();return;}
 if(e.target instanceof Element&&e.target.closest('button,.city-map-info,.city-map-zoom,.city-map-bottom,.city-map-people'))return;
 stage.setPointerCapture?.(e.pointerId);pointers.set(e.pointerId,{x:e.clientX,y:e.clientY});moved=false;
 if(pointers.size===1)start={x:e.clientX,y:e.clientY,tx,ty,time:Date.now()};
 else if(pointers.size===2){const a=[...pointers.values()];start={distance:Math.hypot(a[0].x-a[1].x,a[0].y-a[1].y),scale,kind:'pinch'};}
 });
 stage.addEventListener('pointermove',e=>{if(!pointers.has(e.pointerId))return;pointers.set(e.pointerId,{x:e.clientX,y:e.clientY});if(pointers.size===2&&start?.kind==='pinch'){const a=[...pointers.values()];const d=Math.hypot(a[0].x-a[1].x,a[0].y-a[1].y);scale=start.scale*d/Math.max(1,start.distance);clamp();moved=true;}else if(pointers.size===1&&start&&!start.kind){const dx=e.clientX-start.x,dy=e.clientY-start.y;if(Math.abs(dx)+Math.abs(dy)>5)moved=true;tx=start.tx+dx;ty=start.ty+dy;clamp();}});
 const endPointer=e=>{pointers.delete(e.pointerId);if(pointers.size===0){if(start&&!moved&&Date.now()-start.time<280){const now=Date.now(),dx=e.clientX-lastTapX,dy=e.clientY-lastTapY;if(now-lastTap<320&&Math.hypot(dx,dy)<24){document.body.classList.toggle('city-map-mode-immersive');lastTap=0;}else{lastTap=now;lastTapX=e.clientX;lastTapY=e.clientY;}}start=null;}else if(pointers.size===1){const p=[...pointers.values()][0];start={x:p.x,y:p.y,tx,ty,time:Date.now()};}};
 stage.addEventListener('pointerup',endPointer);stage.addEventListener('pointercancel',endPointer);stage.addEventListener('dblclick',e=>e.preventDefault());stage.addEventListener('contextmenu',e=>e.preventDefault());
 const taipeiSunTimes2025=(month,day)=>{
 const date=new Date(Date.UTC(2025,month-1,day));
 const n=Math.floor((date-Date.UTC(2025,0,0))/86400000);
 const lat=25.033,lon=121.5654,zenith=90.833;
 const decl=0.006918-0.399912*Math.cos(2*Math.PI*n/365)+0.070257*Math.sin(2*Math.PI*n/365)-0.006758*Math.cos(4*Math.PI*n/365)+0.000907*Math.sin(4*Math.PI*n/365)-0.002697*Math.cos(6*Math.PI*n/365)+0.00148*Math.sin(6*Math.PI*n/365);
 const cosH=(Math.cos(zenith*Math.PI/180)-Math.sin(lat*Math.PI/180)*Math.sin(decl))/(Math.cos(lat*Math.PI/180)*Math.cos(decl));
 const ha=Math.acos(Math.max(-1,Math.min(1,cosH)))*180/Math.PI;
 const solarNoon=12-lon/15+8;
 return {sunrise:solarNoon-ha/15,sunset:solarNoon+ha/15};
 };
 let activeMapImage='';
 const applyCityMapImage=mapImage=>{
 if(activeMapImage===mapImage)return;
 activeMapImage=mapImage;
 const image=new Image();
 image.onload=()=>{
 if(activeMapImage!==mapImage)return;
 world.style.backgroundImage='url("'+mapImage+'")';
 world.style.filter='none';
 stage.classList.remove('is-loading');
 document.documentElement.classList.remove('city-map-boot');
 };
 image.onerror=()=>{
 if(activeMapImage!==mapImage)return;
 stage.style.backgroundColor='#18253e';
 stage.classList.remove('is-loading');
 document.documentElement.classList.remove('city-map-boot');
 };
 image.src=mapImage;
 };
 const taipeiTime=()=>{
 const d=new Date();
 const parts=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Taipei',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false}).formatToParts(d);
 const p=Object.fromEntries(parts.map(x=>[x.type,x.value]));
 const month=Number(p.month),day=Number(p.day),minuteOfDay=(Number(p.hour)%24)*60+Number(p.minute);
 const sun=taipeiSunTimes2025(month,day);
 const sunrise=Math.round(sun.sunrise*60),sunset=Math.round(sun.sunset*60);
 const isDay=minuteOfDay>=sunrise&&minuteOfDay<sunset;
 $('cityMapDate').textContent=new Intl.DateTimeFormat('zh-TW',{timeZone:'Asia/Taipei',month:'numeric',day:'numeric',weekday:'short',hour:'2-digit',minute:'2-digit',hour12:false}).format(d);
 const mapImage=isDay?'./encounter-default-scene.webp':'https://raw.githubusercontent.com/elmjp1990-ux/my-ai-roleplay/main/Add_nighttime_lighting_to_buildings_2K_20261027142959%20(1).webp';
 stage.style.backgroundColor=isDay?'#b9d9c5':'#18253e';stage.style.backgroundImage='none';applyCityMapImage(mapImage);
 };
 taipeiTime();
 const cityMapClock=setInterval(taipeiTime,30000);
 const onVisibilityChange=()=>{if(!document.hidden)taipeiTime();};
 document.addEventListener('visibilitychange',onVisibilityChange);
 let locationModal=null;
 let resizeHandler=null;
 activeMapCleanup=()=>{
 clearInterval(cityMapClock);
 document.removeEventListener('visibilitychange',onVisibilityChange);
 if(resizeHandler)window.removeEventListener('resize',resizeHandler);
 const mapVideos=[...stage.querySelectorAll('video'),...(locationModal?.querySelectorAll('video')||[])];
 mapVideos.forEach(video=>{
 characterVideoObserver?.unobserve(video);
 releaseCharacterVideo(video);
 });
 locationModal?.remove();
 stage.remove();
 document.body.classList.remove('city-location-active','city-map-mode','city-map-mode-immersive');
 };

 locationModal=$('cityMapPeople');
 if(locationModal && locationModal.parentElement!==document.body) document.body.appendChild(locationModal);
 const cityPlaceNames=Object.create(null);
 const cityVenueScenes=Object.create(null);
 const renderCitySceneCatalog=(rows)=>{
 for(const row of (Array.isArray(rows)?rows:[])){
 const key=String(row?.location_key||'').trim();
 if(!Array.from(document.querySelectorAll('.city-place-marker[data-place]')).some(marker=>marker.dataset.place===key))continue;
 const previous=cityVenueScenes[key]||{};
 cityPlaceNames[key]=String(row.display_name||key);
 const scene={
 icon:String(row.icon||previous.icon||'📍'),
 heading:String(row.heading||previous.heading||''),
 description:String(row.description||previous.description||''),
 eventLabel:String(row.event_label||previous.eventLabel||'場景亮點'),
 eventTitle:String(row.event_title||previous.eventTitle||''),
 eventDescription:String(row.event_description||previous.eventDescription||'')
 };
 cityVenueScenes[key]=scene;
 }
 };
 const loadCitySceneCatalog=async()=>{
 const client=window.mySupabase;
 if(!client)return [];
 const cached=readCityMapCache('scenes-v3',CITY_MAP_SCENES_CACHE_TTL_MS);
 if(cached)renderCitySceneCatalog(cached.data);
 if(cached?.fresh)return cached.data;
 try{
 const {data,error}=await client.rpc('get_encounter_scene_catalog');
 if(error)throw error;
 const rows=Array.isArray(data)?data:[];
 writeCityMapCache('scenes-v3',rows);
 renderCitySceneCatalog(rows);
 return rows;
 }catch(error){
 if(!cached)console.warn('城市場景目錄載入失敗：',error?.message||error);
 return cached?.data||[];
 }
 };
 activeSceneRefresh=async()=>{
 cityMapMemoryCache.delete('scenes-v3');
 try{sessionStorage.removeItem('poyozz-city-map-scenes-v3-v1');}catch{}
 await loadCitySceneCatalog();
 if(locationModal&&!locationModal.hidden)activeVenueRefresh?.();
 };
 const applyCityWeather=weather=>{
 const stage=$('cityMapStage');
 if(!stage)return;
 const weatherLabel=$('cityMapWeather');
 const temperatureLabel=$('cityMapTemp');
 const rainChanceLabel=$('cityMapRainChance');
 if(!weather){
 if(weatherLabel)weatherLabel.textContent='多雲';
 if(temperatureLabel)temperatureLabel.textContent='24.0°C';
 if(rainChanceLabel)rainChanceLabel.textContent='降雨機率 --';
 stage.classList.remove('is-raining');
 return;
 }
 if(weatherLabel)weatherLabel.textContent=String(weather.weather_text||'多雲');
 const temperature=Number(weather.temperature_c);
 if(temperatureLabel)temperatureLabel.textContent=Number.isFinite(temperature)?temperature.toFixed(1)+'°C':'24.0°C';
 const rainChance=Number(weather.precipitation_probability);
 if(rainChanceLabel)rainChanceLabel.textContent=Number.isFinite(rainChance)?'降雨 '+Math.max(0,Math.min(100,Math.round(rainChance)))+'%':'降雨機率 --';
 stage.classList.toggle('is-raining',weather.is_raining===true);
 const cores=Number(navigator.hardwareConcurrency||8);
 const memory=Number(navigator.deviceMemory||8);
 stage.classList.toggle('low-performance',cores<=4||memory<=4);
 };
 const loadCityWeather=async()=>{
 const client=window.mySupabase;
 const stage=$('cityMapStage');
 if(!client||!stage)return;
 const cached=readCityMapCache('weather-v2',CITY_MAP_WEATHER_CACHE_TTL_MS);
 if(cached)applyCityWeather(cached.data);
 if(cached?.fresh)return;
 try{
 let {data,error}=await client.rpc('get_encounter_city_weather_v2');
 if(error){
 const legacy=await client.rpc('get_encounter_city_weather');
 if(legacy.error)throw error;
 data=legacy.data;
 }
 const weather=Array.isArray(data)?data[0]:data;
 if(weather)writeCityMapCache('weather-v2',weather);
 applyCityWeather(weather);
 }catch(error){
 if(!cached)console.warn('城市天氣資料載入失敗：',error?.message||error);
 }
 };
 const isSleepingSchedule=(activity='',scene='')=>/(熟睡|沉睡|酣睡|安睡|睡著|睡着|睡覺|睡眠|睡夢|睡得很沉|淺眠|深層睡眠|入睡|睡去|午睡|補眠|就寢)/.test((activity+' '+scene).normalize('NFKC').replace(/準備(?:要)?睡覺/g,''));
 const isCurrentCityCharacterEligible=(person)=>{
 const live=(Array.isArray(state.characters)?state.characters:[]).find(item=>item?.id===person?.id);
 return !!live&&live.visibility==='public'&&!live.deletedAt&&live.cloudPublic!==false&&live.localOnly!==true&&!String(live.id||'').startsWith('seed-')&&accessible(live);
 };
 const getCityPresence=(place,sourceCharacters=state.characters)=>{
 const sceneKey=place;
 if(!sceneKey)return [];
 return (Array.isArray(sourceCharacters)?sourceCharacters:[]).filter(character=>{
 if(character?.visibility!=='public'||character.deletedAt||!accessible(character))return false;
 const schedules=Array.isArray(character.encounterSchedules)?character.encounterSchedules:[];
 return schedules.some(row=>row?.location_key===sceneKey);
 }).map(character=>{
 const row=(Array.isArray(character.encounterSchedules)?character.encounterSchedules:[])
 .find(item=>item?.location_key===sceneKey);
 return {...character,cityStartTime:String(row?.start_time||'').slice(0,5),cityEndTime:String(row?.end_time||'').slice(0,5),cityActivity:row?.activity||'',citySceneDescription:row?.scene_description||''};
 });
 };
 const cityPresenceByPlace={};
 const cityAvatarHydrationPending=new Set();
 void loadCitySceneCatalog();
 void loadCityWeather();
 const cityScenePageStates=new Map();
 const renderCityPeopleStrip=(place)=>{
 const pager=cityScenePageStates.get(place);
 const people=pager?.people||[];
 const strip=$('cityMapAvatarStrip');
 if(!strip)return;
 const emptyMessage=pager?.loading
 ? '正在讀取這個場景的角色…'
 : pager?.error
 ? '角色行程載入失敗，請重試。'
 : '目前沒有角色出現在此場景';
 strip.innerHTML=people.length
 ? people.map((person,index)=>{
 const characterName=String(person.name||'角色');
 const image=safeImage(person.image||person.avatar_url||person.avatar);
 const portrait='<span class="city-location-person-avatar-frame">'+characterAvatarMarkup({...person,image,avatar_url:image},{imageClass:'city-location-person-image',fallbackClass:'city-location-avatar-fallback'})+'</span>';
 return '<button type="button" class="city-location-person" data-action="city-person" data-person-index="'+index+'" aria-label="查看 '+escapeHTML(characterName)+' 的角色資訊">'+portrait+'<span class="city-location-person-name">'+escapeHTML(characterName)+'</span></button>';
 }).join('')
 : '<p class="city-location-empty">'+emptyMessage+'</p>';
 if(pager?.error){
 strip.insertAdjacentHTML('beforeend','<button type="button" class="city-location-load-more" data-action="city-people-retry">重試載入</button>');
 }else if(pager?.hasMore){
 strip.insertAdjacentHTML('beforeend','<button type="button" class="city-location-load-more" data-action="city-people-load-more" '+(pager.loading?'disabled':'')+'>載入更多角色（每次 10 位）</button>');
 }
 $('cityMapPeopleCount').textContent=people.length
 ? people.length+' 位角色符合目前時段'+(pager?.hasMore?' · 可載入更多':'')
 : (pager?.loading?'正在讀取…':pager?.error?'載入失敗':'目前沒有角色出現在此場景');
 for(const person of people){
 const id=String(person?.id||'');
 if(!id||person.cloudPublic!==true||safeImage(person.image||person.avatar_url||person.avatar)||person.publicIllustrationsLoaded===true||cityAvatarHydrationPending.has(id))continue;
 cityAvatarHydrationPending.add(id);
 void hydratePublicCharacterIllustrations(id).then(()=>{
 const current=state.characters.find(character=>character.id===id);
 if(!current)return;
 person.image=current.image||'';
 person.primaryIllustrationPath=current.primaryIllustrationPath||'';
 person.publicIllustrationsLoaded=current.publicIllustrationsLoaded===true;
 const livePager=cityScenePageStates.get(place);
 if(livePager===pager&&livePager.people.some(item=>item.id===id))renderCityPeopleStrip(place);
 }).catch(error=>console.warn('城市角色頭像載入失敗：',error?.message||error)).finally(()=>cityAvatarHydrationPending.delete(id));
 }
 };
 const loadCityPeoplePage=async(place)=>{
 const pager=cityScenePageStates.get(place);
 if(!pager||pager.loading||!pager.hasMore||typeof loadCityCharacterPage!=='function')return;
 pager.loading=true;
 renderCityPeopleStrip(place);
 try{
 const targetCount=pager.people.length+10;
 let scannedPages=0;
 while(pager.hasMore&&pager.people.length<targetCount&&scannedPages<5){
 const result=await loadCityCharacterPage(pager.offset);
 const items=Array.isArray(result?.items)?result.items:[];
 if(items.length){
 const schedules=await loadCityCharacterSchedules(items.map(person=>person.id));
 for(const person of items)person.encounterSchedules=schedules.get(person.id)||'';
 }
 pager.offset+=items.length;
 pager.hasMore=result?.hasMore===true;
 pager.candidates=[...pager.candidates,...items];
 pager.people=getCityPresence(place,pager.candidates);
 cityPresenceByPlace[place]=pager.people;
 scannedPages++;
 if(items.length===0)break;
 }
 }catch(error){
 pager.error=error;
 console.error('讀取城市角色排程失敗：',error);
 toast('場景角色載入失敗，請稍後重試。');
 }finally{
 pager.loading=false;
 renderCityPeopleStrip(place);
 }
 };
 activeScheduleRefresh=async()=>{
 const activePlace=locationModal&&!locationModal.hidden?locationModal.dataset.place:null;
 cityScenePageStates.clear();
 Object.keys(cityPresenceByPlace).forEach(place=>delete cityPresenceByPlace[place]);
 if(!activePlace)return;
 const pageState={offset:0,hasMore:true,loading:false,candidates:[],people:[],error:null};
 cityScenePageStates.set(activePlace,pageState);
 renderCityPeopleStrip(activePlace);
 await loadCityPeoplePage(activePlace);
 };
 const openCityLocation=async(marker)=>{
 const place=marker?.dataset?.place;
 if(!place||!locationModal)return;
 await loadCitySceneCatalog();
 const name=cityPlaceNames[place]||'地點';
 const scene=cityVenueScenes[place];
 if(!scene){console.error('城市地標缺少專屬場景設定：',place);toast('這個地點的場景資料尚未完成，請稍後再試。');return;}
 const flightMarkup=place==='airport'
 ? '<div class="city-location-news city-flight-section"><span class="city-location-event-label">今日航班</span><p class="small">模擬航班時刻表</p><table class="city-flight-table"><thead><tr><th>時間</th><th>航班</th><th>目的地</th><th>狀態</th></tr></thead><tbody><tr><td>09:20</td><td>PZ102</td><td>東京</td><td>準時</td></tr><tr><td>13:45</td><td>PZ238</td><td>首爾</td><td>登機中</td></tr><tr><td>18:10</td><td>PZ516</td><td>台北</td><td>預計抵達</td></tr></tbody></table><p class="city-flight-note">以上為虛構示意資料，非真實航班資訊。</p></div>'
 : '';
 locationModal.dataset.scene=place;
 locationModal.dataset.place=place;
 locationModal.dataset.selectedPersonIndex='';
 locationModal.dataset.cardMode='status';
 const characterCard=$('cityCharacterCard');
 if(characterCard)characterCard.hidden=true;
 const venueInfo=$('cityMapPresenceList');
 if(venueInfo)venueInfo.hidden=false;
 const title=$('cityMapPlaceTitle');
 if(title){title.textContent=name;title.style.display='block';title.style.visibility='visible';}
 const placeSubtitle=$('cityMapPlaceSubtitle');if(placeSubtitle)placeSubtitle.textContent='';
 const placeIcon=$('cityMapPlaceIcon');
 if(placeIcon)placeIcon.textContent=scene.icon;
 const renderVenue=()=>{
 const latestScene=cityVenueScenes[place]||scene;
 const latestNotice={
 label:latestScene.eventLabel||'最新消息',
 items:[latestScene.eventTitle,latestScene.eventDescription].map(value=>String(value||'').trim()).filter(Boolean).slice(0,3)
 };
 const latestEventMarkup=latestNotice.items.map(item=>'<p>📣 '+escapeHTML(item)+'</p>').join('');
 if(title){title.textContent=cityPlaceNames[place]||name;title.style.display='block';title.style.visibility='visible';}
 const placeSubtitle=$('cityMapPlaceSubtitle');if(placeSubtitle)placeSubtitle.textContent='';
 if(placeIcon)placeIcon.textContent=latestScene.icon;
 const target=$('cityMapPresenceList');
 if(target)target.innerHTML='<h3 id="cityMapVenueHeading">'+escapeHTML(latestScene.heading)+'</h3><p id="cityMapVenueDescription">'+escapeHTML(latestScene.description)+'</p><div class="city-location-news"><span class="city-location-event-label">'+escapeHTML(latestNotice.label)+'</span><div class="city-location-news-items">'+latestEventMarkup+'</div></div>'+flightMarkup;
 };
 activeVenueRefresh=renderVenue;
 renderVenue();
 const pageState={offset:0,hasMore:true,loading:false,candidates:[],people:[],error:null};
 cityScenePageStates.set(place,pageState);
 renderCityPeopleStrip(place);
 await loadCityPeoplePage(place);
 renderVenue();
 locationModal.hidden=false;
 document.body.classList.add('city-location-active');
 };
 const loadCityCharacterAffinity=async(characterId)=>{
 const target=$('cityCharacterAffinity');if(!target||target.dataset.characterId!==String(characterId))return;
 const user=currentUser?.();if(!user?.uid){target.textContent='登入後查看與角色的好感度';return;}
 const characterKey=String(characterId),key=String(user.uid)+':'+characterKey,renderRow=row=>{const live=$('cityCharacterAffinity');if(!live||live.dataset.characterId!==characterKey||currentUser?.()?.uid!==user.uid)return;live.innerHTML=window.PoyozzAffinityUI?.render(row?.affinity,row?.relationship_stage,'compact')||'<span class="poyozz-affinity-empty">你們還不認識</span>';},showAffinityError=error=>{console.warn('城市角色好感度載入失敗：',error?.message||error);const live=$('cityCharacterAffinity');if(live&&live.dataset.characterId===characterKey&&currentUser?.()?.uid===user.uid){live.textContent='好感度暫時無法載入';live.setAttribute('aria-label','好感度暫時無法載入');}};
 const cached=cityCharacterAffinityCache.get(key);
 if(cached&&Date.now()-cached.at<60_000){renderRow(cached.row);return;}
 const pending=cityCharacterAffinityPending.get(key);
 if(pending){target.textContent='正在讀取好感度…';try{renderRow(await pending);}catch(error){showAffinityError(error);}return;}
 target.textContent='正在讀取好感度…';
 const load=async()=>{
  const client=window.mySupabase;if(!client)throw new Error('關係資料服務尚未連線');
  const rpc=await client.rpc('get_encounter_character_affinity',{p_character_id:characterId});
  if(rpc.error)throw rpc.error;
  let row=Array.isArray(rpc.data)?rpc.data[0]||null:rpc.data||null;
  if(!row){const story=await client.from('story_relationship_states').select('affinity,relationship_stage,updated_at').eq('user_id',user.uid).eq('character_id',characterId).order('updated_at',{ascending:false}).limit(1);if(!story.error&&story.data?.[0])row=story.data[0];}
  cityCharacterAffinityCache.set(key,{row,at:Date.now()});return row;
 };
 const promise=load();cityCharacterAffinityPending.set(key,promise);
 try{renderRow(await promise);}catch(error){showAffinityError(error);}finally{cityCharacterAffinityPending.delete(key);}
 };
 const renderCityCharacterCard=(person,page=0,mode='status')=>{
 const card=$('cityCharacterCard'),body=$('cityCharacterCardBody');
 if(!card||!body||!person)return;
 card.hidden=false;
 const venueInfo=$('cityMapPresenceList');
 if(venueInfo)venueInfo.hidden=true;
 card.dataset.page=String(page);
 card.dataset.mode=mode;
 locationModal.dataset.cardMode=mode;
 locationModal.dataset.selectedPersonIndex=String((cityPresenceByPlace[locationModal.dataset.place]||[]).findIndex(item=>item.id===person.id));
 const image=safeImage(person.image||person.avatar_url||person.avatar);
 if(person.cloudPublic===true&&!image&&person.publicIllustrationsLoaded!==true){
 const selectedIndex=locationModal.dataset.selectedPersonIndex;
 const selectedPlace=locationModal.dataset.place;
 void hydratePublicCharacterIllustrations(person.id).then(()=>{
 const current=state.characters.find(character=>character.id===person.id);
 if(!current)return;
 person.image=current.image||'';
 person.primaryIllustrationPath=current.primaryIllustrationPath||'';
 person.publicIllustrationsLoaded=current.publicIllustrationsLoaded===true;
 const cityVideo=body.querySelector('video.city-character-portrait-video[data-character-video]');
 if(cityVideo)cityVideo.poster=safeImage(person.image);
 if(locationModal.dataset.place===selectedPlace&&locationModal.dataset.selectedPersonIndex===selectedIndex&&locationModal.dataset.cardMode===mode&&card.dataset.page===String(page)&&card.isConnected){
 renderCityCharacterCard(person,page,mode);
 }
 });
 }
 const videoPath=String(person.avatarVideoPath||person.avatar_video_path||person.characterVideoPath||'').trim();
 const videoRaw=String(person.videoUrl||person.video_url||person.introVideoUrl||person.intro_video_url||'').trim();
 const videoUrl=/^https:\/\//i.test(videoRaw)?videoRaw:'';
 const portrait=videoPath
 ? '<video class="city-character-portrait city-character-portrait-video" data-character-video="'+escapeHTML(videoPath)+'" autoplay muted loop playsinline preload="metadata" poster="'+escapeHTML(image||'')+'" aria-label="'+escapeHTML(person.name||'角色')+'角色展示影片"></video>'
 : videoUrl
 ? '<video class="city-character-portrait city-character-portrait-video" src="'+escapeHTML(videoUrl)+'" autoplay muted loop playsinline preload="metadata" poster="'+escapeHTML(image||'')+'" aria-label="'+escapeHTML(person.name||'角色')+'角色展示影片"></video>'
 : characterAvatarMarkup({...person,image,avatar_url:image},{imageClass:'city-character-portrait',fallbackClass:'city-character-portrait city-character-portrait-fallback',loading:'eager'});
 const name=escapeHTML(person.name||'未命名角色');
 const gender=escapeHTML(person.gender||'未設定');
 const liveAge=[person.age,person.characterAge,person.character_age].map(value=>value==null?'':String(value).trim()).find(Boolean)||'';
 const ageDisplay=liveAge?( /^\d+$/.test(liveAge)?liveAge+' 歲':liveAge):'未設定';
 const age=escapeHTML(ageDisplay);
 const rawTimeRange=String(person.cityStartTime||'')+'–'+String(person.cityEndTime||'');
 const requestedSleepScene=person.name==='陸沈宵'&&rawTimeRange==='08:00–09:00';
 const rawStatusDescription=requestedSleepScene?'安靜且完全遮光的臥室，深層睡眠中。':(person.citySceneDescription||person.cityActivity||'在這個場景中度過自己的時間');
 const statusDescription=escapeHTML(rawStatusDescription);
 const timeRange=person.cityStartTime&&person.cityEndTime?escapeHTML(person.cityStartTime+'–'+person.cityEndTime):'時間未設定';
 const placeKey=locationModal.dataset.place;
 const placeName=escapeHTML(cityPlaceNames[placeKey]||'城市地點');
 const intro=String(person.intro||person.description||person.personalityProfile?.summary||'這位角色尚未填寫公開介紹。');
 const sessions=Array.isArray(person.encounterHistoryCloud)?person.encounterHistoryCloud:[];
 const bookmarks='<div class="city-character-bookmarks" aria-label="角色功能"><button type="button" class="city-character-bookmark '+(mode==='status'?'active':'')+'" data-action="city-character-status" aria-label="角色資料">角色資料</button><button type="button" class="city-character-bookmark '+(mode==='history'?'active':'')+'" data-action="city-character-history" aria-label="相遇紀錄">相遇紀錄</button><button type="button" class="city-character-bookmark" data-action="city-character-story" aria-label="故事模式">故事模式</button></div>';
 const affinityMarkup=(mode==='status'&&page===0||mode==='history')?'<div class="city-character-affinity" id="cityCharacterAffinity" data-character-id="'+escapeHTML(person.id)+'">正在讀取好感度…</div>':'';
 const meetControl=isSleepingSchedule(person.cityActivity,person.citySceneDescription)
 ? '<div class="city-character-meet" role="status">熟睡中無法打擾</div>'
 : '<button type="button" class="city-character-meet primary" data-action="city-character-meet">與他相遇</button>';
 const left='<div class="city-character-photo-column">'+portrait+affinityMarkup+meetControl+'</div>';
 let copy='';
 if(mode==='history'){
 const records=window.PoyozzEncounterHistory?.renderHistory(person,sessions,escapeHTML,cityPlaceNames)||'<p>相遇紀錄模組暫時無法載入。</p>';
 copy='<div class="city-character-copy"><h3>'+name+'｜過往相遇</h3><div class="city-encounter-history-list">'+records+'</div></div>';
 $('cityCharacterPageLabel').textContent='相遇紀錄';
 }else if(mode==='story'){
 copy='<div class="city-character-copy"><h3>'+name+'｜故事模式</h3><p>正在開啟傳統角色聊天……</p></div>';
 $('cityCharacterPageLabel').textContent='故事模式';
 }else if(page===0){
 copy='<div class="city-character-copy"><h3>'+name+'</h3><div class="city-character-meta"><span>'+gender+'</span><span>'+age+'</span></div><p><strong>當前行程</strong><br>'+timeRange+'<br>'+placeName+'</p><p><strong>現在狀態</strong><br>'+statusDescription+'</p></div>';
 $('cityCharacterPageLabel').textContent='角色狀態 · 01 / 02';
 }else{
 copy='<div class="city-character-copy"><h3>'+name+'｜角色介紹</h3><p>'+escapeHTML(intro)+'</p></div>';
 $('cityCharacterPageLabel').textContent='角色介紹 · 02 / 02';
 }
 const previousCharacterVideo=body.querySelector('video.city-character-portrait-video[data-character-video]');
 body.innerHTML=left+copy+bookmarks;
 if((mode==='status'&&page===0||mode==='history'))void loadCityCharacterAffinity(person.id);
 let characterVideo=body.querySelector('video.city-character-portrait-video[data-character-video]');
 if(previousCharacterVideo&&characterVideo&&
 previousCharacterVideo.dataset.characterVideo===characterVideo.dataset.characterVideo){
 characterVideo.replaceWith(previousCharacterVideo);
 characterVideo=previousCharacterVideo;
 if(characterVideoObserver){
 characterVideoObserver.unobserve(characterVideo);
 characterVideoObserver.observe(characterVideo);
 }
 }else if(previousCharacterVideo){
 characterVideoObserver?.unobserve(previousCharacterVideo);
 releaseCharacterVideo(previousCharacterVideo);
 }
 if(characterVideo)void hydrateCharacterVideo(characterVideo);
 else{
 const directVideo=body.querySelector('video.city-character-portrait-video');
 if(directVideo){
 directVideo.muted=true;
 directVideo.defaultMuted=true;
 const playWhenReady=()=>directVideo.play().catch(()=>{});
 directVideo.addEventListener('loadedmetadata',playWhenReady,{once:true});
 if(directVideo.readyState>=1)playWhenReady();
 }
 }
 const dots=card.querySelectorAll('.city-character-page-dots i');
 dots.forEach((dot,index)=>dot.classList.toggle('active',mode==='status'&&index===page));
 const pageButtons=card.querySelectorAll('.city-character-page-button');
 pageButtons.forEach(button=>button.disabled=mode!=='status');
 };
 locationModal?.addEventListener('click',async event=>{
 const retryButton=event.target.closest('[data-action="city-people-retry"]');
 if(retryButton){
 event.preventDefault();event.stopPropagation();
 const pager=cityScenePageStates.get(locationModal.dataset.place);
 if(pager){pager.error=null;void loadCityPeoplePage(locationModal.dataset.place);}
 return;
 }
 const loadMoreButton=event.target.closest('[data-action="city-people-load-more"]');
 if(loadMoreButton){
 event.preventDefault();event.stopPropagation();
 void loadCityPeoplePage(locationModal.dataset.place);
 return;
 }
 const personButton=event.target.closest('[data-action="city-person"]');
 if(personButton){
 event.preventDefault();event.stopPropagation();
 const person=cityPresenceByPlace[locationModal.dataset.place]?.[Number(personButton.dataset.personIndex)];
 if(!person||!isCurrentCityCharacterEligible(person)){
 toast('此角色已不在公開城市行程中。');
 await openCityLocation({dataset:{place:locationModal.dataset.place}});
 return;
 }
 const live=state.characters.find(item=>item.id===person.id);
 const cardPerson={...live,...person};
 ['name','gender','age','image','avatar_url','avatarVideoPath','avatar_video_path','intro','description'].forEach(key=>{if((person?.[key]==null||person?.[key]==='')&&live?.[key]!=null)cardPerson[key]=live[key];});
 renderCityCharacterCard(cardPerson,0);
 return;
 }
 const cardAction=event.target.closest('[data-action^="city-character-"]')?.dataset.action;
 if(cardAction==='city-character-close'){
 const card=$('cityCharacterCard');if(card)card.hidden=true;
 const venueInfo=$('cityMapPresenceList');if(venueInfo)venueInfo.hidden=false;
 locationModal.dataset.selectedPersonIndex='';
 return;
 }
 if(cardAction==='city-character-status'||cardAction==='city-character-history'){
 const index=Number(locationModal.dataset.selectedPersonIndex);
 const person=cityPresenceByPlace[locationModal.dataset.place]?.[index];
 if(person){
 const mode=cardAction==='city-character-history'?'history':'status';
 renderCityCharacterCard(person,0,mode);
 if(mode==='history'){
 window.PoyozzEncounterHistory?.openHistory(person,currentUser,window.mySupabase,
 ()=>renderCityCharacterCard(person,0,mode),
 ()=>locationModal.dataset.cardMode==='history'&&locationModal.dataset.selectedPersonIndex===String(index),
 error=>toast(error?.message||'讀取相遇紀錄失敗，請稍後再試。'));
 }
 }
 return;
 }
 if(cardAction==='city-character-story'){
 const index=Number(locationModal.dataset.selectedPersonIndex);
 const person=cityPresenceByPlace[locationModal.dataset.place]?.[index];
 if(!person||!isCurrentCityCharacterEligible(person)){toast('此角色已不在公開城市行程中。');await openCityLocation({dataset:{place:locationModal.dataset.place}});return;}
 if(!currentUser()){
 requireLogin({page:'detail',id:person.id});
 return;
 }
 locationModal.hidden=true;
 document.body.classList.remove('city-location-active');
 go({page:'detail',id:person.id});
 return;
 }
 if(cardAction==='city-character-prev'||cardAction==='city-character-next'){
 const index=Number(locationModal.dataset.selectedPersonIndex);
 const person=cityPresenceByPlace[locationModal.dataset.place]?.[index];
 if(person)renderCityCharacterCard(person,cardAction==='city-character-next'?1:0,'status');
 return;
 }
 if(cardAction==='city-character-meet'){
 const index=Number(locationModal.dataset.selectedPersonIndex);
 const placeKey=locationModal.dataset.place;
 const person=cityPresenceByPlace[placeKey]?.[index];
 if(!person||!isCurrentCityCharacterEligible(person)){toast('此角色已不在公開城市行程中。');await openCityLocation({dataset:{place:placeKey}});return;}
 if(!requireLogin({page:'citymap',id:person.id}))return;
 const meetButton=event.target.closest('[data-action="city-character-meet"]');
 if(meetButton)meetButton.disabled=true;
 try{
 const resumedSession=await findResumableEncounterSession(person.id,placeKey);
 let encounterSession=null;
 if(resumedSession){
 try{
 await setEncounterLifecycleState(resumedSession.id,'resume');
 resumedSession.encounterTemporarilyLeftAt=null;
 resumedSession.archived=false;
 resumedSession.archivedAt=null;
 encounterSession=resumedSession;
 // Resume metadata is committed by encounter-session-state on the server.
 // Do not require a separate chat snapshot save to reopen the scene.
 }catch(error){
 if(error?.code!=='encounter_scene_expired_or_closed')throw error;
 resumedSession.archived=true;
 resumedSession.archivedAt=Date.now();
 resumedSession.encounterTemporarilyLeftAt=null;
 persist();
 encounterSession=await createEncounterSession(person,placeKey);
 }
 }else{
 encounterSession=await createEncounterSession(person,placeKey);
 }
 encounterSession.hidden=false;
 persist();
 locationModal.hidden=true;
 document.body.classList.remove('city-location-active');
 go({page:'conversation',id:encounterSession.id});
 toast(resumedSession && encounterSession.id===resumedSession.id?'已接續你們這次的相遇。':'已進入相遇模式；每次送出訊息依既有規則扣款。');
 }catch(error){
 console.error('從城市地點開始相遇失敗：',error);
 toast(error?.message||'相遇模式暫時無法使用，請稍後再試。');
 }finally{if(meetButton)meetButton.disabled=false;}
 }
 });
 $('cityMapAvatarStrip')?.addEventListener('error',event=>{
 const image=event.target;
 if(!(image instanceof HTMLImageElement)||!image.classList.contains('city-location-person-image')||image.dataset.characterAvatarId)return;
 const fallback=document.createElement('span');
 fallback.className='city-location-avatar-fallback';
 fallback.textContent=image.alt?.slice(0,1)||'角';
 image.replaceWith(fallback);
 },true);
 $('cityCharacterCardBody')?.addEventListener('error',event=>{
 const image=event.target;
 if(!(image instanceof HTMLImageElement)||!image.classList.contains('city-character-portrait')||image.dataset.characterAvatarId)return;
 const fallback=document.createElement('div');
 fallback.className='city-character-portrait city-character-portrait-fallback';
 fallback.textContent=image.alt?.slice(0,1)||'角';
 image.replaceWith(fallback);
 },true);
 stage.querySelectorAll('[data-action="city-landmark"]').forEach(marker=>{
 marker.addEventListener('keydown',event=>{
 if(event.key==='Enter'||event.key===' '){
 event.preventDefault();
 event.stopPropagation();
 openCityLocation(marker);
 }
 });
 });
 locationModal?.addEventListener('click',event=>{
 const close=event.target.closest('[data-action="city-close"]');
 if(close){event.preventDefault();event.stopPropagation();locationModal.hidden=true;document.body.classList.remove('city-location-active');}
 else event.stopPropagation();
 });
 stage.addEventListener('click',event=>{
 const button=event.target instanceof Element ? event.target.closest('[data-action]') : null;
 if(!button)return;
 if(button.dataset.action==='city-landmark'){
 event.preventDefault();
 event.stopPropagation();
 void openCityLocation(button);
 return;
 }
 if(button.dataset.action==='city-zoom-in'){event.preventDefault();event.stopPropagation();zoomBy(1.18);return;}
 if(button.dataset.action==='city-zoom-out'){event.preventDefault();event.stopPropagation();zoomBy(.85);return;}
 if(button.dataset.action==='city-traditional'){event.preventDefault();event.stopPropagation();go({page:'home'});}
 },true);
 resizeHandler=()=>{sizeWorld();clamp();};
 window.addEventListener('resize',resizeHandler,{passive:true});
 }
 });
})(window);
