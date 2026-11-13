/* POYOZZ custom character-tag picker module.
 * This module owns only picker presentation and delegated local UI events.
 * Tag persistence and character-form submission remain app-owned.
 */
(function (global) {
  'use strict';

  let bound = false;

  function render(dependencies) {
    const { $, e, validCharacterTag } = dependencies;
    
      const modal=$('modal');
      const input=modal?.querySelector('input[name="tagSearch"]');
      const options=modal?.querySelector('#customTagList');
      const results=modal?.querySelector('#customTagResults');
      const selectedArea=modal?.querySelector('#customTagSelected');
      const count=modal?.querySelector('#customTagCount');
      if(!input||!options||!results||!selectedArea||!count)return;
      const query=String(input.value||'').trim().toLocaleLowerCase('zh-Hant');
      const checkboxes=[...options.querySelectorAll('input[name="tag"]')];
      const matches=checkboxes.filter(item=>!query||item.value.toLocaleLowerCase('zh-Hant').includes(query));
      results.innerHTML=matches.map(item=>`<button type="button" class="tag-picker-chip ${item.checked?'selected':''}" data-action="toggle-custom-tag" data-tag="${e(item.value)}" aria-pressed="${item.checked}">${e(item.value)}${item.checked?' ✓':''}</button>`).join('');
      if(!matches.length && !query) {
        results.innerHTML='<p class="small muted">尚無可用標籤，輸入至少2字即可新增。</p>';
      } else if(!matches.length) {
        results.innerHTML='<p class="small muted">沒有符合的標籤，可新增這個標籤。</p>';
      }
      const chosen=checkboxes.filter(item=>item.checked);
      count.textContent='['+chosen.length+'/5]';
      selectedArea.innerHTML=chosen.map(item=>`<button type="button" class="tag-picker-chip selected" data-action="toggle-custom-tag" data-tag="${e(item.value)}" aria-label="取消選擇 ${e(item.value)}">${e(item.value)} ×</button>`).join('') || '<span class="small muted">尚未選擇標籤</span>';
      const addButton=modal.querySelector('[data-action="add-custom-tag"]');
      if(addButton) {
        addButton.hidden=!(validCharacterTag(input.value)&&matches.length===0);
        addButton.textContent='新增';
        addButton.setAttribute('aria-label','新增標籤 '+String(input.value||'').trim());
      }
  }

  function bind(dependencies) {
    if (bound) return;
    bound = true;
    const { $, toast } = dependencies;
    document.addEventListener('input', event => {
      const input=event.target;
      if(input instanceof HTMLInputElement && input.name==='tagSearch' && input.closest('.tag-picker')) render(dependencies);
    });
    document.addEventListener('click', event => {
      const button=event.target.closest('[data-action="toggle-custom-tag"]');
      if(!button)return;
      const options=$('modal')?.querySelector('#customTagList');
      const input=options&&[...options.querySelectorAll('input[name="tag"]')].find(item=>item.value===button.dataset.tag);
      if(!input)return;
      const checked=[...options.querySelectorAll('input[name="tag"]:checked')];
      if(!input.checked&&checked.length>=5){toast('角色最多選擇5個標籤。');return;}
      input.checked=!input.checked;
      render(dependencies);
    });
    document.addEventListener('change', event => {
      const input=event.target;
      if(!(input instanceof HTMLInputElement)||input.name!=='tag'||!input.closest('#customTagList'))return;
      const checked=[...document.querySelectorAll('#customTagList input[name="tag"]:checked')];
      if(checked.length>5){input.checked=false;toast('角色最多選擇5個標籤。');}
      render(dependencies);
    });
  }

  global.PoyozzCustomTagPicker = Object.freeze({ render, bind });
})(window);
