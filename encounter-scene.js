/* POYOZZ Encounter scene presentation. Uses the shared chat composer, wallet,
   suggested replies, swipe controls, persistence and pending-turn handler. */
(function installEncounterScenePresentation(){
  const style=document.createElement('style');
  style.textContent=`
    .encounter-start-button{background:linear-gradient(135deg,#7969a8,#b17f9d)!important;color:#fff!important;border:1px solid #d8c8ef!important}
    .chat-main.encounter-scene{position:relative;isolation:isolate;overflow:hidden;height:100dvh!important;min-height:0!important;border:0!important;border-radius:0!important;background:#15141b!important}
    .chat-main.encounter-scene:before{content:"";position:absolute;inset:0;z-index:0;background:linear-gradient(180deg,rgba(10,9,17,.26),rgba(10,9,17,.08) 34%,rgba(10,9,17,.36) 57%,rgba(10,9,17,.88) 100%),var(--encounter-scene-photo,none) center/cover no-repeat,radial-gradient(ellipse at 70% 22%,#6a5a65 0%,#322b36 48%,#17141b 100%);filter:saturate(.9);transform:scale(1.025);pointer-events:none}
    .encounter-scene .chat-layout{height:100dvh!important;min-height:0!important}
    .encounter-scene .chat-heading{position:absolute!important;z-index:4;left:0;right:0;top:0;background:linear-gradient(180deg,rgba(10,9,17,.72),rgba(10,9,17,.18))!important;backdrop-filter:blur(8px);color:#fff;border:0!important;padding:calc(10px + env(safe-area-inset-top)) 10px 18px!important}
    .encounter-scene .chat-heading .chat-name,.encounter-scene .chat-heading .character-status-label{color:#fff}
    .encounter-scene .chat-heading .row.between>.row:last-child button:not([data-action="chat-settings-menu"]){display:none!important}
    .encounter-scene .chat-heading .character-status-dot{box-shadow:0 0 8px #22c55e55}
    .encounter-scene .messages{position:absolute!important;z-index:2;left:0;right:0;bottom:clamp(390px,48dvh,470px);height:auto;max-height:22dvh;min-height:0!important;overflow-y:auto;background:transparent!important;padding:12px 22px!important;overscroll-behavior:contain}
    .encounter-scene .message{max-width:100%;background:transparent!important;align-items:flex-start}
    .encounter-scene .message-content{max-width:100%;padding:0!important;background:transparent!important;border:0!important;box-shadow:none!important;color:#fff!important}
    .encounter-scene .message-name{display:none}
    .encounter-scene .bubble,.encounter-scene .narration{color:#fff!important;text-shadow:0 2px 8px #000b;font-size:clamp(14px,3.7vw,18px);line-height:1.6}
    .encounter-scene .message-more{color:#fff;background:#17141b66}
    .encounter-character-sprite.encounter-card-portrait-fallback{object-fit:contain;object-position:center bottom;filter:drop-shadow(0 10px 22px rgba(0,0,0,.22))}.encounter-character-sprite.encounter-auto-bg-fallback{mix-blend-mode:multiply}
    .encounter-character-sprite{position:absolute;z-index:1;pointer-events:none;right:-2%;bottom:0;width:min(108%,680px);height:78dvh;object-fit:contain;object-position:center bottom;filter:drop-shadow(0 12px 24px rgba(0,0,0,.28));opacity:.98}
    .encounter-scene .composer{position:absolute!important;z-index:3;left:0;right:0;bottom:0;max-height:56dvh;overflow-y:auto;background:linear-gradient(180deg,rgba(17,14,24,.12),rgba(17,14,24,.92) 18%)!important;border:0!important;border-radius:24px 24px 0 0!important;padding:12px 14px calc(12px + env(safe-area-inset-bottom))!important;backdrop-filter:blur(12px)}
    .encounter-scene .suggestions{margin:0 0 8px!important}
    .encounter-scene .suggestions-panel{border:0!important;background:transparent!important;overflow:visible!important}
    .encounter-scene .suggestions-panel>summary{display:flex;align-items:center;justify-content:space-between;color:#fff!important;font-size:13px;padding:4px 2px 8px!important;list-style:none}
    .encounter-scene .suggestions-panel>summary::-webkit-details-marker{display:none}
    .encounter-scene .suggestions-panel>summary:after{display:none}
    .encounter-scene .suggestions-count{color:#d4cedd!important;font-size:11px}
    .encounter-scene .suggestion-options{display:flex!important;padding:0 2px 7px!important;gap:7px}
    .encounter-scene .suggestion-light{width:9px;height:9px;min-width:9px;background:#ffffff22;box-shadow:inset 0 0 0 1px #e7e0f0}
    .encounter-scene .suggestion-light[aria-pressed="true"]{background:#bda5f4;box-shadow:0 0 8px #bda5f488}
    .encounter-scene .suggestion-card,.encounter-scene .suggestion-card.active{display:block!important;width:100%;max-height:82px;overflow:auto;margin:0 0 7px;padding:9px 11px!important;border:1px solid #ffffff35!important;border-radius:13px!important;background:rgba(244,239,249,.13)!important;color:#fff!important;text-align:left;backdrop-filter:blur(14px)}
    .encounter-scene .suggestion-card-title{font-size:12px;color:#fff;margin-bottom:3px}
    .encounter-scene .suggestion-card-action,.encounter-scene .suggestion-card-dialogue{display:inline!important;font-size:12px;line-height:1.45;color:#f5f0fa!important;overflow:visible;-webkit-line-clamp:unset}
    .encounter-scene .suggestion-card-dialogue{margin-left:3px}
    .encounter-scene .suggestion-card:not(.active){opacity:.92}
    .encounter-scene .composer-input-row{margin-top:7px}
    .encounter-scene #messageInput{min-height:48px;max-height:100px;background:rgba(255,255,255,.13)!important;color:#fff!important;border:1px solid #ffffff40!important;border-radius:15px!important;padding:12px!important}
    .encounter-scene #messageInput::placeholder{color:#e0d9e7!important}
    .encounter-scene .composer-bottom-row{display:flex;align-items:center;justify-content:space-between;gap:8px;padding-top:8px}
    .encounter-scene .composer-icon-button{background:rgba(255,255,255,.1)!important;border:1px solid #ffffff32!important;color:#fff!important}
    .encounter-scene .composer-cost{color:#fff!important;background:rgba(255,255,255,.08)!important;border-color:#ffffff30!important}
    .encounter-scene .composer-send{border-radius:50%!important;min-width:48px;min-height:48px}
    .encounter-scene .chat-tools{background:rgba(25,21,34,.94);padding:7px;border-radius:12px}
    .encounter-scene .chat-tools button{color:#fff}
    .encounter-scene .chat-layout{display:block!important}
    .encounter-scene .chat-list{display:none!important}
    .encounter-scene .chat-main{width:100%!important}
    /* Latest encounter UI refinement: extend the dim scene through the entire viewport,
       keep the original identity row, and use compact horizontal glass suggestions. */
    .chat-main.encounter-scene{background:#17171b!important}
    .encounter-scene .chat-heading{padding:calc(9px + env(safe-area-inset-top)) 12px 12px!important;background:rgba(18,19,23,.42)!important;backdrop-filter:blur(18px) saturate(115%)}
    .encounter-scene .chat-heading>.row.between{align-items:center}
    .encounter-scene .chat-heading .row.grow{align-items:center;gap:7px!important;flex-wrap:wrap}
    .encounter-scene .chat-heading .chat-name{font-size:14px;max-width:38vw}
    .encounter-scene .chat-heading .encounter-scene-label{display:inline-flex!important;align-items:center;margin:0!important;padding:3px 7px!important;border-radius:999px;background:rgba(225,226,232,.13);border:1px solid rgba(255,255,255,.18);color:#f1f1f4!important;font-size:10px!important;letter-spacing:.04em!important;white-space:nowrap}
    .encounter-scene .messages{bottom:clamp(220px,30dvh,300px)!important;max-height:35dvh!important;padding:10px 16px!important}
    .encounter-scene .message.user{display:none!important}
    .encounter-scene .message:not(.user) .message-content{padding:9px 12px!important;border:1px solid rgba(255,255,255,.18)!important;border-radius:15px!important;background:rgba(27,28,33,.28)!important;backdrop-filter:blur(9px);text-shadow:0 1px 6px #0009}
    .encounter-scene .encounter-character-sprite{bottom:0!important;height:78dvh!important;width:min(108%,680px)!important;right:-2%!important}
    .encounter-scene .composer{max-height:44dvh!important;padding:8px 12px calc(8px + env(safe-area-inset-bottom))!important;background:linear-gradient(180deg,rgba(24,25,30,.12),rgba(22,23,28,.60) 20%,rgba(22,23,28,.78))!important;border-top:1px solid rgba(255,255,255,.13)!important;backdrop-filter:blur(18px) saturate(110%)}
    .encounter-scene .suggestions{margin:0 0 5px!important}
    .encounter-scene .suggestions-panel>summary{font-size:11px;padding:2px 2px 5px!important}
    .encounter-scene .suggestion-options{padding:0 2px 5px!important;gap:9px}
    .encounter-scene .suggestion-light{width:7px;height:7px;min-width:7px}
    .encounter-scene .suggestion-cards,.encounter-scene .suggestions-panel{min-width:0}
    .encounter-scene .suggestion-card,.encounter-scene .suggestion-card.active{display:block!important;width:100%!important;max-width:100%!important;max-height:54px!important;min-height:0!important;overflow:hidden!important;white-space:normal;margin:0 0 2px!important;padding:6px 9px!important;border-radius:10px!important;background:rgba(226,228,233,.16)!important;border:1px solid rgba(255,255,255,.23)!important;box-shadow:inset 0 1px rgba(255,255,255,.12);backdrop-filter:blur(16px)}
    .encounter-scene .suggestions-panel .suggestion-card{display:none!important}
    .encounter-scene .suggestions-panel .suggestion-card.active{display:block!important}
    .encounter-scene .suggestion-card-title{font-size:10px!important;margin-bottom:1px!important}
    .encounter-scene .suggestion-card-action,.encounter-scene .suggestion-card-dialogue{font-size:11px!important;line-height:1.3!important;display:-webkit-box!important;-webkit-box-orient:vertical;-webkit-line-clamp:2;overflow:hidden}
    .encounter-scene .suggestion-card-dialogue{margin-left:2px}
    .encounter-scene .composer-input-row{margin-top:4px!important}
    .encounter-scene #messageInput{min-height:38px!important;max-height:76px!important;padding:8px 10px!important;border-radius:12px!important;font-size:13px!important;background:rgba(235,236,240,.13)!important;border-color:rgba(255,255,255,.23)!important;backdrop-filter:blur(16px)}
    .encounter-scene .composer-bottom-row{padding-top:5px!important}
    .encounter-scene .composer-send{min-width:40px!important;min-height:40px!important}
    .encounter-scene .chat-tools{background:rgba(28,29,34,.58)!important;border:1px solid rgba(255,255,255,.15);backdrop-filter:blur(18px)}
    .encounter-scene .chat-settings-overlay{background:linear-gradient(135deg,rgba(225,227,232,.20),rgba(108,112,122,.22))!important;border:1px solid rgba(255,255,255,.25)!important;box-shadow:0 18px 50px #0005,inset 0 1px #ffffff25!important;backdrop-filter:blur(24px)!important;color:#f7f7fa!important}
    .encounter-scene .chat-settings-overlay .profile-setting{background:rgba(35,36,41,.28)!important;border:1px solid rgba(255,255,255,.18)!important;color:#f7f7fa!important}
    .encounter-scene .chat-settings-overlay .profile-setting small{color:#d5d6dc!important}
    .encounter-scene .encounter-missing-art{position:absolute;z-index:1;right:16px;bottom:clamp(390px,49dvh,480px);max-width:45%;padding:8px 10px;border-radius:12px;background:#17141b66;color:#ffffffa8;font-size:10px;pointer-events:none}
    @media(max-width:767px){
      .chat-main.encounter-scene{height:100dvh!important;min-height:0}
      .encounter-scene .messages{bottom:clamp(390px,48dvh,460px);max-height:19dvh;padding:8px 20px!important}
      .encounter-character-sprite{right:-2%!important;bottom:0!important;width:min(108%,680px)!important;height:78dvh!important}
      .encounter-scene .composer{max-height:57dvh;padding:10px 12px calc(10px + env(safe-area-inset-bottom))!important}
      .encounter-scene .suggestion-card,.encounter-scene .suggestion-card.active{max-height:72px;padding:7px 9px!important;margin-bottom:5px}
      .encounter-scene .suggestion-card-action,.encounter-scene .suggestion-card-dialogue{font-size:11px}
      .encounter-scene .chat-heading{padding-top:calc(8px + env(safe-area-inset-top))!important}
    }

    /* Encounter fullscreen v2: detach the scene from legacy app/sidebar layout. */
    html:has(body.encounter-mode-active),body.encounter-mode-active{width:100%!important;height:100%!important;min-height:100%!important;overflow:hidden!important}
    body.encounter-mode-active .sidebar,
    body.encounter-mode-active #mobileNav,
    body.encounter-mode-active .app>header{display:none!important}
    body.encounter-mode-active .app{position:fixed!important;inset:0!important;width:100vw!important;height:100dvh!important;min-height:100dvh!important;margin:0!important;padding:0!important;overflow:hidden!important;transform:none!important}
    body.encounter-mode-active #view{position:fixed!important;inset:0!important;z-index:100!important;width:100vw!important;height:100dvh!important;min-height:100dvh!important;max-width:none!important;margin:0!important;padding:0!important;overflow:hidden!important}
    body.encounter-mode-active .chat-layout{position:fixed!important;inset:0!important;display:block!important;width:100vw!important;height:100dvh!important;min-height:100dvh!important;margin:0!important;padding:0!important;overflow:hidden!important}
    body.encounter-mode-active:has(.chat-main.encounter-scene){overflow:hidden!important}
    .chat-main.encounter-scene{position:fixed!important;inset:0!important;z-index:110!important;display:block!important;width:100vw!important;height:100dvh!important;min-height:100dvh!important;max-width:none!important;margin:0!important;padding:0!important;border:0!important;border-radius:0!important;overflow:hidden!important;isolation:isolate!important;background:#17141b!important}
    .chat-main.encounter-scene:before{position:absolute!important;inset:0!important;z-index:0!important;background-image:linear-gradient(180deg,rgba(10,9,17,.10),rgba(10,9,17,.12) 34%,rgba(10,9,17,.40) 66%,rgba(10,9,17,.92) 100%),var(--encounter-scene-photo,none),radial-gradient(ellipse at 70% 22%,#6a5a65 0%,#322b36 48%,#17141b 100%)!important;background-position:center,center,center!important;background-size:cover,cover,cover!important;background-repeat:no-repeat!important;transform:none!important;filter:none!important;content:""!important;pointer-events:none!important}
    .encounter-scene .chat-layout{position:absolute!important;inset:0!important;width:100%!important;height:100dvh!important;min-height:0!important;margin:0!important;padding:0!important}
    .encounter-scene .chat-main{position:absolute!important;inset:0!important;width:100%!important;height:100dvh!important;min-height:0!important;margin:0!important;border-radius:0!important}
    .encounter-scene .messages{bottom:clamp(265px,34dvh,360px)!important;max-height:clamp(110px,31dvh,330px)!important;overflow-y:auto!important;overscroll-behavior:contain!important;scrollbar-width:thin;scrollbar-color:rgba(230,225,245,.45) transparent}
    .encounter-scene .encounter-dialogue-beat{display:flex!important;flex-direction:column!important;gap:10px!important;width:100%!important;max-width:100%!important;min-height:74px!important;padding:14px 16px!important;border:1px solid rgba(255,255,255,.2)!important;border-radius:17px!important;background:linear-gradient(135deg,rgba(22,22,30,.58),rgba(22,22,30,.34))!important;color:#fff!important;text-align:left!important;white-space:pre-wrap!important;backdrop-filter:blur(14px)!important;box-shadow:0 10px 28px rgba(0,0,0,.12),inset 0 1px rgba(255,255,255,.1)!important}
    .encounter-scene .encounter-dialogue-text{font-size:clamp(15px,3.8vw,19px)!important;line-height:1.85!important;overflow-wrap:anywhere!important}
    .encounter-scene .encounter-dialogue-hint{align-self:flex-end!important;color:#e0d6f4!important;font-size:11px!important;letter-spacing:.04em!important}
    .encounter-scene .composer{max-height:50dvh!important;overflow-y:auto!important;overflow-x:hidden!important;overscroll-behavior:contain!important;touch-action:pan-y!important;padding:9px 12px calc(9px + env(safe-area-inset-bottom))!important;scrollbar-width:thin!important;scrollbar-color:rgba(230,225,245,.35) transparent!important}
    .encounter-scene .suggestions{display:block!important;min-height:0!important;margin:0 0 5px!important}
    .encounter-scene .suggestions-panel{display:block!important;max-height:none!important;min-height:0!important;overflow:visible!important}
    .encounter-scene .suggestions-panel>summary{position:relative!important;z-index:2!important;background:rgba(25,24,32,.42)!important;border-radius:8px!important}
    .encounter-scene .suggestion-cards{display:block!important;max-height:none!important;overflow:visible!important;touch-action:pan-y!important;padding:2px 3px 8px!important}
    .encounter-scene .suggestions-panel .suggestion-card{display:none!important}
    .encounter-scene .suggestions-panel .suggestion-card.active{display:block!important;width:100%!important;max-width:100%!important;max-height:clamp(90px,19dvh,190px)!important;min-height:54px!important;height:auto!important;overflow-y:auto!important;overflow-x:hidden!important;overscroll-behavior:contain!important;touch-action:pan-y!important;white-space:normal!important;margin:0!important;padding:10px 12px!important;border-radius:12px!important;background:rgba(226,228,239,.15)!important;border:1px solid rgba(255,255,255,.25)!important;color:#fff!important;text-align:left!important;box-shadow:inset 0 1px rgba(255,255,255,.12)!important;backdrop-filter:blur(14px)!important;scrollbar-width:thin!important;scrollbar-color:rgba(230,225,245,.45) transparent!important}
    .encounter-scene .suggestion-card-title{font-size:11px!important;line-height:1.5!important;white-space:normal!important;overflow-wrap:anywhere!important}
    .encounter-scene .suggestion-card-action,.encounter-scene .suggestion-card-dialogue{display:inline!important;font-size:12px!important;line-height:1.65!important;white-space:normal!important;overflow:visible!important;-webkit-line-clamp:unset!important;-webkit-box-orient:initial!important;overflow-wrap:anywhere!important}
    .encounter-scene .suggestion-card-dialogue{margin-left:3px!important}
    .encounter-scene .suggestion-card.active{border-color:rgba(205,184,255,.72)!important;background:rgba(143,120,190,.27)!important}
    .encounter-scene .composer-input-row{flex:0 0 auto!important}
    @media(max-width:767px){
      .encounter-scene .chat-heading{left:0!important;right:0!important;padding-top:calc(8px + env(safe-area-inset-top))!important}
      .encounter-scene .messages{bottom:clamp(300px,39dvh,390px)!important;max-height:clamp(100px,27dvh,240px)!important;padding:8px 14px!important}
      .encounter-character-sprite{right:-2%!important;bottom:0!important;width:min(108%,680px)!important;height:78dvh!important;max-height:none!important}
      .encounter-scene .composer{max-height:54dvh!important;overflow-y:auto!important;overflow-x:hidden!important;padding:7px 10px calc(7px + env(safe-area-inset-bottom))!important}
      .encounter-scene .suggestions-panel{max-height:clamp(112px,26dvh,235px)!important}
      .encounter-scene .suggestion-cards{max-height:clamp(90px,22dvh,190px)!important}
      .encounter-scene .suggestions-panel .suggestion-card,.encounter-scene .suggestions-panel .suggestion-card.active{padding:9px 10px!important}
      .encounter-scene .suggestion-card-action,.encounter-scene .suggestion-card-dialogue{font-size:12px!important;line-height:1.6!important}
      .encounter-scene .composer-bottom-row{padding-top:4px!important}
    }
  `;;
  document.head.appendChild(style);
  const splitEncounterBeats=(value)=>{
    const source=String(value||'').replace(/\r\n?/g,'\n').replace(/[ \t]+\n/g,'\n').trim();
    if(!source)return [];
    const paragraphs=source.split(/\n+/).map(x=>x.trim()).filter(Boolean);
    const beats=[];
    const pushSentence=(text)=>{
      const cleaned=String(text||'').replace(/^\s*[-*•]+\s*/,'').replace(/^\*+|\*+$/g,'').trim();
      if(!cleaned)return;
      // Long, unpunctuated prose is broken into readable visual-novel beats too.
      if(cleaned.length>58){
        const clauses=cleaned.split(/(?<=[，,、；;：:])/u).map(x=>x.trim()).filter(Boolean);
        if(clauses.length>1){
          let chunk='';
          for(const clause of clauses){
            if(chunk&&chunk.length+clause.length>48){beats.push(chunk);chunk=clause;}
            else chunk+=clause;
          }
          if(chunk)pushSentence(chunk);
          return;
        }
        for(let i=0;i<cleaned.length;i+=48)beats.push(cleaned.slice(i,i+48));
        return;
      }
      beats.push(cleaned);
    };
    for(const paragraph of paragraphs){
      const sentences=paragraph.match(/[^。！？!?；;]+[。！？!?；;」』”’"）)】]*/gu)||[paragraph];
      for(const sentence of sentences){
        const part=sentence.trim();
        if(part)pushSentence(part);
      }
    }
    return beats;
  };
  // Re-apply the visual-novel beat after BOTH full conversation renders and message-only renders.
  // The base chat renderer can replace #messages after renderConversation finishes; this hook prevents it
  // from restoring ordinary chat bubbles and silently cancelling progressive dialogue.
  const applyEncounterDialogue=(panel,session)=>{
    const messages=panel?.querySelector('.messages');
    if(!messages)return;
    const allMessages=Array.isArray(session?.messages)?session.messages:[];
    const latestReply=[...allMessages].reverse().find(m=>m&&m.role!=='user'&&String(m.text??m.content??'').trim());
    const raw=String(latestReply?.text??latestReply?.content??'').trim();
    const beats=raw?splitEncounterBeats(raw):[];
    const beatKey=String(latestReply?.id||latestReply?.createdAt||latestReply?.timestamp||raw.slice(0,48))+':'+raw.length+':'+beats.length;
    if(session.encounterBeatKey!==beatKey){session.encounterBeatKey=beatKey;session.encounterBeatIndex=0;}
    const idx=Math.min(Math.max(0,Number(session.encounterBeatIndex)||0),Math.max(0,beats.length-1));
    const speakerCharacter=sessionCharacter(session);
    const speakerName=String(speakerCharacter?.name||speakerCharacter?.display_name||speakerCharacter?.character_name||'角色').trim();
    messages.innerHTML=beats.length
      ? '<button type="button" class="encounter-dialogue-beat" data-action="encounter-next-beat" aria-label="點擊繼續劇情"><span class="encounter-speaker-label">'+e(speakerName)+'</span><span class="encounter-dialogue-text">'+e(beats[idx])+'</span><span class="encounter-dialogue-hint">'+(idx<beats.length-1?'點擊繼續　⌄':'劇情已讀完')+'</span></button>'
      : '<div class="encounter-dialogue-empty" aria-hidden="true"></div>';
    messages.classList.toggle('encounter-dialogue-ready',beats.length>0);
    const composer=panel.querySelector('.composer');
    if(composer){
      const suggestions=composer.querySelector('.suggestions');
      if(suggestions)suggestions.hidden=beats.length>0&&idx<beats.length-1;
      composer.classList.toggle('encounter-awaiting-beat',beats.length>0&&idx<beats.length-1);
    }
    messages.dataset.encounterBeatKey=beatKey;
    messages.dataset.encounterBeatIndex=String(idx);
  };
  const encounterRenderLifecycle=window.PoyozzChatRenderLifecycle;
  if(encounterRenderLifecycle){
    encounterRenderLifecycle.register('afterSingleConversation','encounter.single-scene',({session:renderSession,panel:renderPanel})=>{
      const session=renderSession||currentSession();
      const panel=renderPanel||$('view')?.querySelector('.chat-main');
      if(!session?.encounterMode||!panel)return;
      panel.classList.add('encounter-scene');
      const character=sessionCharacter(session);
      const sceneImage=safeImage(character?.encounterSceneImage||session?.encounterSceneImage||character?.sceneImage||'');
      const defaultSceneImage='./encounter-default-scene.webp';
      panel.style.setProperty('--encounter-scene-photo','url('+JSON.stringify(sceneImage||defaultSceneImage)+')');
      panel.dataset.encounterPlace=session.encounterPlace||'';
      // Encounter scenes use dedicated encounter art or the author's scene-illustration gallery.
      // The character-card primary image is intentionally never reused as a scene sprite.
      const dedicatedSprite=safeImage(character?.encounterPortraitImage||character?.halfBodyImage||character?.transparentPortrait||character?.encounterSprite||'');
      const sceneIllustration=safeImage(character?.galleryIllustrations?.[0]?.src||'');
      const halfBodyImage=dedicatedSprite||sceneIllustration;
      let existingSprite=panel.querySelector('.encounter-character-sprite');
      const missingArt=panel.querySelector('.encounter-missing-art');
      if(halfBodyImage){
        if(missingArt)missingArt.remove();
        if(!existingSprite){
          existingSprite=document.createElement('img');
          existingSprite.className='encounter-character-sprite';
          existingSprite.alt='';
          existingSprite.setAttribute('aria-hidden','true');
          existingSprite.loading='eager';
          panel.insertBefore(existingSprite,panel.firstChild);
        }
        existingSprite.classList.toggle('encounter-card-portrait-fallback',!dedicatedSprite);
        if(existingSprite.dataset.encounterSource!==halfBodyImage){
          existingSprite.dataset.encounterSource=halfBodyImage;
          existingSprite.dataset.encounterProcessed='';
          existingSprite.classList.remove('encounter-auto-bg-fallback');
          if(!dedicatedSprite){
            existingSprite.crossOrigin='anonymous';
            existingSprite.onload=()=>{
              if(existingSprite.dataset.encounterSource!==halfBodyImage||existingSprite.dataset.encounterProcessed===halfBodyImage)return;
              try{
                const sourceImage=existingSprite;
                const canvas=document.createElement('canvas');
                canvas.width=sourceImage.naturalWidth;
                canvas.height=sourceImage.naturalHeight;
                const ctx=canvas.getContext('2d',{willReadFrequently:true});
                ctx.drawImage(sourceImage,0,0);
                const frame=ctx.getImageData(0,0,canvas.width,canvas.height);
                const pixels=frame.data,w=canvas.width,h=canvas.height,total=w*h;
                const visited=new Uint8Array(total);
                const stack=new Int32Array(total);
                let top=0;
                const nearWhite=(i)=>{
                  const p=i*4,red=pixels[p],green=pixels[p+1],blue=pixels[p+2];
                  return red>=218&&green>=218&&blue>=218&&Math.max(red,green,blue)-Math.min(red,green,blue)<= thirty;
                };
                const thirty=34;
                const push=(i)=>{if(i>=0&&i<total&&!visited[i]&&nearWhite(i)){visited[i]=1;stack[top++]=i;}};
                for(let x=0;x<w;x++){push(x);push((h-1)*w+x);}
                for(let y=0;y<h;y++){push(y*w);push(y*w+w-1);}
                while(top){
                  const i=stack[--top];
                  const p=i*4;
                  pixels[p+3]=0;
                  const x=i%w,y=(i/w)|0;
                  if(x>0)push(i-1);
                  if(x<w-1)push(i+1);
                  if(y>0)push(i-w);
                  if(y<h-1)push(i+w);
                }
                ctx.putImageData(frame,0,0);
                const transparentImage=canvas.toDataURL('image/png');
                existingSprite.dataset.encounterProcessed=halfBodyImage;
                existingSprite.onload=null;
                existingSprite.src=transparentImage;
              }catch(error){
                // If the image host disallows canvas access, use a visual blend fallback.
                existingSprite.dataset.encounterProcessed=halfBodyImage;
                existingSprite.classList.add('encounter-auto-bg-fallback');
              }
            };
          }
          existingSprite.src=halfBodyImage;
        }
      }else{
        if(existingSprite)existingSprite.remove();
        let artNote=missingArt;
        if(!artNote){
          artNote=document.createElement('div');
          artNote.className='encounter-missing-art';
          artNote.textContent='正在載入角色立繪…';
          artNote.setAttribute('aria-hidden','true');
          panel.insertBefore(artNote,panel.firstChild);
        }
        if(character?.id){
          const encounterSessionId=session.id;
          void hydrateEncounterGalleryIllustration(character.id).then(asset=>{
            if(!panel.isConnected||currentSession()?.id!==encounterSessionId)return;
            if(asset?.src){
              if(panel.querySelector('.encounter-character-sprite'))return;
              const sprite=document.createElement('img');
              sprite.className='encounter-character-sprite encounter-card-portrait-fallback';
              sprite.alt='';
              sprite.setAttribute('aria-hidden','true');
              sprite.loading='eager';
              sprite.dataset.encounterSource=asset.src;
              if(asset.path)sprite.dataset.characterIllustrationPath=asset.path;
              sprite.src=asset.src;
              panel.insertBefore(sprite,panel.firstChild);
              panel.querySelector('.encounter-missing-art')?.remove();
            }else if(artNote.isConnected){
              artNote.textContent='角色半立繪素材待補';
            }
          }).catch(error=>{
            if(artNote.isConnected)artNote.textContent='角色立繪暫時無法載入';
            console.warn('相遇場景立繪延遲載入失敗：',error?.message||error);
          });
        }else if(artNote){
          artNote.textContent='角色半立繪素材待補';
        }
      }
      const title=panel.querySelector('.chat-heading');
      if(title){
        let tag=title.querySelector('.encounter-scene-label');
        if(!tag){
          tag=document.createElement('span');tag.className='encounter-scene-label';tag.textContent='✦ 相遇模式';
          const identityRow=title.querySelector('.row.grow');
          tag.style.cssText='font-size:10px;letter-spacing:.04em;color:#f1f1f4;padding:3px 7px;border-radius:999px;background:rgba(225,226,232,.13);border:1px solid rgba(255,255,255,.18);white-space:nowrap';
          if(identityRow)identityRow.appendChild(tag);else title.appendChild(tag);
        }
      }
      const composer=panel.querySelector('.composer');
      if(composer){
        const input=composer.querySelector('#messageInput');
        if(input){input.placeholder='說點什麼，或留空讓角色繼續…';input.setAttribute('aria-label','相遇模式對話');}
      }
      applyEncounterDialogue(panel,session);
    });
    encounterRenderLifecycle.register('afterMessages','encounter.progressive-dialogue',({session:renderSession,panel:renderPanel})=>{
      const session=renderSession||currentSession();
      if(!session?.encounterMode)return;
      const panel=renderPanel||$('view')?.querySelector('.chat-main');
      if(panel){panel.classList.add('encounter-scene');applyEncounterDialogue(panel,session);}
    });
  }
  document.addEventListener('click',event=>{
    const target=event.target.closest('[data-action="encounter-next-beat"]');
    if(!target)return;
    const session=currentSession();
    if(!session?.encounterMode)return;
    const panel=target.closest('.chat-main');
    const messages=panel?.querySelector('.messages');
    if(!messages)return;
    const key=messages.dataset.encounterBeatKey||'';
    const latestReply=[...(session.messages||[])].reverse().find(m=>m.role!=='user'&&String(m.text||m.content||'').trim());
    const raw=String(latestReply?.text||latestReply?.content||'').trim();
    const beats=splitEncounterBeats(raw);
    if(session.encounterBeatKey!==key){session.encounterBeatKey=key;session.encounterBeatIndex=0;}
    if((session.encounterBeatIndex||0)<beats.length-1){session.encounterBeatIndex=(session.encounterBeatIndex||0)+1;persist();renderConversation();}
  });
})();
