const root=document.getElementById('preview'),nodes=new Map();
let revision=0,measurement=0,scheduled=false,assetBase=null;
function geometry(){
  // The native clip owns vertical scrolling. Browser selection restoration and
  // scroll anchoring must not introduce a second origin inside the web view.
  if(window.scrollX||window.scrollY)window.scrollTo(0,0);
  const frame=root.getBoundingClientRect(),origin=frame.top;
  return {revision,measurement:++measurement,width:frame.width,height:root.offsetHeight,items:[...root.children].map(n=>{
    const box=n.getBoundingClientRect();
    const heading=n.querySelector(':scope > h1,:scope > h2,:scope > h3,:scope > h4,:scope > h5,:scope > h6');
    const p=n.querySelector(':scope > p');
    const image=p && p.children.length===1 && p.firstElementChild.tagName==='IMG' && !p.textContent.trim()
      ?p.firstElementChild:null;
    const reference=heading || image;
    return {id:n.dataset.id,y:box.top-origin,height:box.height,
      landmarkY:reference?reference.getBoundingClientRect().top-origin:null};
  })};
}
function report(){scheduled=false;window.webkit.messageHandlers.geometry.postMessage(geometry());}
function changed(){if(!scheduled){scheduled=true;requestAnimationFrame(report);}}
window.astraUpdate=(items,version,points,base="",measure=false)=>{
  // BEGIN DEBUG
  const started=measure?performance.now():0;let changedHTML=0;
  // END DEBUG
  revision=version;document.documentElement.style.fontSize=points+'px';
  if(assetBase!==base){root.replaceChildren();nodes.clear();assetBase=base;}
  const retained=new Set(items.map(x=>x.id));
  for(const [id,n] of nodes)if(!retained.has(id)){n.remove();nodes.delete(id);}
  let previous=null;
  for(const item of items){
    let n=nodes.get(item.id);
    if(!n){n=document.createElement('section');n.dataset.id=item.id;nodes.set(item.id,n);}
    n.dataset.from=item.from;n.dataset.to=item.to;
    if(item.html!==undefined && n._html!==item.html){
      const template=document.createElement('template');template.innerHTML=item.html;
      // BEGIN DEBUG
      changedHTML++;
      // END DEBUG
      // Relative assets from different document directories must not share a
      // WebKit resource-cache key, even when the Markdown markup is identical.
      // Assign the final resource key while the fragment is inert. Inserting
      // first and rewriting src afterward starts two image requests.
      for(const image of template.content.querySelectorAll('img[src]')){
        const url=new URL(image.src);
        if(url.protocol==='astra-asset:'){url.searchParams.set('base',base);image.src=url.href;}
      }
      n.replaceChildren(template.content);n._html=item.html;
    }
    const next=previous?previous.nextSibling:root.firstChild;
    if(next!==n)root.insertBefore(n,next);
    previous=n;
  }
  // BEGIN DEBUG
  if(measure){
  const patched=performance.now(),result=geometry(),finished=performance.now();
  result.timing={patchMs:patched-started,layoutMs:finished-patched,totalMs:finished-started,changedHTML,mounted:items.length};
  return result;
  }
  // END DEBUG
  return geometry();
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
