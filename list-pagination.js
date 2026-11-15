(()=>{const PAGE_SIZES=Object.freeze({explore:20,authorCharacters:10,chatSessions:10,groupSessions:10,followedAuthors:10,encounterMemories:10,messages:5,citySceneCharacters:10,chatSearch:10,groupCharacterPicker:10,ownedCharacters:10,favorites:10,notifications:10,characterComments:10,memoryPhotos:10}),states=new Set(),observers=new Set();let scope='';
function createState(kind, initial = {}){let version=0;const s={kind,pageSize:PAGE_SIZES[kind]||10,offset:0,hasMore:true,loading:false,observer:null,...initial,
beginRequest(){states.add(s);s.loading=true;return ++version},
isRequestCurrent(id){return version===id},
invalidate(){++version;s.loading=false;s.observer?.disconnect();s.observer=null},
dispose(){s.invalidate();states.delete(s)}};return s}
function findScrollRoot(node){
  for(let parent=node?.parentElement;parent&&parent!==document.body;parent=parent.parentElement){
    const style=window.getComputedStyle?.(parent);
    if(style&&/(auto|scroll|overlay)/.test(style.overflowY)&&parent.scrollHeight>parent.clientHeight+1)return parent;
  }
  return null;
}
function observeEnd(node,callback,options={}){
  if(!node||typeof IntersectionObserver==='undefined')return null;
  const root=Object.prototype.hasOwnProperty.call(options,'root')?options.root:findScrollRoot(node);
  const o=new IntersectionObserver(entries=>{if(entries.some(e=>e.isIntersecting))callback()},{root,rootMargin:options.rootMargin||'220px 0px',threshold:0}),disconnect=o.disconnect.bind(o);
  o.disconnect=()=>{disconnect();observers.delete(o)};
  observers.add(o);o.observe(node);return o;
}
function beginScope(value){value=String(value||'');if(value===scope)return false;scope=value;observers.forEach(o=>o.disconnect());observers.clear();states.forEach(s=>s.invalidate());states.clear();return true}
function mergeUnique(existing,incoming,keyOf=item=>item?.id){const seen=new Set((existing||[]).map(keyOf));return [...(existing||[]),...(incoming||[]).filter(item=>{const key=keyOf(item);if(key==null||seen.has(key))return false;seen.add(key);return true})]}
window.PoyozzListPagination=Object.freeze({pageSize:kind=>PAGE_SIZES[kind]||10,createState,observeEnd,beginScope,mergeUnique});
})();