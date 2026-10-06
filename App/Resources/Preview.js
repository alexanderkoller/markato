const root=document.getElementById('preview'),nodes=new Map();
let revision=0,scheduled=false;
function geometry(){
  const origin=root.getBoundingClientRect().top;
  return {revision,height:root.offsetHeight,items:[...nodes.values()].map(n=>{
    const box=(n._body || n).getBoundingClientRect();
    // Match MacDown's sparse landmarks: headings and standalone images.
    // Paragraph/table/code boundaries remain geometry for window rebasing only.
    const heading=n.querySelector(':scope > h1,:scope > h2,:scope > h3,:scope > h4,:scope > h5,:scope > h6');
    const p=n.querySelector(':scope > p');
    const image=p && p.children.length===1 && p.firstElementChild.tagName==='IMG' && !p.textContent.trim()
      ?p.firstElementChild:null;
    const landmark=heading || image;
    return {id:n.dataset.id,y:box.top-origin,height:box.height,
      landmarkY:landmark?landmark.getBoundingClientRect().top-origin:null};
  })};
}
// Restore each library-rendered row batch before updates; then put adjacent
// batches in one table so they share columns and have no repeated header/gap.
function restoreTables(){
  for(const n of nodes.values()) {
    if(n._body && n._table)n._table.appendChild(n._body);
    n.style.display='';n._body=null;n._table=null;
  }
}
function joinTables(items){
  let group=null,previous=null;
  for(const item of items){
    const n=nodes.get(item.id),table=n.querySelector(':scope > table'),body=table?.tBodies[0];
    if(item.kind==='Table' && body){
      n._body=body;n._table=table;
      if(group && previous.container===item.container && previous.to===item.from){
        group.appendChild(body);n.style.display='none';
      }else group=table;
    }else group=null;
    previous=item;
  }
}
function report(){scheduled=false;window.webkit.messageHandlers.geometry.postMessage(geometry());}
function changed(){if(!scheduled){scheduled=true;requestAnimationFrame(report);}}
window.astraUpdate=(items,version,points,measure=false)=>{
  const started=measure?performance.now():0;let changedHTML=0;
  revision=version;document.documentElement.style.fontSize=points+'px';
  restoreTables();
  const retained=new Set(items.map(x=>x.id));
  for(const [id,n] of nodes)if(!retained.has(id)){n.remove();nodes.delete(id);}
  let previous=null;
  for(const item of items){
    let n=nodes.get(item.id);
    if(!n){n=document.createElement('section');n.dataset.id=item.id;nodes.set(item.id,n);}
    if(item.html!==undefined && n._html!==item.html){n.innerHTML=item.html;n._html=item.html;changedHTML++;}
    const next=previous?previous.nextSibling:root.firstChild;
    if(next!==n)root.insertBefore(n,next);
    previous=n;
  }
  joinTables(items);
  if(!measure)return geometry();
  const patched=performance.now(),result=geometry(),finished=performance.now();
  result.timing={patchMs:patched-started,layoutMs:finished-patched,totalMs:finished-started,changedHTML,mounted:items.length};
  return result;
};
new ResizeObserver(changed).observe(root);
document.addEventListener('load',changed,true);
document.fonts.ready.then(changed);
