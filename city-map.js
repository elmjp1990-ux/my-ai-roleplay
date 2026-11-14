/* POYOZZ city-map presentation module.
 * App-owned state and actions are injected explicitly; this module does not own
 * persistence, authentication, chat, encounter, or wallet business rules.
 */
(function (global) {
  'use strict';

  global.PoyozzCityMap = Object.freeze({
    render(dependencies) {
      const {
        $, state, accessible, escapeHTML, safeImage, currentUser, toast, go, requireLogin,
        persist, hydratePublicCharacterIllustrations, characterVideoObserver,
        releaseCharacterVideo, hydrateCharacterVideo, findResumableEncounterSession,
        setEncounterLifecycleState, saveChatSessionSafely, createEncounterSession, loadCityCharacterPage, loadCityCharacterSchedules
      } = dependencies;

  // A previous city-map render moves its dialog to <body>. Remove stale dialogs first;
  // otherwise duplicate IDs make later landmark clicks update an old, detached-from-view panel.
  document.querySelectorAll('#cityMapPeople').forEach(modal=>modal.remove());
  document.body.classList.remove('city-location-active');
  document.body.classList.add('city-map-mode');
  // Keep the early boot cover until the time-appropriate map asset is ready.
  const view=$('view');
  view.innerHTML=`
    <section class="city-map-stage" id="cityMapStage" aria-label="POYOZZ 城市地圖">
      <div class="city-map-world" id="cityMapWorld" aria-label="可拖曳地圖">
        <div class="city-map-river"></div>
        <div class="city-map-road r1"></div><div class="city-map-road r2"></div><div class="city-map-road r3"></div>
        <div class="city-map-block cafe"></div><div class="city-map-block school"></div><div class="city-map-block park"></div><div class="city-map-block shop"></div><div class="city-map-block home"></div>
        <svg class="city-building-layer" id="cityBuildingLayer" viewBox="0 0 1662 932" preserveAspectRatio="none" aria-label="城市地點玻璃圓形圖標">
          <!-- Marker anchors follow the user's annotated city-map reference; icons are specific to each place type. -->
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="airport" transform="translate(220 140)" tabindex="0" role="button" aria-label="機場"><circle class="city-marker-hit-area" r="38" fill="transparent" pointer-events="all"/><circle class="city-marker-glass" r="23"/><path class="city-marker-glyph" d="M 0 -11 L 2 -3 L 11 2 L 11 4 L 2 2 L 1 8 L 4 11 L 4 13 L 0 11 L -4 13 L -4 11 L -1 8 L -2 2 L -11 4 L -11 2 L -2 -3 Z"/></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="commercial" transform="translate(1305 94)" tabindex="0" role="button" aria-label="商業大樓"><circle class="city-marker-hit-area" r="38" fill="transparent" pointer-events="all"/><circle class="city-marker-glass" r="23"/><path class="city-marker-glyph" d="M -8 10 V -10 H 1 V 10 M 1 -3 H 8 V 10 M -5 -6 H -3 M -5 -1 H -3 M -5 4 H -3 M 4 0 H 6 M 4 5 H 6 M -2 10 V 6 H 0 V 10"/></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="night-bar" transform="translate(632 294)" tabindex="0" role="button" aria-label="夜間酒吧"><circle class="city-marker-hit-area" r="38" fill="transparent" pointer-events="all"/><circle class="city-marker-glass" r="23"/><path class="city-marker-glyph" d="M -10 -9 H 10 L 3 0 V 6 H 7 V 10 H -7 V 6 H -3 V 0 Z M -5 -5 L -2 -2 M 2 -5 L 5 -2"/></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="live-house" transform="translate(868 416)" tabindex="0" role="button" aria-label="Live House 音樂酒吧"><circle class="city-marker-hit-area" r="38" fill="transparent" pointer-events="all"/><circle class="city-marker-glass" r="23"/><path class="city-marker-glyph" d="M 2 -10 V 5 A 4 4 0 1 1 -1 1 V -6 L 9 -9 V 2 A 4 4 0 1 1 6 -2 V -7 Z"/></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="apartment" transform="translate(666 440)" tabindex="0" role="button" aria-label="308公寓"><circle class="city-marker-hit-area" r="38" fill="transparent" pointer-events="all"/><circle class="city-marker-glass" r="23"/><path class="city-marker-glyph" d="M -8 10 V -10 H 8 V 10 M -4 -6 H -2 M 3 -6 H 5 M -4 -1 H -2 M 3 -1 H 5 M -4 4 H -2 M 3 4 H 5 M -2 10 V 7 H 2 V 10"/></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="department-store" transform="translate(1020 300)" tabindex="0" role="button" aria-label="百貨公司"><circle class="city-marker-hit-area" r="38" fill="transparent" pointer-events="all"/><circle class="city-marker-glass" r="23"/><path class="city-marker-glyph" d="M -9 -3 H 9 L 7 10 H -7 Z M -6 -3 V -6 Q -6 -10 0 -10 Q 6 -10 6 -6 V -3 M -9 -3 L -11 1 M 9 -3 L 11 1"/></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="bookstore" transform="translate(480 733)" tabindex="0" role="button" aria-label="書店"><circle class="city-marker-hit-area" r="38" fill="transparent" pointer-events="all"/><circle class="city-marker-glass" r="23"/><path class="city-marker-glyph" d="M -10 -7 Q -4 -9 0 -5 Q 4 -9 10 -7 V 8 Q 4 6 0 10 Q -4 6 -10 8 Z M 0 -5 V 10 M -7 -4 Q -4 -5 -2 -3 M 2 -3 Q 5 -5 7 -4"/></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="cafe" transform="translate(645 624)" tabindex="0" role="button" aria-label="咖啡廳"><circle class="city-marker-hit-area" r="38" fill="transparent" pointer-events="all"/><circle class="city-marker-glass" r="23"/><path class="city-marker-glyph" d="M -8 -4 H 6 V 5 Q 6 10 0 10 H -2 Q -8 10 -8 5 Z M 6 -2 H 9 Q 12 -2 11 2 Q 10 5 6 4 M -5 -8 Q -8 -11 -5 -13 M 0 -8 Q -3 -11 0 -13 M 4 -8 Q 1 -11 4 -13"/></g>
          <g class="city-place-marker is-available" data-action="city-landmark" data-place="park" transform="translate(750 766)" tabindex="0" role="button" aria-label="中央公園"><circle class="city-marker-hit-area" r="38" fill="transparent" pointer-events="all"/><circle class="city-marker-glass" r="23"/><path class="city-marker-glyph" d="M 0 -11 L -7 -2 H -3 L -8 4 H -2 V 10 H 2 V 4 H 8 L 3 -2 H 7 Z"/></g>
        </svg>

      </div>
      <div class="city-map-ui" id="cityMapUI">
        <aside class="city-map-info">
          <h2 class="city-map-title"><img src="./LOGO_WEBLOGO.webp" alt="POYOZZ"> <span>城市</span></h2>
          <div id="cityMapDate">台灣時間</div>
          <div class="city-map-weather"><span>🌤️</span><span id="cityMapWeather">天氣資料待串接</span><span id="cityMapTemp">溫度待串接</span></div>
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
          <div class="city-location-title-row"><span class="city-location-scene-icon city-location-title-icon" id="cityMapPlaceIcon" aria-hidden="true">☕</span><h2 id="cityMapPlaceTitle">咖啡廳</h2><span class="city-location-open-inline"><i></i><span>營業中</span></span></div>
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
    // Detect marker taps here only to keep them out of map-drag handling.
    // Do NOT open the modal on pointerdown: on touch devices the synthesized click
    // may then land on the newly displayed backdrop and immediately close it.
    const marker=direct||[...stage.querySelectorAll('[data-action="city-landmark"]')].find(node=>{
      const r=node.getBoundingClientRect();
      return e.clientX>=r.left-8&&e.clientX<=r.right+8&&e.clientY>=r.top-8&&e.clientY<=r.bottom+8;
    });
    // Keep marker taps out of map-drag handling without cancelling the browser's synthesized click.
    // Calling preventDefault() on pointerdown can suppress click on mobile browsers, leaving the static modal content unchanged.
    if(marker){e.stopPropagation();return;}
    if(e.target instanceof Element&&e.target.closest('button,.city-map-info,.city-map-zoom,.city-map-bottom,.city-map-people'))return;
    stage.setPointerCapture?.(e.pointerId);pointers.set(e.pointerId,{x:e.clientX,y:e.clientY});moved=false;
    if(pointers.size===1)start={x:e.clientX,y:e.clientY,tx,ty,time:Date.now()};
    else if(pointers.size===2){const a=[...pointers.values()];start={distance:Math.hypot(a[0].x-a[1].x,a[0].y-a[1].y),scale,kind:'pinch'};}
  });
  stage.addEventListener('pointermove',e=>{if(!pointers.has(e.pointerId))return;pointers.set(e.pointerId,{x:e.clientX,y:e.clientY});if(pointers.size===2&&start?.kind==='pinch'){const a=[...pointers.values()];const d=Math.hypot(a[0].x-a[1].x,a[0].y-a[1].y);scale=start.scale*d/Math.max(1,start.distance);clamp();moved=true;}else if(pointers.size===1&&start&&!start.kind){const dx=e.clientX-start.x,dy=e.clientY-start.y;if(Math.abs(dx)+Math.abs(dy)>5)moved=true;tx=start.tx+dx;ty=start.ty+dy;clamp();}});
  const endPointer=e=>{pointers.delete(e.pointerId);if(pointers.size===0){if(start&&!moved&&Date.now()-start.time<280){const now=Date.now(),dx=e.clientX-lastTapX,dy=e.clientY-lastTapY;if(now-lastTap<320&&Math.hypot(dx,dy)<24){document.body.classList.toggle('city-map-mode-immersive');lastTap=0;}else{lastTap=now;lastTapX=e.clientX;lastTapY=e.clientY;}}start=null;}else if(pointers.size===1){const p=[...pointers.values()][0];start={x:p.x,y:p.y,tx,ty,time:Date.now()};}};
  stage.addEventListener('pointerup',endPointer);stage.addEventListener('pointercancel',endPointer);stage.addEventListener('dblclick',e=>e.preventDefault());stage.addEventListener('contextmenu',e=>e.preventDefault());
  // 2025 Taipei solar-time reference profile. Calculate the 2025 reference day locally;
  // no sunrise/sunset API or daily network request is needed.
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
  document.addEventListener('visibilitychange',()=>{if(!document.hidden)taipeiTime();});

  // Keep the location dialog outside the transformed map stage to isolate it from map gestures.
  const locationModal=$('cityMapPeople');
  if(locationModal && locationModal.parentElement!==document.body) document.body.appendChild(locationModal);
  const cityPlaceNames={airport:'機場',commercial:'商業大樓','night-bar':'夜間酒吧','live-house':'Live House／音樂酒吧',apartment:'308公寓','department-store':'百貨公司',bookstore:'書店',cafe:'咖啡廳',park:'中央公園'};
  // These are authored scene descriptions, not live opening hours, character presence, or dynamically generated events.
  const cityVenueScenes={
    airport:{icon:'✈️',heading:'城市的起點與交會處',description:'航班資訊在大廳螢幕上流動，旅人拖著行李匆匆經過。候機座位、接機大廳與深夜航班，總有新的相遇可能。',eventLabel:'場景亮點',eventTitle:'抵達大廳的偶遇',eventDescription:'適合安排接機、送別、轉機途中或旅程開始前的故事。'},
    commercial:{icon:'🏢',heading:'玻璃帷幕下的繁忙日常',description:'電梯穿梭於不同樓層，會議室、辦公座位與窗邊休息區構成城市工作的節奏。白天忙碌，傍晚後則逐漸安靜。',eventLabel:'場景亮點',eventTitle:'下班後的窗邊時光',eventDescription:'適合商業談判、同事互動、秘密會面或忙碌一天後的短暫休息。'},
    'night-bar':{icon:'🍸',heading:'霓虹燈下的微醺夜色',description:'低亮度燈光映著吧台酒杯，音樂與交談聲交錯。角落座位保留一點私密感，適合卸下白天的面具。',eventLabel:'場景亮點',eventTitle:'吧台邊的陌生人',eventDescription:'適合深夜談心、偶然搭話、重逢或帶著秘密的夜間故事。'},
    'live-house':{icon:'🎸',heading:'讓音樂填滿整個夜晚',description:'舞台燈光、音箱震動與觀眾的歡呼交織成現場氛圍。演出前後的走廊與吧台，也可能發生比舞台更難忘的對話。',eventLabel:'場景亮點',eventTitle:'演出開始前',eventDescription:'適合樂團演出、後台相遇、樂迷交流或散場後的續攤情節。'},
    apartment:{icon:'🏠',heading:'308 公寓的日常與秘密',description:'熟悉的電梯聲、走廊燈光與各自緊閉的房門，讓這裡既有生活感，也保留鄰居之間尚未說出口的故事。',eventLabel:'場景亮點',eventTitle:'走廊裡的偶然碰面',eventDescription:'適合鄰居日常、借物、深夜返家或逐漸熟悉彼此的生活故事。'},
    'department-store':{icon:'🛍️',heading:'從精品櫥窗到美食樓層',description:'明亮的中庭連接各式品牌櫃位、服飾樓層與餐飲空間。人潮來去，購物、約會與臨時起意的行程都能在這裡展開。',eventLabel:'場景亮點',eventTitle:'中庭的週末人潮',eventDescription:'適合約會逛街、挑選禮物、偶遇熟人或在美食樓層稍作停留。'},
    bookstore:{icon:'📚',heading:'在書頁之間慢下腳步',description:'木質書架與紙張氣味讓時間放慢。新書展示區、靠窗閱讀座位與安靜的書架轉角，各自藏著不同的相遇方式。',eventLabel:'場景亮點',eventTitle:'同一本書的選擇',eventDescription:'適合交換閱讀心得、尋找某本書、安靜陪伴或從共同興趣開始的故事。'},
    cafe:{icon:'☕',heading:'在城市裡，找個地方歇歇腳',description:'咖啡香從吧台飄向窗邊座位，甜點櫃裡擺著當季蛋糕。這裡適合短暫休息、工作、約會，也適合和某個人慢慢聊起近況。',eventLabel:'場景亮點',eventTitle:'今日甜點的話題',eventDescription:'甜點櫃可作為聊天與約會的情境；實際品項、庫存與活動尚未連接動態資料。'},
    park:{icon:'🌳',heading:'城市裡的一片綠意',description:'步道穿過樹蔭與草地，長椅、噴水池和開闊的天空讓人暫時遠離喧鬧。清晨散步、午後閒聊或傍晚慢跑，都有不同的城市風景。',eventLabel:'場景亮點',eventTitle:'樹蔭下的片刻寧靜',eventDescription:'適合散步、慢跑、野餐、偶遇或在戶外談一場不急著結束的對話。'}
  };
  // Use only published characters whose own schedule data is already available to this client.
  // Never invent a character or query private schedule rows from the browser.
  const cityPlaceAliases={airport:['airport'],commercial:['commercial','office'], 'night-bar':['night-bar','bar'], 'live-house':['live-house','livehouse'], apartment:['apartment'], 'department-store':['department-store','department_store'], bookstore:['bookstore','book-store'], cafe:['cafe','coffee-shop'], park:['park']};
  const getTaipeiClock=()=>{
    const parts=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Taipei',weekday:'short',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(new Date());
    const values=Object.fromEntries(parts.map(part=>[part.type,part.value]));
    return {weekday:{Sun:0,Mon:1,Tue:2,Wed:3,Thu:4,Fri:5,Sat:6}[values.weekday],minutes:Number(values.hour)*60+Number(values.minute)};
  };
  // Public schedules live in character_schedules, not in the character row.
  // Always re-check through the server RPC when opening a city location. A cached
  // public schedule can outlive a public -> private change, so never reuse it.
  const isCurrentCityCharacterEligible=(person)=>{
    const live=(Array.isArray(state.characters)?state.characters:[]).find(item=>item?.id===person?.id);
    return !!live&&live.visibility==='public'&&!live.deletedAt&&live.cloudPublic!==false&&live.localOnly!==true&&!String(live.id||'').startsWith('seed-')&&accessible(live);
  };
  const getCityPresence=(place,sourceCharacters=state.characters)=>{
    const clock=getTaipeiClock();
    const aliases=cityPlaceAliases[place]||[place];
    return (Array.isArray(sourceCharacters)?sourceCharacters:[]).filter(character=>{
      // Author access to a private character is for management only. It must
      // never make that character a participant in the public city encounter.
      // Do not use accessible() here: it intentionally permits the owner to
      // view private characters elsewhere in the product.
      if(character?.visibility!=='public'||character.deletedAt||!accessible(character)) return false;
      const raw=String(character.encounterSchedules||'').trim();
      if(!raw) return false;
      return raw.split(/\r?\n/).some(line=>{
        const parts=line.trim().split('|').map(value=>value.trim());
        if(parts.length!==5) return false;
        const [day,start,end,key,activity]=parts;
        if(!aliases.includes(key)||!activity) return false;
        if(day!=='*'&&Number(day)!==clock.weekday) return false;
        if(!/^([01]\d|2[0-3]):[0-5]\d$/.test(start)||!/^([01]\d|2[0-3]):[0-5]\d$/.test(end)) return false;
        const now=clock.minutes,from=Number(start.slice(0,2))*60+Number(start.slice(3)),to=Number(end.slice(0,2))*60+Number(end.slice(3));
        return from<to?now>=from&&now<to:(now>=from||now<to);
      });
    }).map(character=>{
      const raw=String(character.encounterSchedules||'');
      const line=raw.split(/\r?\n/).find(item=>{
        const parts=item.trim().split('|').map(value=>value.trim());
        if(parts.length!==5||!(cityPlaceAliases[place]||[place]).includes(parts[3])||!parts[4]) return false;
        if(parts[0]!=='*'&&Number(parts[0])!==clock.weekday) return false;
        const from=Number(parts[1]?.slice(0,2))*60+Number(parts[1]?.slice(3)),to=Number(parts[2]?.slice(0,2))*60+Number(parts[2]?.slice(3));
        return Number.isFinite(from)&&Number.isFinite(to)&&(from<to?clock.minutes>=from&&clock.minutes<to:(clock.minutes>=from||clock.minutes<to));
      });
      const parts=String(line||'').trim().split('|').map(value=>value.trim());
      return {...character,cityStartTime:parts[1]||'',cityEndTime:parts[2]||'',cityActivity:parts[4]||''};
    });
  };
  const cityPresenceByPlace={};
  const cityScenePageStates=new Map();
  const renderCityPeopleStrip=(place)=>{
    const pager=cityScenePageStates.get(place);
    const people=pager?.people||[];
    const strip=$('cityMapAvatarStrip');
    if(!strip)return;
    strip.innerHTML=people.length
      ? people.map((person,index)=>{
          const characterName=String(person.name||'角色');
          const image=safeImage(person.image||person.avatar_url||person.avatar);
          const portrait=image
            ? '<img class="city-location-person-image" src="'+escapeHTML(image)+'" alt="" loading="lazy" referrerpolicy="no-referrer">'
            : '<span class="city-location-avatar-fallback">'+escapeHTML(characterName.slice(0,1))+'</span>';
          return '<button type="button" class="city-location-avatar city-location-person" data-action="city-person" data-person-index="'+index+'" aria-label="查看 '+escapeHTML(characterName)+' 的角色資訊">'+portrait+'<span class="city-location-person-name">'+escapeHTML(characterName)+'</span></button>';
        }).join('')
      : '<p class="city-location-empty">'+(pager?.loading?'正在讀取這個場景的角色…':'目前沒有角色排定在這個地點。')+'</p>';
    if(pager?.hasMore){
      strip.insertAdjacentHTML('beforeend','<button type="button" class="city-location-load-more" data-action="city-people-load-more" '+(pager.loading?'disabled':'')+'>載入更多角色（每次 10 位）</button>');
    }
    $('cityMapPeopleCount').textContent=people.length
      ? people.length+' 位角色符合目前時段'+(pager?.hasMore?' · 可載入更多':'')
      : (pager?.loading?'正在讀取…':'目前沒有符合時段的角色');
  };
  const loadCityPeoplePage=async(place)=>{
    const pager=cityScenePageStates.get(place);
    if(!pager||pager.loading||!pager.hasMore||typeof loadCityCharacterPage!=='function')return;
    pager.loading=true;
    renderCityPeopleStrip(place);
    try{
      const result=await loadCityCharacterPage(pager.offset);
      const items=Array.isArray(result?.items)?result.items:[];
      pager.offset+=items.length;
      pager.hasMore=result?.hasMore===true;
      pager.candidates=[...pager.candidates,...items];
      const schedules=await loadCityCharacterSchedules(items.map(person=>person.id));
      for(const person of items)person.encounterSchedules=schedules.get(person.id)||'';
      pager.people=getCityPresence(place,pager.candidates);
      cityPresenceByPlace[place]=pager.people;
    }catch(error){
      pager.error=error;
      console.error('讀取城市角色排程失敗：',error);
      toast('場景角色載入失敗，請稍後重試。');
    }finally{
      pager.loading=false;
      renderCityPeopleStrip(place);
    }
  };
  const openCityLocation=async(marker)=>{
    const place=marker?.dataset?.place;
    if(!place||!locationModal)return;
    const name=cityPlaceNames[place]||'地點';
    const scene=cityVenueScenes[place];
    if(!scene){console.error('城市地標缺少專屬場景設定：',place);toast('這個地點的場景資料尚未完成，請稍後再試。');return;}
    const venueNotices={
      bookstore:{label:'最新消息',items:['本週暢銷書排行已經更新。','本週六下午兩點將舉辦作家簽售會。']},
      cafe:{label:'最新消息',items:['本日限定甜點已上架，適合搭配店內手沖咖啡。','本週末推出季節限定飲品。']},
      park:{label:'最新消息',items:['本週末草地旁將舉辦小型手作市集。','傍晚時段適合散步，中央步道照明已開啟。']},
      'department-store':{label:'最新消息',items:['10 樓櫃位調整中，造成不便敬請見諒。','地下美食街有多樣美食，用餐期間歡迎前往用餐。','本週末中庭將舉辦季節主題展。']},
      airport:{label:'最新消息',items:['大廳服務櫃檯今日提供旅遊諮詢。','候機區新增安靜休息座位指引。']},
      commercial:{label:'管理室公告',items:['如有裝潢需求，請向管理處提出申請。','各辦公室包裹請寄件人填寫好收件單位。','廁所內的公用物品請愛惜使用。']},
      'night-bar':{label:'最新消息',items:['今晚有現場 DJ 音樂時段。','本週末吧台區安排主題音樂夜。']},
      'live-house':{label:'最新消息',items:['本週演出時刻表已更新。','週六晚間將舉辦新團專場演出。']},
      apartment:{label:'管委會公告',items:['公寓公共交誼區本週進行佈置更新。','公共區域請保持整潔，訪客請由住戶陪同進出。','本週六下午將舉辦住戶交換市集。']}
    };
    const notice=venueNotices[place]||{label:'最新消息',items:['這個場景有新的城市消息。']};
    const eventMarkup=notice.items.slice(0,3).map(item=>'<p>📣 '+escapeHTML(item)+'</p>').join('');
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
    const placeIcon=$('cityMapPlaceIcon');
    if(placeIcon)placeIcon.textContent=scene.icon;
    const renderVenue=()=>{
      const target=$('cityMapPresenceList');
      if(target)target.innerHTML='<h3 id="cityMapVenueHeading">'+escapeHTML(scene.heading)+'</h3><p id="cityMapVenueDescription">'+escapeHTML(scene.description)+'</p><div class="city-location-news"><span class="city-location-event-label">'+escapeHTML(notice.label)+'</span><div class="city-location-news-items">'+eventMarkup+'</div></div>'+flightMarkup;
    };
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
    const target=$('cityCharacterAffinity');
    if(!target||target.dataset.characterId!==String(characterId))return;
    if(!currentUser()){
      target.textContent='登入後查看與角色的好感度';
      return;
    }
    target.textContent='正在讀取好感度…';
    try{
      const client=window.mySupabase;
      if(!client)throw new Error('關係資料服務尚未連線');
      const {data,error}=await client.rpc('get_latest_settled_encounter_affinity',{p_character_id:characterId});
      if(error)throw error;
      const row=Array.isArray(data)?data[0]:data;
      const liveTarget=$('cityCharacterAffinity');
      if(!liveTarget||liveTarget.dataset.characterId!==String(characterId))return;
      if(!row){
        liveTarget.innerHTML='<span class="city-character-affinity-empty">你們還不認識</span>';
        liveTarget.setAttribute('aria-label','你們還不認識（尚無已結算的相遇紀錄）');
        return;
      }
      const affinity=Number(row.affinity);
      const labels={hostile:'敵對',dislike:'反感',wary:'戒備',first_meeting:'初次見面',acquaintance:'熟識',close:'親近',intimate:'親密',special:'特殊羈絆'};
      const stage=labels[row.relationship_stage];
      if(!Number.isInteger(affinity)||affinity < -100||affinity > 100||!stage)throw new Error('好感度資料格式不正確');
      const progress=Math.round((affinity+100)/2);
      const score=affinity>0?'+'+affinity:String(affinity);
      liveTarget.innerHTML='<div class="city-character-affinity-heading"><span>好感度</span><strong>'+score+'</strong><em>'+stage+'</em></div><div class="city-character-affinity-meter" role="img" aria-label="好感度進度 '+progress+'%"><i style="width:'+progress+'%"></i></div>';
      liveTarget.setAttribute('aria-label','好感度 '+score+'，關係階段 '+stage);
    }catch(error){
      console.warn('城市角色好感度載入失敗：',error?.message||error);
      const liveTarget=$('cityCharacterAffinity');
      if(liveTarget&&liveTarget.dataset.characterId===String(characterId)){
        liveTarget.textContent='好感度暫時無法載入';
        liveTarget.setAttribute('aria-label','好感度暫時無法載入');
      }
    }
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
    // Uploaded character videos are private Storage objects, so hydrate their signed URL.
    const videoPath=String(person.avatarVideoPath||person.avatar_video_path||person.characterVideoPath||'').trim();
    const videoRaw=String(person.videoUrl||person.video_url||person.introVideoUrl||person.intro_video_url||'').trim();
    const videoUrl=/^https:\/\//i.test(videoRaw)?videoRaw:'';
    const portrait=videoPath
      ? '<video class="city-character-portrait city-character-portrait-video" data-character-video="'+escapeHTML(videoPath)+'" autoplay muted loop playsinline preload="metadata" poster="'+escapeHTML(image||'')+'" aria-label="'+escapeHTML(person.name||'角色')+'角色展示影片"></video>'
      : videoUrl
        ? '<video class="city-character-portrait city-character-portrait-video" src="'+escapeHTML(videoUrl)+'" autoplay muted loop playsinline preload="metadata" poster="'+escapeHTML(image||'')+'" aria-label="'+escapeHTML(person.name||'角色')+'角色展示影片"></video>'
        : image
          ? '<img class="city-character-portrait" src="'+escapeHTML(image)+'" alt="'+escapeHTML(person.name||'角色')+'" loading="eager" referrerpolicy="no-referrer">'
          : '<div class="city-character-portrait city-character-portrait-fallback">'+escapeHTML(String(person.name||'角').slice(0,1))+'</div>';
    const name=escapeHTML(person.name||'未命名角色');
    const gender=escapeHTML(person.gender||'未設定');
    const age=escapeHTML(person.age?String(person.age)+' 歲':'未設定');
    const activity=escapeHTML(person.cityActivity||'在這個場景中度過自己的時間');
    const timeRange=person.cityStartTime&&person.cityEndTime?escapeHTML(person.cityStartTime+'–'+person.cityEndTime):'時間未設定';
    const placeKey=locationModal.dataset.place;
    const placeName=escapeHTML(cityPlaceNames[placeKey]||'城市地點');
    const intro=String(person.intro||person.description||person.personalityProfile?.summary||'這位角色尚未填寫公開介紹。');
    const sessions=Object.values(state.sessions||{}).filter(session=>session?.encounterMode&&session.characterId===person.id&&!session.archived)
      .sort((a,b)=>(Number(b.startedAt)||0)-(Number(a.startedAt)||0));
    const bookmarks='<div class="city-character-bookmarks" aria-label="角色功能"><button type="button" class="city-character-bookmark '+(mode==='status'?'active':'')+'" data-action="city-character-status" aria-label="角色資料">角色資料</button><button type="button" class="city-character-bookmark '+(mode==='history'?'active':'')+'" data-action="city-character-history" aria-label="相遇紀錄">相遇紀錄</button><button type="button" class="city-character-bookmark" data-action="city-character-story" aria-label="故事模式">故事模式</button></div>';
    const affinityMarkup=mode==='status'&&page===0?'<div class="city-character-affinity" id="cityCharacterAffinity" data-character-id="'+escapeHTML(person.id)+'">正在讀取好感度…</div>':'';
    const left='<div class="city-character-photo-column">'+portrait+affinityMarkup+'<button type="button" class="city-character-meet primary" data-action="city-character-meet">與他相遇</button></div>';
    let copy='';
    if(mode==='history'){
      const records=sessions.length?sessions.map(session=>{
        const when=new Date(Number(session.startedAt)||Date.now()).toLocaleDateString('zh-TW',{year:'numeric',month:'2-digit',day:'2-digit'});
        const venue=cityPlaceNames[session.encounterPlace]||'城市相遇';
        const lastUser=(session.messages||[]).filter(message=>message.role==='user').at(-1)?.content;
        const summary=lastUser?'對話片段：'+String(lastUser).slice(0,90):'兩人在'+venue+'相遇，故事仍待續。';
        return '<article class="city-encounter-history-item"><strong>'+escapeHTML(when)+' · '+escapeHTML(venue)+'</strong><p>'+escapeHTML(summary)+'</p></article>';
      }).join(''):'<p>目前還沒有已保存的相遇紀錄。完成「與他相遇」對話後，紀錄會顯示在這裡。</p>';
      copy='<div class="city-character-copy"><h3>'+name+'｜過往相遇</h3><div class="city-encounter-history-list">'+records+'</div></div>';
      $('cityCharacterPageLabel').textContent='相遇紀錄';
    }else if(mode==='story'){
      copy='<div class="city-character-copy"><h3>'+name+'｜故事模式</h3><p>正在開啟傳統角色聊天……</p></div>';
      $('cityCharacterPageLabel').textContent='故事模式';
    }else if(page===0){
      copy='<div class="city-character-copy"><h3>'+name+'</h3><div class="city-character-meta"><span>'+gender+'</span><span>'+age+'</span></div><p><strong>當前行程</strong><br>'+timeRange+'<br>'+placeName+'</p><p><strong>心情</strong><br>'+escapeHTML(person.cityMood||person.mood||'平靜')+'</p><p><strong>現在狀態</strong><br>'+activity+'</p></div>';
      $('cityCharacterPageLabel').textContent='角色狀態 · 01 / 02';
    }else{
      copy='<div class="city-character-copy"><h3>'+name+'｜角色介紹</h3><p>'+escapeHTML(intro)+'</p></div>';
      $('cityCharacterPageLabel').textContent='角色介紹 · 02 / 02';
    }
    const previousCharacterVideo=body.querySelector('video.city-character-portrait-video[data-character-video]');
    body.innerHTML=left+copy+bookmarks;
    if(mode==='status'&&page===0)void loadCityCharacterAffinity(person.id);
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
      renderCityCharacterCard(live,0);
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
      if(person)renderCityCharacterCard(person,0,cardAction==='city-character-history'?'history':'status');
      return;
    }
    if(cardAction==='city-character-story'){
      const index=Number(locationModal.dataset.selectedPersonIndex);
      const person=cityPresenceByPlace[locationModal.dataset.place]?.[index];
      if(!person||!isCurrentCityCharacterEligible(person)){toast('此角色已不在公開城市行程中。');await openCityLocation({dataset:{place:locationModal.dataset.place}});return;}
      // Story mode is an entry to the normal character introduction page, not an
      // immediate chat. Preserve the intended destination through sign-in.
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
        // 同一個角色今天仍在同一地標出現時，優先接回暫時離開的相遇 session。
        const resumedSession=findResumableEncounterSession(person.id,placeKey);
        let encounterSession=null;
        if(resumedSession){
          try{
            await setEncounterLifecycleState(resumedSession.id,'resume');
            resumedSession.encounterTemporarilyLeftAt=null;
            encounterSession=resumedSession;
            const saved=await saveChatSessionSafely(encounterSession);
            if(saved!==true)throw new Error('接續相遇狀態尚未同步保存。');
          }catch(error){
            if(error?.code!=='encounter_scene_expired_or_closed')throw error;
            // The authoritative scene clock has ended; archive the stale local resume candidate
            // and ask the backend to create a new session only if the character is still present.
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
    if(!(image instanceof HTMLImageElement)||!image.classList.contains('city-location-person-image'))return;
    const fallback=document.createElement('span');
    fallback.className='city-location-avatar-fallback';
    fallback.textContent=image.alt?.slice(0,1)||'角';
    image.replaceWith(fallback);
  },true);
  $('cityCharacterCardBody')?.addEventListener('error',event=>{
    const image=event.target;
    if(!(image instanceof HTMLImageElement)||!image.classList.contains('city-character-portrait'))return;
    const fallback=document.createElement('div');
    fallback.className='city-character-portrait city-character-portrait-fallback';
    fallback.textContent=image.alt?.slice(0,1)||'角';
    image.replaceWith(fallback);
  },true);
  // Bind activation directly to each SVG marker. Some mobile SVG click paths do not
  // reliably reach the stage-level delegated handler, so each landmark owns its click.
  stage.querySelectorAll('[data-action="city-landmark"]').forEach(marker=>{
    marker.addEventListener('click',event=>{
      event.preventDefault();
      event.stopPropagation();
      openCityLocation(marker);
    });
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
    // Landmark SVG groups have their own activation listener above. Never resolve
    // nearby coordinates here: that duplicated async open and caused a first-tap flash.
    if(button?.dataset.action==='city-landmark')return;
    if(!button)return;
    if(button.dataset.action==='city-zoom-in'){event.preventDefault();event.stopPropagation();zoomBy(1.18);return;}
    if(button.dataset.action==='city-zoom-out'){event.preventDefault();event.stopPropagation();zoomBy(.85);return;}
    if(button.dataset.action==='city-traditional'){event.preventDefault();event.stopPropagation();go({page:'home'});}
  });
  window.addEventListener('resize',()=>{sizeWorld();clamp();},{passive:true});
    }
  });
})(window);
