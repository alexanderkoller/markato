const root=document.getElementById('preview'),nodes=new Map();
let revision=0,measurement=0,scheduled=false,assetBase=null,orderedNodes=[];
const groups=new Map(),fanout=32;
function geometry(){
  // The native clip owns vertical scrolling. Browser selection restoration and
  // scroll anchoring must not introduce a second origin inside the web view.
  if(window.scrollX||window.scrollY)window.scrollTo(0,0);
  const frame=root.getBoundingClientRect(),origin=frame.top;
  return {revision,measurement:++measurement,width:frame.width,height:root.offsetHeight,items:orderedNodes.map(n=>{
    const box=n.getBoundingClientRect();
    const reference=n._reference;
    return {id:n.dataset.id,y:box.top-origin,height:box.height,
      landmarkY:reference?reference.getBoundingClientRect().top-origin:null};
  })};
}
function report(){scheduled=false;window.webkit.messageHandlers.geometry.postMessage(geometry());}
function changed(){if(!scheduled){scheduled=true;requestAnimationFrame(report);}}
function fill(n,item,base){
  n._from=Number(item.from);n._to=Number(item.to);
  if(item.html!==undefined && n._html!==item.html){
    const template=document.createElement('template');template.innerHTML=item.html;
    for(const image of template.content.querySelectorAll('img[src]')){
      const url=new URL(image.src);
      if(url.protocol==='astra-asset:'){url.searchParams.set('base',base);image.src=url.href;}
    }
    n.replaceChildren(template.content);n._html=item.html;n._reference=null;
    for(const child of n.children){
      if(/^H[1-6]$/.test(child.tagName)){n._reference=child;break;}
      if(child.tagName==='P' && child.children.length===1 &&
         child.firstElementChild.tagName==='IMG' && !child.textContent.trim()){
        n._reference=child.firstElementChild;break;
      }
    }
    return true;
  }
  return false;
}
window.astraPatch=(items,version,points,base,suffixIndex,shift,debugMeasure=false)=>{
  // BEGIN DEBUG
  const started=debugMeasure?performance.now():0;let changedHTML=0;
  // END DEBUG
  revision=version;document.documentElement.style.fontSize=points+'px';
  for(const item of items){
    const old=orderedNodes[item.index];
    let n=old;
    if(!old || old.dataset.id!==item.id){
      n=document.createElement('section');n.dataset.id=item.id;
      if(old){old.replaceWith(n);nodes.delete(old.dataset.id);}
      nodes.set(item.id,n);orderedNodes[item.index]=n;
    }
    const changedBlock=fill(n,item,base);
    // BEGIN DEBUG
    if(changedBlock)changedHTML++;
    // END DEBUG
  }
  if(shift)for(let i=suffixIndex;i<orderedNodes.length;i++){
    orderedNodes[i]._from+=shift;orderedNodes[i]._to+=shift;
  }
  if(root._lastBlock!==orderedNodes.at(-1)){
    root._lastBlock?.classList.remove('last-block');
    root._lastBlock=orderedNodes.at(-1);root._lastBlock?.classList.add('last-block');
  }
  // BEGIN DEBUG
  if(debugMeasure)return {timing:{patchMs:performance.now()-started,changedHTML,mounted:orderedNodes.length}};
  // END DEBUG
};
window.astraUpdate=(items,version,points,base="",measure=false)=>{
  // BEGIN DEBUG
  const started=measure?performance.now():0;let changedHTML=0;
  // END DEBUG
  revision=version;document.documentElement.style.fontSize=points+'px';
  if(assetBase!==base){root.replaceChildren();nodes.clear();groups.clear();assetBase=base;}
  const retained=new Set(items.map(x=>x.id));
  for(const [id,n] of nodes)if(!retained.has(id)){n.remove();nodes.delete(id);}
  const ordered=[];
  for(const item of items){
    let n=nodes.get(item.id);
    if(!n){n=document.createElement('section');n.dataset.id=item.id;nodes.set(item.id,n);}
    // Source offsets are metadata, not CSS attributes. An insertion shifts
    // every following block; mutating HTML attributes invalidates its style.
    const changedBlock=fill(n,item,base);
    // BEGIN DEBUG
    if(changedBlock)changedHTML++;
    // END DEBUG
    ordered.push(n);
  }
  orderedNodes=ordered;
  // The native view spans the complete document. A flat block list makes
  // each paint tile traverse every sibling. Bound the fanout and contain
  // paint so a tile can reject whole distant branches.
  const used=new Set();
  function arrange(parent,children){
    let previous=null;
    for(const child of children){
      const next=previous?previous.nextSibling:parent.firstChild;
      if(next!==child)parent.insertBefore(child,next);
      previous=child;
    }
    for(let extra=previous?previous.nextSibling:parent.firstChild;extra;){
      const next=extra.nextSibling;extra.remove();extra=next;
    }
  }
  let level=ordered,depth=0;
  while(level.length>fanout){
    const parents=[];
    for(let start=0;start<level.length;start+=fanout){
      const key=depth+':'+start/fanout;used.add(key);
      let group=groups.get(key);
      if(!group){group=document.createElement('div');group.className='paint-group';groups.set(key,group);}
      arrange(group,level.slice(start,start+fanout));parents.push(group);
    }
    level=parents;depth++;
  }
  arrange(root,level);
  for(const [key,group] of groups)if(!used.has(key)){group.remove();groups.delete(key);}
  if(root._lastBlock!==ordered.at(-1)){
    root._lastBlock?.classList.remove('last-block');
    root._lastBlock=ordered.at(-1);root._lastBlock?.classList.add('last-block');
  }
  // BEGIN DEBUG
  if(measure)return {timing:{patchMs:performance.now()-started,changedHTML,mounted:items.length}};
  // END DEBUG
  // Geometry is measured once, after fonts/assets and viewport size settle.

};
// All asynchronous layout dependencies are settled on the hidden surface.
window.astraReady=async width=>{
  if(!Number.isFinite(width)||width<=0)throw new Error("Invalid presentation width");
  await document.fonts.ready;
  await Promise.all([...document.images].map(async image=>{
    if(!image.complete)await new Promise(resolve=>{
      image.addEventListener('load',resolve,{once:true});image.addEventListener('error',resolve,{once:true});
    });
    if(image.decode)await image.decode().catch(()=>{});
  }));
  // A native frame resize reaches WebKit asynchronously. Wait for matching
  // measured layout rather than accepting an old viewport or guessing a delay.
  const matches=()=>Math.abs(root.getBoundingClientRect().width-width)<=1;
  if(!matches())await new Promise(resolve=>{
    const observer=new ResizeObserver(()=>{if(matches()){observer.disconnect();resolve();}});
    observer.observe(root);
    if(matches()){observer.disconnect();resolve();}
  });
};
// Carry user state across the two presentation views, only when its identified
// fragment still contains the same text. Complete tables stay in their sections.
window.astraViewState=()=>{
  function endpoint(node,offset){
    const owner=(node?.nodeType===1?node:node?.parentElement)?.closest('section[data-id]');
    if(!owner)return null;
    const range=document.createRange();range.selectNodeContents(owner);range.setEnd(node,offset);
    return {id:owner.dataset.id,text:owner.textContent,offset:range.toString().length,
      end:offset===(node.nodeType===3?node.length:node.childNodes.length)};
  }
  const selection=window.getSelection(),scroll=[];
  for(const n of nodes.values())for(const [index,box] of [n,...n.querySelectorAll('pre,.katex-display')].entries())
    if(box.scrollLeft)scroll.push({id:n.dataset.id,index,left:box.scrollLeft});
  return {scroll,anchor:endpoint(selection?.anchorNode,selection?.anchorOffset),focus:endpoint(selection?.focusNode,selection?.focusOffset)};
};
window.astraRestoreViewState=state=>{
  if(!state)return;
  for(const n of nodes.values())for(const saved of state.scroll||[])if(n.dataset.id===saved.id){
    const box=[n,...n.querySelectorAll('pre,.katex-display')][saved.index];if(box)box.scrollLeft=saved.left;
  }
  function endpoint(saved){
    if(!saved)return null;
    const owner=nodes.get(saved.id);
    if(!owner||owner.textContent!==saved.text)return null;
    const walker=document.createTreeWalker(owner,NodeFilter.SHOW_TEXT);let remaining=saved.offset,node;
    while(node=walker.nextNode()){if(remaining<node.length||(remaining===node.length&&saved.end))return [node,remaining];remaining-=node.length;}
    return remaining===0?[owner,owner.childNodes.length]:null;
  }
  const selection=window.getSelection(),anchor=endpoint(state.anchor),focus=endpoint(state.focus);
  selection.removeAllRanges();if(anchor&&focus)selection.setBaseAndExtent(...anchor,...focus);
};
new ResizeObserver(changed).observe(root);
window.addEventListener('scroll',()=>{if(window.scrollX||window.scrollY)window.scrollTo(0,0)});
document.addEventListener('load',changed,true);
document.fonts.ready.then(changed);
