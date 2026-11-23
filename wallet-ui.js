/* Wallet-cost UI: compact currency deductions and a single-chat insufficient-balance choice. */
function walletCostPreviewHTML(cost) {
  const user=currentUser()||{};
  const silver=Math.max(0,Number(user.silver||0));
  const diamonds=Math.max(0,Number(user.diamonds||0));
  const price=Math.max(0,Number(cost||0));
  const fromSilver=Math.min(silver,price);
  const fromDiamonds=Math.max(0,price-fromSilver);
  const parts=[];
  if(fromSilver>0) parts.push('<span class="wallet-cost-part" aria-label="銀幣扣除 '+fromSilver+'">🪙 −'+fromSilver+'</span>');
  if(fromDiamonds>0) parts.push('<span class="wallet-cost-part" aria-label="鑽石扣除 '+fromDiamonds+'">💎 −'+fromDiamonds+'</span>');
  if(!parts.length) parts.push('<span class="wallet-cost-part">🪙 −'+price+'</span>');
  return parts.join('<span class="wallet-cost-plus" aria-hidden="true"> </span>');
}
let walletDiamondConsentOnce = '';
function walletCostFor(mode) {
  return mode==='group' ? Math.max(1,(groupPrototype.active?.members||[]).length)*3 : 2;
}
function walletChoiceStorageKey(mode) {
  return 'personax-wallet-choice:'+String(currentUser()?.uid||'guest')+':'+mode;
}
function getTodayWalletChoice(mode) {
  try {
    const saved=JSON.parse(localStorage.getItem(walletChoiceStorageKey(mode))||'null');
    if(!saved||saved.expiresAt<=Date.now()||!['diamonds','ad'].includes(saved.choice)) {
      localStorage.removeItem(walletChoiceStorageKey(mode));
      return '';
    }
    return saved.choice;
  } catch (_) { return ''; }
}
function saveTodayWalletChoice(mode,choice) {
  const now=new Date();
  const expiresAt=new Date(now.getFullYear(),now.getMonth(),now.getDate()+1).getTime()-1;
  try { localStorage.setItem(walletChoiceStorageKey(mode),JSON.stringify({choice,expiresAt})); } catch (_) {}
}
function walletPreflight(mode) {
  const user=currentUser()||{};
  const silver=Math.max(0,Number(user.silver||0));
  const diamonds=Math.max(0,Number(user.diamonds||0));
  const cost=walletCostFor(mode);
  if(silver>=cost) return true;
  const neededDiamonds=Math.max(0,cost-silver);
  if(walletDiamondConsentOnce===mode && diamonds>=neededDiamonds) {
    walletDiamondConsentOnce='';
    return true;
  }
  walletDiamondConsentOnce='';
  const remembered=getTodayWalletChoice(mode);
  if(remembered==='diamonds' && diamonds>=neededDiamonds) return true;
  if(remembered==='ad' && mode==='single') {
    showWalletAdUnavailable();
    return false;
  }
  openInsufficientFundsDialog(mode);
  return false;
}
function showWalletAdUnavailable() {
  showDialog('廣告功能尚未串接','<p>目前尚未接入廣告播放器及後端完整播放驗證，因此不會發放銀幣，也不會放行對話。接入廣告服務後，才會在確認完整播放與後端廣告回饋成功後繼續對話。</p>');
}
function openInsufficientFundsDialog(mode) {
  const user=currentUser()||{};
  const silver=Math.max(0,Number(user.silver||0));
  const diamonds=Math.max(0,Number(user.diamonds||0));
  const cost=walletCostFor(mode);
  const fromSilver=Math.min(silver,cost);
  const fromDiamonds=Math.max(0,cost-fromSilver);
  const enoughTotal=silver+diamonds>=cost;
  const remembered=getTodayWalletChoice(mode);
  const remember=remembered==='diamonds' || (mode==='single' && remembered==='ad');
  const chargePreview=(fromSilver>0?'<span>🪙 −'+fromSilver+' <small>(持有 '+silver+')</small></span>':'')+
    (fromDiamonds>0?'<span>💎 −'+fromDiamonds+' <small>(持有 '+diamonds+')</small></span>':'');
  const adOption=mode==='single'
    ? '<button type="button" class="primary" data-action="wallet-watch-ad">看廣告繼續聊</button>'
    : '';
  const diamondOption=enoughTotal
    ? '<button type="button" class="primary" data-action="wallet-confirm-diamonds" data-mode="'+mode+'">使用鑽石</button>'
    : '<button type="button" class="primary" data-action="wallet-open-shop">鑽石不足，前往商店</button>';
  const rememberOption=mode==='single'
    ? '<label class="wallet-remember-choice"><input type="checkbox" id="walletRememberChoice" '+(remember?'checked':'')+'> <span>今天都使用這個選擇，不要再提醒我</span></label>'
    : '<label class="wallet-remember-choice"><input type="checkbox" id="walletRememberChoice" '+(remembered==='diamonds'?'checked':'')+'> <span>今天都使用這個選擇，不要再提醒我</span></label>';
  const body='你的銀幣或鑽石不足，繼續對話將花費以下：';
  showDialog('銀幣或鑽石不足',`
    <p>${body}</p>
    <div class="wallet-modal-cost" aria-label="預計扣款">${chargePreview||'💎 −'+cost+' <small>(持有 '+diamonds+')</small>'}</div>
    ${mode==='single'?'<p>你也可以選擇觀看廣告，繼續對話。</p>':''}
    <div class="wallet-modal-actions">${adOption}${diamondOption}</div>
    ${rememberOption}
  `);
}
document.addEventListener('click',async event=>{
  const nsfwButton=event.target.closest('[data-action="nsfw-focus"],[data-action="dialog-close"]');
  if(nsfwButton?.dataset.action==='nsfw-focus'){$('modal')?.close();focusNsfwCheckbox();return;}
  if(nsfwButton?.dataset.action==='dialog-close'){$('modal')?.close();return;}
  const button=event.target.closest('[data-action="wallet-dialog-close"],[data-action="wallet-cost-details"],[data-action="wallet-confirm-diamonds"],[data-action="wallet-watch-ad"],[data-action="wallet-open-shop"]');
  if(!button)return;
  if(button.dataset.action==='wallet-dialog-close') {
    $('modal')?.close();
    return;
  }
  if(button.dataset.action==='wallet-cost-details') {
    const u=currentUser()||{};
    const silver=Math.max(0,Number(u.silver||0)),diamonds=Math.max(0,Number(u.diamonds||0));
    const cost=route.page==='group'?Math.max(1,(groupPrototype.active?.members||[]).length)*3:2;
    showDialog('我的資源',`
      <div class="wallet-resource-row"><span>🪙 銀幣</span><strong>持有 ${silver.toLocaleString()}</strong></div>
      <div class="wallet-resource-row"><span>💎 鑽石</span><strong>持有 ${diamonds.toLocaleString()}</strong></div>
      <p class="small muted">本次預計扣除：${walletCostPreviewHTML(cost)}</p>
    `);
    return;
  }
  if(button.dataset.action==='wallet-open-shop') {
    const modal=$('modal'); if(modal?.open) modal.close();
    go({page:'shop'});
    return;
  }
  if(button.dataset.action==='wallet-watch-ad') {
    if($('walletRememberChoice')?.checked) saveTodayWalletChoice('single','ad');
    showWalletAdUnavailable();
    return;
  }
  if(button.dataset.action==='wallet-confirm-diamonds') {
    const mode=button.dataset.mode || (route.page==='group'?'group':'single');
    if($('walletRememberChoice')?.checked) saveTodayWalletChoice(mode,'diamonds');
    walletDiamondConsentOnce=mode;
    const modal=$('modal'); if(modal?.open) modal.close();
    // Explicit player consent: only now retry the intended send action.
    if(mode==='group') await groupSendTurn();
    else {
      const form=$('view').querySelector('form[data-form="message"]');
      if(form) form.requestSubmit();
    }
  }
});
