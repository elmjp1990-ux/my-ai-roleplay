/* POYOZZ Encounter scene presentation. Uses the shared chat composer, wallet,
   suggested replies, swipe controls, persistence and pending-turn handler. */
(function installEncounterScenePresentation(){
  const processEncounterSpriteBackdrop=(image,source)=>{
    image.crossOrigin='anonymous';
    image.onerror=()=>{
      image.dataset.encounterProcessed=source;
      image.classList.add('encounter-auto-bg-fallback');
      image.onload=null;
      image.onerror=null;
    };
    image.onload=()=>{
      if(image.dataset.encounterProcessed===source)return;
      try{
        const canvas=document.createElement('canvas');
        canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;
        const ctx=canvas.getContext('2d',{willReadFrequently:true});
        ctx.drawImage(image,0,0);
        const frame=ctx.getImageData(0,0,canvas.width,canvas.height),pixels=frame.data,w=canvas.width,h=canvas.height,total=w*h;
        const visited=new Uint8Array(total),stack=new Int32Array(total);let top=0;
        const neutralBackdrop=i=>{
          const p=i*4,r=pixels[p],g=pixels[p+1],b=pixels[p+2];
          return (r+g+b)/3>=140&&Math.max(r,g,b)-Math.min(r,g,b)<=42;
        };
        const push=i=>{if(i>=0&&i<total&&!visited[i]&&neutralBackdrop(i)){visited[i]=1;stack[top++]=i;}};
        for(let x=0;x<w;x++){push(x);push((h-1)*w+x);}
        for(let y=0;y<h;y++){push(y*w);push(y*w+w-1);}
        while(top){
          const i=stack[--top],p=i*4;pixels[p+3]=0;
          const x=i%w,y=(i/w)|0;
          if(x>0)push(i-1);if(x<w-1)push(i+1);if(y>0)push(i-w);if(y<h-1)push(i+w);
        }
        ctx.putImageData(frame,0,0);
        const result=canvas.toDataURL('image/png');
        image.dataset.encounterProcessed=source;
        image.onload=null;
        image.src=result;
      }catch(error){
        image.dataset.encounterProcessed=source;
        image.classList.add('encounter-auto-bg-fallback');
        image.onload=null;
      }
    };
    image.src=source;
  };
  const style=document.createElement('style');
  style.textContent=`
/* Canonical Encounter presentation stylesheet. Keyboard viewport sizing is controlled by
   the shared viewport script variables; all Encounter visual rules live here. */
html:has(body.encounter-mode-active),body.encounter-mode-active{width:100%!important;height:100%!important;min-height:100%!important;overflow:hidden!important}
body.encounter-mode-active .sidebar,body.encounter-mode-active #mobileNav,body.encounter-mode-active .app>header{display:none!important}
body.encounter-mode-active .app,body.encounter-mode-active #view,body.encounter-mode-active .chat-layout,.chat-main.encounter-scene{position:fixed!important;top:0!important;bottom:auto!important;inset-inline:0!important;width:100vw!important;height:100lvh!important;min-height:0!important;max-height:none!important;margin:0!important;padding:0!important;overflow:hidden!important;transform:none!important;display:block!important;z-index:110!important;isolation:isolate!important;border:0!important;border-radius:0!important;background:#17141b!important}
.chat-main.encounter-scene:before{content:""!important;position:absolute!important;inset:0!important;z-index:0!important;pointer-events:none!important;background-image:linear-gradient(180deg,rgba(10,9,17,.10),rgba(10,9,17,.12) 34%,rgba(10,9,17,.40) 66%,rgba(10,9,17,.92) 100%),var(--encounter-scene-photo,none),radial-gradient(ellipse at 70% 22%,#6a5a65 0%,#322b36 48%,#17141b 100%)!important;background-position:center!important;background-size:cover!important;background-repeat:no-repeat!important;transform:none!important;filter:none!important}
.encounter-scene .chat-layout,.encounter-scene .chat-main{position:absolute!important;inset:0!important;width:100%!important;height:100%!important;min-height:0!important;margin:0!important;padding:0!important}
.encounter-scene .chat-list{display:none!important}
.encounter-scene .chat-heading{position:absolute!important;z-index:4!important;top:0!important;left:0!important;right:0!important;width:100%!important;max-width:100vw!important;box-sizing:border-box!important;margin:0!important;transform:none!important;display:block!important;padding:calc(9px + env(safe-area-inset-top)) max(12px,env(safe-area-inset-right)) 12px max(12px,env(safe-area-inset-left))!important;background:rgba(18,19,23,.42)!important;backdrop-filter:blur(18px) saturate(115%)!important;color:#fff!important;border:0!important;border-bottom:1px solid rgba(255,255,255,.16)!important}
.encounter-scene .chat-heading>.row.between{display:flex!important;align-items:center!important;justify-content:space-between!important;gap:8px!important;flex-wrap:nowrap!important}
.encounter-scene .chat-heading .row.grow{min-width:0!important;flex-wrap:nowrap!important;align-items:center!important;gap:7px!important}
.encounter-scene .chat-heading .chat-name{color:#fff!important;font-size:14px!important;max-width:38vw}
.encounter-scene .chat-heading .character-status-label{color:#fff!important}
.encounter-scene .chat-heading .character-status-dot{box-shadow:0 0 8px #22c55e55}
.encounter-scene .chat-heading button{visibility:visible!important;opacity:1!important}
.encounter-scene .chat-heading .encounter-scene-label{display:inline-flex!important;align-items:center;margin:0!important;padding:3px 7px!important;border-radius:999px;background:rgba(225,226,232,.13);border:1px solid rgba(255,255,255,.18);color:#f1f1f4!important;font-size:10px!important;letter-spacing:.04em!important;white-space:nowrap}
.encounter-scene .chat-heading [data-kind="search"],.encounter-scene .chat-heading [data-action="phone-open"],.encounter-scene .chat-heading [data-kind="album"]{display:none!important}
.encounter-scene .chat-heading .encounter-affinity-chip{display:inline-flex!important;align-items:center;margin:0!important;padding:0!important;border:0!important;border-radius:0!important;background:transparent!important;color:inherit!important;font-size:inherit!important;white-space:normal!important}
.encounter-scene .messages{position:absolute!important;z-index:2!important;left:0!important;right:0!important;bottom:var(--poyozz-encounter-composer-height,190px)!important;height:auto!important;max-height:calc(var(--poyozz-chat-viewport-height,100dvh) - var(--poyozz-encounter-composer-height,190px) - 110px)!important;min-height:0!important;overflow-y:auto!important;overscroll-behavior:contain!important;scrollbar-width:thin!important;scrollbar-color:rgba(230,225,245,.45) transparent!important;background:transparent!important;padding:10px 16px!important}
.encounter-scene .message{max-width:100%;background:transparent!important;align-items:flex-start}
.encounter-scene .message.user{display:none!important}
.encounter-scene .message-content{max-width:100%;padding:0!important;background:transparent!important;border:0!important;box-shadow:none!important;color:#fff!important}
.encounter-scene .message-name{display:none}
.encounter-scene .message:not(.user) .message-content{padding:9px 12px!important;border:1px solid rgba(255,255,255,.18)!important;border-radius:15px!important;background:rgba(27,28,33,.28)!important;backdrop-filter:blur(9px);text-shadow:0 1px 6px #0009}
.encounter-scene .bubble,.encounter-scene .narration{color:#fff!important;text-shadow:0 2px 8px #000b;font-size:clamp(14px,3.7vw,18px);line-height:1.6}
.encounter-scene .message-more{color:#fff;background:#17141b66}
.encounter-scene .encounter-dialogue-beat{display:flex!important;flex-direction:column!important;gap:10px!important;width:100%!important;max-width:100%!important;min-height:74px!important;padding:14px 16px!important;border:1px solid rgba(255,255,255,.2)!important;border-radius:17px!important;background:linear-gradient(135deg,rgba(22,22,30,.58),rgba(22,22,30,.34))!important;color:#fff!important;text-align:left!important;white-space:pre-wrap!important;backdrop-filter:blur(14px)!important;box-shadow:0 10px 28px rgba(0,0,0,.12),inset 0 1px rgba(255,255,255,.1)!important}
.encounter-scene .encounter-dialogue-text{font-size:clamp(15px,3.8vw,19px)!important;line-height:1.85!important;overflow-wrap:anywhere!important}
.encounter-scene .encounter-dialogue-hint{align-self:flex-end!important;color:#e0d6f4!important;font-size:11px!important;letter-spacing:.04em!important}
.encounter-character-sprite{position:absolute!important;z-index:1!important;pointer-events:none!important;left:50%!important;right:auto!important;transform:translateX(-50%)!important;bottom:0!important;width:min(108%,680px)!important;height:78lvh!important;object-fit:contain!important;object-position:center bottom!important;max-height:none!important;filter:drop-shadow(0 12px 24px rgba(0,0,0,.28))!important;opacity:.98!important;background:transparent!important}
.encounter-character-sprite.encounter-card-portrait-fallback{object-fit:contain!important;object-position:center bottom!important;filter:drop-shadow(0 10px 22px rgba(0,0,0,.22))!important}
.encounter-character-sprite.encounter-auto-bg-fallback{mix-blend-mode:normal!important}
.encounter-scene .composer{position:absolute!important;z-index:3!important;left:0!important;right:0!important;width:100%!important;max-width:100vw!important;margin:0!important;transform:none!important;bottom:0!important;max-height:calc(var(--poyozz-chat-viewport-height,100dvh) - 72px)!important;overflow-y:auto!important;overflow-x:hidden!important;overscroll-behavior:contain!important;touch-action:pan-y!important;padding:7px max(10px,env(safe-area-inset-right)) calc(7px + env(safe-area-inset-bottom)) max(10px,env(safe-area-inset-left))!important;border:0!important;border-radius:20px 20px 0 0!important;background:linear-gradient(180deg,rgba(24,25,30,.12),rgba(22,23,28,.60) 20%,rgba(22,23,28,.78))!important;backdrop-filter:blur(18px) saturate(110%)!important;scrollbar-width:thin!important;scrollbar-color:rgba(230,225,245,.35) transparent!important}
.encounter-scene .suggestions{display:block!important;min-width:0!important;min-height:0!important;margin:0 0 5px!important}
.encounter-scene .suggestions-panel{display:block!important;min-width:0!important;max-height:clamp(112px,26dvh,235px)!important;min-height:0!important;overflow:visible!important;border:0!important;background:transparent!important}
.encounter-scene .suggestions-panel>summary{position:relative!important;z-index:2!important;display:flex!important;align-items:center!important;justify-content:space-between!important;background:rgba(25,24,32,.42)!important;border-radius:8px!important;color:#fff!important;font-size:11px!important;padding:2px 2px 5px!important;list-style:none!important}
.encounter-scene .suggestions-panel>summary::-webkit-details-marker,.encounter-scene .suggestions-panel>summary:after{display:none!important}
.encounter-scene .suggestions-count{color:#d4cedd!important;font-size:11px!important}
.encounter-scene .suggestion-options{display:flex!important;padding:0 2px 5px!important;gap:9px!important}
.encounter-scene .suggestion-light{width:7px!important;height:7px!important;min-width:7px!important;background:#ffffff22!important;box-shadow:inset 0 0 0 1px #e7e0f0!important}
.encounter-scene .suggestion-light[aria-pressed="true"]{background:#bda5f4!important;box-shadow:0 0 8px #bda5f488!important}
.encounter-scene .suggestion-cards{display:block!important;max-height:clamp(90px,22dvh,190px)!important;overflow:visible!important;touch-action:pan-y!important;padding:2px 3px 8px!important}
.encounter-scene .suggestions-panel .suggestion-card{display:none!important}
.encounter-scene .suggestions-panel .suggestion-card.active{display:block!important;width:100%!important;max-width:100%!important;max-height:clamp(90px,19dvh,190px)!important;min-height:54px!important;height:auto!important;overflow-y:auto!important;overflow-x:hidden!important;overscroll-behavior:contain!important;touch-action:pan-y!important;white-space:normal!important;margin:0!important;padding:9px 10px!important;border-radius:12px!important;background:rgba(226,228,239,.15)!important;border:1px solid rgba(255,255,255,.25)!important;color:#fff!important;text-align:left!important;box-shadow:inset 0 1px rgba(255,255,255,.12)!important;backdrop-filter:blur(14px)!important;scrollbar-width:thin!important;scrollbar-color:rgba(230,225,245,.45) transparent!important}
.encounter-scene .suggestion-card-title{font-size:11px!important;line-height:1.5!important;white-space:normal!important;overflow-wrap:anywhere!important;margin-bottom:1px!important}
.encounter-scene .suggestion-card-action,.encounter-scene .suggestion-card-dialogue{display:inline!important;font-size:12px!important;line-height:1.65!important;white-space:normal!important;overflow:visible!important;-webkit-line-clamp:unset!important;-webkit-box-orient:initial!important;overflow-wrap:anywhere!important;color:#f5f0fa!important}
.encounter-scene .suggestion-card-dialogue{margin-left:3px!important}
.encounter-scene .suggestion-card.active{border-color:rgba(205,184,255,.72)!important;background:rgba(143,120,190,.27)!important}
.encounter-scene .composer-input-row{flex:0 0 auto!important;margin-top:4px!important}
.encounter-scene #messageInput{min-height:38px!important;max-height:76px!important;padding:8px 10px!important;border-radius:12px!important;font-size:13px!important;background:rgba(235,236,240,.13)!important;border:1px solid rgba(255,255,255,.23)!important;color:#fff!important;backdrop-filter:blur(16px)!important}
.encounter-scene #messageInput::placeholder{color:#e0d9e7!important}
.encounter-scene .composer-bottom-row{display:flex!important;align-items:center!important;justify-content:space-between!important;gap:8px!important;padding-top:4px!important}
.encounter-scene .composer-icon-button{background:rgba(255,255,255,.1)!important;border:1px solid #ffffff32!important;color:#fff!important}
.encounter-scene .composer-cost{color:#fff!important;background:rgba(255,255,255,.08)!important;border-color:#ffffff30!important}
.encounter-scene .composer-send{border-radius:50%!important;min-width:40px!important;min-height:40px!important}
.encounter-scene .chat-tools{background:rgba(28,29,34,.58)!important;border:1px solid rgba(255,255,255,.15)!important;backdrop-filter:blur(18px)!important}
.encounter-scene .chat-tools button{color:#fff!important}
.encounter-scene .chat-settings-overlay{background:linear-gradient(135deg,rgba(225,227,232,.20),rgba(108,112,122,.22))!important;border:1px solid rgba(255,255,255,.25)!important;box-shadow:0 18px 50px #0005,inset 0 1px #ffffff25!important;backdrop-filter:blur(24px)!important;color:#f7f7fa!important}
.encounter-scene .chat-settings-overlay .profile-setting{background:rgba(35,36,41,.28)!important;border:1px solid rgba(255,255,255,.18)!important;color:#f7f7fa!important}
.encounter-scene .chat-settings-overlay .profile-setting small{color:#d5d6dc!important}
.encounter-scene .encounter-missing-art{position:absolute!important;z-index:1!important;right:16px!important;bottom:var(--poyozz-encounter-composer-height,190px)!important;max-width:45%!important;padding:8px 10px!important;border-radius:12px!important;background:#17141b66!important;color:#ffffffa8!important;font-size:10px!important;pointer-events:none!important}
body.encounter-mode-active .chat-main.encounter-scene .assistant-typing .message-content{display:flex!important;align-items:center!important;gap:8px!important;padding:10px 14px!important;border-radius:13px!important;background:rgba(35,30,43,.52)!important;border:1px solid rgba(255,255,255,.18)!important;color:#fff!important}
body.encounter-mode-active .chat-main.encounter-scene .typing-dots i{animation:encounterTypingPulse 1.15s infinite ease-in-out!important}
body.encounter-mode-active .chat-main.encounter-scene .typing-dots i:nth-child(2){animation-delay:.16s!important}
body.encounter-mode-active .chat-main.encounter-scene .typing-dots i:nth-child(3){animation-delay:.32s!important}
@keyframes encounterTypingPulse{0%,80%,100%{opacity:.28;transform:translateY(0)}40%{opacity:1;transform:translateY(-3px)}}
@media(max-width:767px){.encounter-scene .chat-heading{padding-top:calc(8px + env(safe-area-inset-top))!important}.encounter-character-sprite{width:min(108%,680px)!important;height:78lvh!important}.encounter-scene .composer{max-height:calc(var(--poyozz-chat-viewport-height,100dvh) - 60px)!important}.encounter-scene .messages{padding:8px 14px!important}}

/* Consolidated final Encounter polish. */
body.encounter-mode-active .chat-main.encounter-scene:before{background-image:linear-gradient(180deg,rgba(10,9,17,.08),rgba(10,9,17,.06) 42%,rgba(10,9,17,.20) 72%,rgba(10,9,17,.30) 100%),var(--encounter-scene-photo,none),radial-gradient(ellipse at 70% 22%,#6a5a65 0%,#322b36 48%,#17141b 100%)!important}
body.encounter-mode-active .chat-main.encounter-scene .chat-heading{background:linear-gradient(110deg,rgba(25,22,35,.30),rgba(45,38,55,.18) 52%,rgba(25,22,35,.10))!important;border-color:rgba(255,255,255,.12)!important;box-shadow:0 8px 28px rgba(8,6,14,.08)!important;backdrop-filter:blur(12px)!important}
body.encounter-mode-active .chat-main.encounter-scene .chat-heading .row.grow{max-width:calc(100% - 12px)!important;gap:8px!important}
body.encounter-mode-active .chat-main.encounter-scene .encounter-dialogue-beat{position:relative;z-index:2;width:min(100%,760px)!important;margin:0 auto!important;gap:9px!important;padding:17px 19px 12px!important;color:rgba(255,250,247,.96)!important;background:linear-gradient(135deg,rgba(35,29,43,.54),rgba(61,48,66,.43) 48%,rgba(31,28,42,.48))!important;border-color:rgba(255,237,242,.22)!important;box-shadow:0 10px 32px rgba(10,7,16,.12),inset 0 1px rgba(255,255,255,.10)!important;backdrop-filter:blur(15px)!important}
body.encounter-mode-active .chat-main.encounter-scene .encounter-speaker-label{align-self:flex-start!important;display:inline-flex!important;max-width:72%!important;padding:4px 12px!important;margin:0 0 1px!important;border-radius:5px 11px 11px 5px!important;font-size:12px!important;font-weight:650!important;letter-spacing:.08em!important;color:rgba(255,239,224,.98)!important;background:linear-gradient(100deg,rgba(205,164,177,.32),rgba(167,150,196,.20) 60%,rgba(255,255,255,.08))!important;border-left:2px solid rgba(244,204,218,.72)!important;box-shadow:inset 0 1px rgba(255,255,255,.12)!important}
body.encounter-mode-active .chat-main.encounter-scene .encounter-dialogue-text{font-size:15px!important;line-height:1.9!important;font-weight:450!important;text-shadow:0 1px 8px rgba(0,0,0,.16)!important}
body.encounter-mode-active .chat-main.encounter-scene .encounter-dialogue-hint{align-self:flex-end!important;padding:3px 8px!important;border-radius:999px!important;color:rgba(255,255,255,.58)!important;background:rgba(255,255,255,.045)!important;font-size:10px!important}
body.encounter-mode-active .chat-main.encounter-scene .suggestions-panel,body.encounter-mode-active .chat-main.encounter-scene .suggestion-cards,body.encounter-mode-active .chat-main.encounter-scene .suggestions-panel .suggestion-card,body.encounter-mode-active .chat-main.encounter-scene .suggestions-panel .suggestion-card.active{background:linear-gradient(135deg,rgba(38,32,47,.30),rgba(72,57,77,.22) 52%,rgba(36,31,46,.26))!important;border-color:rgba(255,255,255,.13)!important;box-shadow:0 6px 22px rgba(8,6,14,.07),inset 0 1px rgba(255,255,255,.07)!important;backdrop-filter:blur(13px)!important}
body.encounter-mode-active .chat-main.encounter-scene .suggestion-card-action,body.encounter-mode-active .chat-main.encounter-scene .suggestion-card-dialogue{background:transparent!important}
body.encounter-mode-active .chat-main.encounter-scene .composer{background:linear-gradient(180deg,rgba(24,20,31,.015),rgba(36,29,43,.13) 42%,rgba(26,22,34,.30))!important}
body.encounter-mode-active .chat-main.encounter-scene .messages .message>img.avatar,body.encounter-mode-active .chat-main.encounter-scene .messages .message .avatar,body.encounter-mode-active .chat-main.encounter-scene .messages .roleplay-segments .avatar{display:none!important}
body.encounter-mode-active .chat-main.encounter-scene .encounter-dialogue-empty{display:none!important}
@media(max-width:767px){body.encounter-mode-active .chat-main.encounter-scene .messages .encounter-dialogue-beat{padding:14px 15px 10px!important;gap:7px!important}body.encounter-mode-active .chat-main.encounter-scene .encounter-dialogue-text{font-size:14px!important;line-height:1.85!important}body.encounter-mode-active .chat-main.encounter-scene .encounter-speaker-label{font-size:11px!important;padding:4px 10px!important}}
/* Final full-bleed chat frame: remove the outer panel inset and let header/composer glass meet the phone edges. */
body.chat-page .chat-main,body.conversation .chat-main,body.group-chat-page .chat-main{box-sizing:border-box;width:100%;max-width:none;height:100%;min-height:0;margin:0;padding:0;border:0!important;border-radius:0!important;box-shadow:none!important;}
body.chat-page .chat-heading,body.conversation .chat-heading,body.group-chat-page .chat-heading{box-sizing:border-box;width:100%;margin:0;border-left:0!important;border-right:0!important;border-top:0!important;border-radius:0!important;}
body.chat-page .composer,body.conversation .composer,body.group-chat-page .composer{box-sizing:border-box;width:100%;margin:0;border-left:0!important;border-right:0!important;border-bottom:0!important;border-radius:0!important;}
body.chat-page .messages,body.conversation .messages,body.group-chat-page .messages{width:100%;max-width:none;}
`;
;
  style.textContent += `
/* Unified header: full identity row; affinity directly below name, Encounter control row uses fixed chip sizing. */
.encounter-scene .chat-heading>.row.between{align-items:flex-start!important;flex-wrap:wrap!important;gap:5px!important}
.encounter-scene .chat-heading>.row.between>.row.grow{width:100%!important;max-width:100%!important;min-width:0!important;flex-wrap:nowrap!important;gap:7px!important}
.encounter-scene .chat-heading .chat-name{max-width:none!important}
.encounter-scene .chat-heading .encounter-affinity-chip{width:calc(4em + 28px)!important;min-width:calc(4em + 28px)!important;max-width:calc(4em + 28px)!important;justify-content:center!important;gap:4px!important;font-size:10px!important;line-height:1.15!important}
.encounter-scene .chat-heading .encounter-affinity-chip .poyozz-affinity-label{width:4em!important;min-width:4em!important;text-align:center!important}
.encounter-scene .chat-heading .encounter-scene-label{width:calc(4em + 28px)!important;min-width:calc(4em + 28px)!important;max-width:calc(4em + 28px)!important;justify-content:center!important;font-size:10px!important;line-height:1.15!important;padding:3px 4px!important;box-sizing:border-box!important}
.encounter-scene .chat-heading .row:not(.grow){align-items:center!important}
.encounter-scene .chat-heading [data-action="chat-settings-menu"],.encounter-scene .chat-heading [data-action="chat-settings-menu"] .icon{display:inline-flex!important;visibility:visible!important;opacity:1!important}
.encounter-scene .chat-heading>.row.between>.row:last-child{width:100%!important;justify-content:flex-end!important;gap:3px!important}
.encounter-scene .chat-heading .chat-name{min-width:0!important;max-width:none!important;flex:0 0 auto!important;white-space:normal!important;overflow:visible!important;text-overflow:clip!important}
.encounter-scene .chat-heading .encounter-identity-stack{display:flex!important;flex-direction:column!important;align-items:flex-start!important;gap:3px!important;min-width:0!important;flex:1 1 auto!important}
.encounter-scene .chat-heading .encounter-affinity-chip{max-width:none!important}
.encounter-scene .chat-heading .encounter-mode-icon,.encounter-scene .chat-heading [data-encounter-mode-icon]{flex:0 0 auto!important}
.encounter-scene .composer .composer-bottom-row{display:flex!important;align-items:center!important;justify-content:space-between!important;gap:8px!important}
.encounter-scene .composer .composer-bottom-left{display:flex!important;align-items:center!important;gap:6px!important}
.encounter-scene .composer .composer-icon-button,.encounter-scene .composer [data-action="send-message"],.encounter-scene .composer [type="submit"]{display:inline-flex!important;visibility:visible!important;opacity:1!important;flex:0 0 auto!important}
.encounter-scene .composer .composer-input-row{display:flex!important;align-items:flex-end!important}
.encounter-scene .composer #messageInput{min-height:42px!important;max-height:24dvh!important}
body.encounter-mode-active.chat-keyboard-open .encounter-character-sprite{height:78lvh!important;max-height:none!important;bottom:calc(100lvh - var(--poyozz-chat-viewport-height,100dvh))!important;object-position:center bottom!important}
body.encounter-mode-active.chat-keyboard-open .encounter-scene .composer{bottom:calc(100lvh - var(--poyozz-chat-viewport-height,100dvh))!important;max-height:var(--poyozz-chat-viewport-height,100dvh)!important;overflow:visible!important}
body.encounter-mode-active .encounter-scene .composer-bottom-row{position:sticky!important;bottom:0!important;z-index:12!important;min-height:46px!important;padding:6px 0 calc(4px + env(safe-area-inset-bottom))!important;margin-top:4px!important;background:linear-gradient(180deg,rgba(28,25,34,.20),rgba(28,25,34,.72))!important;overflow:visible!important}
body.encounter-mode-active .encounter-scene .composer-bottom-left,body.encounter-mode-active .encounter-scene .composer-bottom-right{overflow:visible!important}
body.encounter-mode-active .encounter-scene .composer-bottom-row .composer-icon-button,body.encounter-mode-active .encounter-scene .composer-bottom-row .composer-send{position:relative!important;z-index:13!important;visibility:visible!important;opacity:1!important;display:inline-flex!important}
body.encounter-mode-active .encounter-scene .composer-bottom-row .composer-icon-button{width:36px!important;height:36px!important;min-width:36px!important;min-height:36px!important}
body.encounter-mode-active .encounter-scene .composer-bottom-row .composer-send{width:42px!important;height:42px!important;min-width:42px!important;min-height:42px!important}
body.encounter-mode-active.chat-keyboard-open .encounter-scene .messages{bottom:calc(var(--poyozz-encounter-composer-height,190px) + 100lvh - var(--poyozz-chat-viewport-height,100dvh))!important;max-height:calc(var(--poyozz-chat-viewport-height,100dvh) - var(--poyozz-encounter-composer-height,190px) - 65px)!important}
`;

  style.textContent += `
/* Preview acceptance fixes: keep the header controls on the top-right, widen four-character labels,
   keep the sprite anchored to the scene when the keyboard opens, and lift the composer controls. */
body.encounter-mode-active .chat-main.encounter-scene .chat-heading>.row.between{
  position:relative!important;display:flex!important;align-items:flex-start!important;flex-wrap:nowrap!important;gap:6px!important;
}
body.encounter-mode-active .chat-main.encounter-scene .chat-heading>.row.between>.row.grow{
  width:100%!important;max-width:100%!important;min-width:0!important;padding-right:154px!important;flex-wrap:nowrap!important;
}
body.encounter-mode-active .chat-main.encounter-scene .chat-heading>.row.between>.row:last-child{
  position:absolute!important;top:0!important;right:0!important;left:auto!important;width:auto!important;
  display:flex!important;align-items:center!important;justify-content:flex-end!important;flex-wrap:nowrap!important;
  gap:5px!important;margin:0!important;z-index:6!important;
}
body.encounter-mode-active .chat-main.encounter-scene .chat-heading .encounter-affinity-chip{
  width:calc(5.5em + 30px)!important;min-width:calc(5.5em + 30px)!important;max-width:calc(5.5em + 30px)!important;
  justify-content:center!important;gap:4px!important;
}
body.encounter-mode-active .chat-main.encounter-scene .chat-heading .encounter-affinity-chip .poyozz-affinity-ui{
  width:calc(5.5em + 30px)!important;min-width:calc(5.5em + 30px)!important;max-width:calc(5.5em + 30px)!important;
  padding:3px 5px!important;box-sizing:border-box!important;
}
body.encounter-mode-active .chat-main.encounter-scene .chat-heading .encounter-affinity-chip .poyozz-affinity-label{
  width:5.5em!important;min-width:5.5em!important;text-align:center!important;white-space:nowrap!important;
}
body.encounter-mode-active .chat-main.encounter-scene .chat-heading .encounter-scene-label{
  width:calc(5.5em + 30px)!important;min-width:calc(5.5em + 30px)!important;max-width:calc(5.5em + 30px)!important;
  box-sizing:border-box!important;justify-content:center!important;white-space:nowrap!important;
}
body.encounter-mode-active .chat-main.encounter-scene .chat-heading .encounter-mode-icon,
body.encounter-mode-active .chat-main.encounter-scene .chat-heading [data-encounter-mode-icon]{
  flex:0 0 auto!important;
}
body.encounter-mode-active .chat-main.encounter-scene .encounter-character-sprite,
body.encounter-mode-active.chat-keyboard-open .chat-main.encounter-scene .encounter-character-sprite{
  position:absolute!important;bottom:0!important;left:50%!important;right:auto!important;transform:translateX(-50%)!important;top:auto!important;
}
body.encounter-mode-active .chat-main.encounter-scene .composer{padding-bottom:calc(15px + env(safe-area-inset-bottom))!important}
body.encounter-mode-active .chat-main.encounter-scene .composer-bottom-row{
  transform:translateY(-6px)!important;margin-bottom:2px!important;
}
@media(max-width:420px){
  body.encounter-mode-active .chat-main.encounter-scene .chat-heading>.row.between>.row.grow{padding-right:148px!important}
  body.encounter-mode-active .chat-main.encounter-scene .chat-heading .encounter-scene-label,
  body.encounter-mode-active .chat-main.encounter-scene .chat-heading .encounter-affinity-chip{
    width:calc(5em + 28px)!important;min-width:calc(5em + 28px)!important;max-width:calc(5em + 28px)!important;
  }
  body.encounter-mode-active .chat-main.encounter-scene .chat-heading .encounter-affinity-chip .poyozz-affinity-label{
    width:5em!important;min-width:5em!important;
  }
}
`;
  document.head.appendChild(style);
  const splitEncounterBeats=(value)=>{
    const source=String(value||'').replace(/\r\n?/g,'\n').replace(/[ \t]+\n/g,'\n').trim();
    if(!source)return [];
    const paragraphs=source.split(/\n+/).map(x=>x.trim()).filter(Boolean);
    const beats=[];
    const pushSentence=(text)=>{
      const cleaned=String(text||'').replace(/^\s*[-•]+\s*/,'').trim();
      if(!cleaned)return;
      // Long, unpunctuated prose is broken into readable visual-novel beats too.
      if(cleaned.length>58&&!cleaned.includes('*')){
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
      const sentences=paragraph.match(/(?:\*(?!\*)[^*]*\*(?!\*)|[^。！？!?；;])+(?:[。！？!?；;」』”’"）)】]*)?/gu)||[paragraph];
      for(const sentence of sentences){
        const part=sentence.trim();
        if(part)pushSentence(part);
      }
    }
    return beats;
  };
  const encounterBeatMarkup=(value)=>{
    const parts=String(value||'').split(/(\*(?!\*)[^*]+?\*(?!\*))/gu).filter(Boolean);
    const hasSpeech=parts.some(part=>!(part.startsWith('*')&&!part.startsWith('**')&&part.endsWith('*')&&!part.endsWith('**'))&&part.trim());
    const html=parts.map(part=>part.startsWith('*')&&!part.startsWith('**')&&part.endsWith('*')&&!part.endsWith('**')&&part.length>=2?' <em>'+e(part.slice(1,-1))+'</em> ':e(part)).join('');
    return {html,hasSpeech};
  };
  const encounterTypingMarkup=(name)=>'<div class="encounter-typing-indicator" role="status" aria-live="polite"><span>'+e(name)+' 正在回覆...</span><span class="typing-dots" aria-hidden="true"><i></i><i></i><i></i></span></div>';
  // Re-apply the visual-novel beat after BOTH full conversation renders and message-only renders.
  // The base chat renderer can replace #messages after renderConversation finishes; this hook prevents it
  // from restoring ordinary chat bubbles and silently cancelling progressive dialogue.
  const applyEncounterDialogue=(panel,session)=>{
    const messages=panel?.querySelector('.messages');
    if(!messages)return;
    const allMessages=Array.isArray(session?.messages)?session.messages:[];
    const openingText=String(session?.initialOpeningMessage?.text||'').trim();
    const latestReply=[...allMessages].reverse().find(m=>m&&m.role==='assistant'&&String(m.text??m.content??'').trim())||
      (openingText?{id:'opening-'+session.id,content:openingText}:null);
    const raw=String(latestReply?.text??latestReply?.content??'').trim();
    const hasStarted=!!raw;
    let latestUserIndex=-1,latestAssistantIndex=-1;
    for(let i=0;i<allMessages.length;i++){
      const message=allMessages[i];
      if(message?.role==='user')latestUserIndex=i;
      if(message?.role==='assistant'&&String(message.text??message.content??'').trim())latestAssistantIndex=i;
    }
    const hasAnyPlayerTurn=latestUserIndex>=0;
    const hasAssistantTurnReply=hasAnyPlayerTurn&&latestAssistantIndex>latestUserIndex;
    const composer=panel.querySelector('.composer');
    if(composer){
      const input=composer.querySelector('#messageInput');
      const characterName=String(sessionCharacter(session)?.name||sessionCharacter(session)?.display_name||'角色').trim();
      if(input)input.placeholder=hasAnyPlayerTurn?'留空發送，角色會繼續說下去':'先跟'+characterName+'打招呼，或者留空發送，讓'+characterName+'發現你';
      const suggestions=composer.querySelector('.suggestions');
      if(suggestions)suggestions.hidden=!hasAssistantTurnReply;
    }
    if(!hasStarted){
      messages.innerHTML=session.activeTurnInFlight?encounterTypingMarkup(String(sessionCharacter(session)?.name||'角色')):'';
      messages.classList.remove('encounter-dialogue-ready');
      messages.dataset.encounterBeatKey='opening-input:'+session.id;
      messages.dataset.encounterBeatIndex='0';
      return;
    }
    const beats=raw?splitEncounterBeats(raw):[];
    const beatKey=String(latestReply?.id||latestReply?.createdAt||latestReply?.timestamp||raw.slice(0,48))+':'+raw.length+':'+beats.length;
    if(session.encounterBeatKey!==beatKey){session.encounterBeatKey=beatKey;session.encounterBeatIndex=0;}
    const idx=Math.min(Math.max(0,Number(session.encounterBeatIndex)||0),Math.max(0,beats.length-1));
    const speakerCharacter=sessionCharacter(session);
    const speakerName=String(speakerCharacter?.name||speakerCharacter?.display_name||speakerCharacter?.character_name||'角色').trim();
    const beat=beats[idx]||'';
    const formattedBeat=encounterBeatMarkup(beat);
    const speakerLabel=formattedBeat.hasSpeech?'<span class="encounter-speaker-label">'+e(speakerName)+'</span>':'';
    const replayButton=idx===beats.length-1?'<button type="button" class="encounter-dialogue-replay" data-action="encounter-replay-beat">再看一次</button>':'';
    const dialogueMarkup=beats.length
      ? '<div class="encounter-dialogue-stack"><button type="button" class="encounter-dialogue-beat" data-action="encounter-next-beat" aria-label="點擊繼續劇情">'+speakerLabel+'<span class="encounter-dialogue-text">'+formattedBeat.html+'</span><span class="encounter-dialogue-hint">'+(idx<beats.length-1?'點擊繼續　⌄':'劇情已讀完')+'</span></button>'+replayButton+'</div>'
      : '<div class="encounter-dialogue-empty" aria-hidden="true"></div>';
    messages.innerHTML=dialogueMarkup+(session.activeTurnInFlight&&!hasAssistantTurnReply?encounterTypingMarkup(speakerName):'');
    messages.classList.toggle('encounter-dialogue-ready',beats.length>0);
    if(composer){
      const suggestions=composer.querySelector('.suggestions');
      if(suggestions)suggestions.hidden=!hasAssistantTurnReply||(beats.length>0&&idx<beats.length-1);
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
      const selectedBackgroundPath=safeImage(session?.encounterVisuals?.sceneBackgroundPath||'');
      const sceneImage=safeImage(selectedBackgroundPath||character?.encounterSceneImage||session?.encounterSceneImage||character?.sceneImage||'');
      const defaultSceneImage='./encounter-default-scene.webp';
      panel.style.setProperty('--encounter-scene-photo','url('+JSON.stringify(sceneImage||defaultSceneImage)+')');
      panel.dataset.encounterPlace=session.encounterPlace||'';
      // Encounter scenes use dedicated encounter art or the author's scene-illustration gallery.
      // The character-card primary image is intentionally never reused as a scene sprite.
      const selectedIllustrationId=typeof session?.encounterVisuals?.illustrationId==='string'?session.encounterVisuals.illustrationId:'';
      const selectedGalleryAsset=selectedIllustrationId
        ? (character?.galleryIllustrations||[]).find(asset=>asset?.id===selectedIllustrationId)
        : null;
      const selectedGalleryImage=safeImage(selectedGalleryAsset?.src||'');
      const dedicatedSprite=safeImage(character?.encounterPortraitImage||character?.halfBodyImage||character?.transparentPortrait||character?.encounterSprite||'');
      const sceneIllustration=safeImage(selectedGalleryImage||character?.galleryIllustrations?.[0]?.src||'');
      const halfBodyImage=selectedGalleryImage||dedicatedSprite||sceneIllustration;
      const useGallerySprite=!!selectedGalleryImage||!dedicatedSprite;
      let existingSprite=panel.querySelector('.encounter-character-sprite');
      const missingArt=panel.querySelector('.encounter-missing-art');
      if(halfBodyImage){
        if(missingArt)missingArt.remove();
        if(!existingSprite){
          existingSprite=document.createElement('img');
          existingSprite.className='encounter-character-sprite';
          existingSprite.dataset.encounterCharacterImage='true';
          existingSprite.alt='';
          existingSprite.setAttribute('aria-hidden','true');
          existingSprite.loading='eager';
          panel.insertBefore(existingSprite,panel.firstChild);
        }
        existingSprite.dataset.encounterCharacterImage='true';
        existingSprite.classList.toggle('encounter-card-portrait-fallback',useGallerySprite);
        if(existingSprite.dataset.encounterSource!==halfBodyImage){
          existingSprite.dataset.encounterSource=halfBodyImage;
          existingSprite.dataset.encounterProcessed='';
          existingSprite.classList.remove('encounter-auto-bg-fallback');
          processEncounterSpriteBackdrop(existingSprite,halfBodyImage);
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
          void hydrateEncounterGalleryIllustration(character.id,selectedIllustrationId||null).then(asset=>{
            if(!panel.isConnected||currentSession()?.id!==encounterSessionId)return;
            if(asset?.src){
              if(panel.querySelector('.encounter-character-sprite'))return;
              const sprite=document.createElement('img');
              sprite.className='encounter-character-sprite encounter-card-portrait-fallback';
              sprite.dataset.encounterCharacterImage='true';
              sprite.alt='';
              sprite.setAttribute('aria-hidden','true');
              sprite.loading='eager';
              sprite.dataset.encounterSource=asset.src;
              if(asset.path)sprite.dataset.characterIllustrationPath=asset.path;
              processEncounterSpriteBackdrop(sprite,asset.src);
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
        const identityRow=title.querySelector('.row.grow');
        const controlsRow=title.querySelector('.row.between>.row:last-child');
        if(!tag){
          tag=document.createElement('span');tag.className='encounter-scene-label';tag.textContent='✦ 相遇模式';
          tag.style.cssText='font-size:10px;letter-spacing:.04em;color:#f1f1f4;padding:3px 7px;border-radius:999px;background:rgba(225,226,232,.13);border:1px solid rgba(255,255,255,.18);white-space:nowrap';
        }
        const modeIcon=title.querySelector('.encounter-mode-icon,[data-encounter-mode-icon]');
        const menuButton=controlsRow?.querySelector('[data-action="chat-settings-menu"]');
        if(controlsRow){
          if(modeIcon)controlsRow.insertBefore(modeIcon,menuButton||null);
          controlsRow.insertBefore(tag,menuButton||null);
        }
        let affinityChip=title.querySelector('.encounter-affinity-chip');
        if(!affinityChip){affinityChip=document.createElement('span');affinityChip.className='encounter-affinity-chip';}
        const nameNode=identityRow?.querySelector('.chat-name');
        if(identityRow&&nameNode){
          let stack=identityRow.querySelector('.encounter-identity-stack');
          if(!stack){stack=document.createElement('div');stack.className='encounter-identity-stack';nameNode.before(stack);stack.appendChild(nameNode);}
          if(!stack.contains(affinityChip))stack.appendChild(affinityChip);
        }else if(controlsRow&&!controlsRow.contains(affinityChip)){controlsRow.appendChild(affinityChip);}
        affinityChip.innerHTML=window.PoyozzAffinityUI?.render(session.encounterAffinity,session.encounterRelationshipStage||'stranger','encounter')||'';
        affinityChip.setAttribute('role','status');
        affinityChip.setAttribute('aria-label','目前關係：'+(window.PoyozzAffinityUI?.labels?.[session.encounterRelationshipStage]||'陌生人'));
      }
      const input=panel.querySelector('.composer #messageInput');
      if(input)input.setAttribute('aria-label','相遇模式對話');
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
    const target=event.target.closest('[data-action="encounter-next-beat"],[data-action="encounter-replay-beat"]');
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
    if(target.dataset.action==='encounter-replay-beat')session.encounterBeatIndex=0;
    else if((session.encounterBeatIndex||0)<beats.length-1)session.encounterBeatIndex=(session.encounterBeatIndex||0)+1;
    else return;
    persist();renderConversation();
  });


})();
