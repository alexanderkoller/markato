import {parser, Table} from '@lezer/markdown';
import {TreeFragment} from '@lezer/common';
import {renderHTML} from './html.mjs';

const math = {
  defineNodes: [{name:'MathInline'}, {name:'MathBlock', block:true}],
  parseInline: [{name:'MathInline', before:'Escape', parse(cx, next, pos) {
    const dollar = next === 36 && cx.char(pos+1) !== 36;
    const slash = next === 92 && cx.char(pos+1) === 40;
    if (!dollar && !slash) return -1;
    if (dollar && /\s/.test(cx.slice(pos+1,pos+2))) return -1;
    const start = pos + (slash ? 2 : 1);
    for(let end=start;end<cx.end;end++) {
      if(cx.char(end)===10) return -1;
      if(cx.char(end)===92) {
        if(slash && cx.char(end+1)===41) return cx.addElement(cx.elt('MathInline',pos,end+2));
        end++; continue;
      }
      if(dollar && cx.char(end)===36 && end>start && !/\s/.test(cx.slice(end-1,end)))
        return cx.addElement(cx.elt('MathInline',pos,end+1));
    }
    return -1;
  }}],
  parseBlock: [{name:'MathBlock', before:'FencedCode', parse(cx,line) {
    const first=line.text.slice(line.pos).trim();
    const open=first.startsWith('$$')?'$$':first.startsWith('\\[')?'\\[':null;
    if(!open) return false;
    const close=open==='$$'?'$$':'\\]'; const from=cx.lineStart+line.pos;
    if(first.slice(open.length).includes(close)) {
      const to=cx.lineStart+line.text.length;cx.nextLine();cx.addElement(cx.elt('MathBlock',from,to));return true;
    }
    let to=cx.lineStart+line.text.length;
    while(cx.nextLine()) { to=cx.lineStart+line.text.length;if(line.text.includes(close)){cx.nextLine();break;} }
    cx.addElement(cx.elt('MathBlock',from,to)); return true;
  }}]
};
const configured=parser.configure([Table,math]);
const documentIdentity=globalThis.nativeDocumentIdentity ?? `js:${Math.random().toString(36).slice(2)}`;
let tree=null, treeRevision=-1, blocks=[], nextID=0, documentLength=0, blockChange=null;
const references=new Map();
const leafKinds=/^(Paragraph|ATXHeading[1-6]|SetextHeading[12]|FencedCode|CodeBlock|Table|MathBlock|HorizontalRule|HTMLBlock|BulletList|OrderedList|Blockquote|LinkReference)$/;

function read(input,a,b){return input.read(a,b);}
// One immutable JS string per revision keeps parser reads inside JavaScript.
// Calling a native rope proxy for every line and token dominates cold parsing.
export function documentInput(text) {
  return {length:text.length,lineChunks:true,read:(a,b)=>text.slice(a,b),chunk(position){
    const newline=text.indexOf('\n',position);
    return text.slice(position,newline<0?text.length:newline===position?newline+1:newline);
  }};
}
function referencedDefinitions(markdown) {
  if(!references.size)return '';
  const used=new Set();const re=/\[([^\]\n]+)\](?:\[([^\]\n]*)\])?/g;let m;
  while((m=re.exec(markdown)))used.add((m[2]||m[1]).trim().replace(/\s+/g,' ').toLowerCase());
  return [...used].filter(id=>references.has(id)).map(id=>references.get(id)).join('\n');
}
// Prepared blocks belong to the immutable document revision; Lezer retains its indexed syntax tree.
// Each block retains its HTML when its complete rendering input is unchanged.
function renderingInput(raw) {
  const defs=referencedDefinitions(raw);
  return defs?raw+'\n\n'+defs:raw;
}
function prepareContent(block,input) {
  if(block.raw===undefined)block.raw=read(input,block.from,block.to);
  if(block.markdown===undefined)block.markdown=renderingInput(block.raw);
}
function prepareDocument(input,changes,reuseCoordinates) {
  const oldBlocks=blocks;
  documentLength=input.length;
  const previous=new Map();
  const positioned=new Map();
  for(const block of blocks) {
    const key=block.kind+'\0'+block.markdown;
    if(block.markdown!==undefined) {
      if(!previous.has(key))previous.set(key,{items:[],next:0});
      previous.get(key).items.push(block);
    }
    if(reuseCoordinates) {
      let from=block.from,to=block.to,valid=true;
      for(const edit of changes) {
        const delta=edit.inserted-(edit.to-edit.from);
        if(edit.to<=from){from+=delta;to+=delta;}
        else if(edit.from<to){valid=false;break;}
      }
      if(valid)positioned.set(from,{block,to});
    }
  }
  const nodes=[];
  tree.iterate({enter(n){if(leafKinds.test(n.name)){nodes.push(n.node);return false;}}});
  blocks=nodes.map(node=>{
    const exact=positioned.get(node.from);
    if(exact?.to===node.to&&exact.block.kind===node.name) {
      const old=exact.block,markdown=old.raw===undefined?undefined:renderingInput(old.raw);
      const reusable=markdown===undefined||markdown===old.markdown;
      return {id:reusable?old.id:`${documentIdentity}:${++nextID}`,kind:node.name,from:node.from,to:node.to,
        raw:old.raw,markdown,html:reusable?old.html:undefined};
    }
    // A caller without recorded edits can still reuse identical prepared input.
    // Recorded edits locate retained blocks directly, without rereading their text.
    let raw,markdown,old;
    if(!reuseCoordinates&&previous.size) {
      raw=read(input,node.from,node.to);markdown=renderingInput(raw);
      const candidates=previous.get(node.name+'\0'+markdown);
      old=candidates?.items[candidates.next++];
    }
    return {id:old?.id ?? `${documentIdentity}:${++nextID}`,kind:node.name,from:node.from,to:node.to,raw,markdown,html:old?.html};
  });
  if(!blocks.length&&input.length)blocks=[{id:`${documentIdentity}:empty`,kind:'Empty',from:0,to:input.length,raw:'',markdown:'',html:''}];
  let prefix=0,suffix=0;
  while(prefix<oldBlocks.length&&prefix<blocks.length&&oldBlocks[prefix].id===blocks[prefix].id&&oldBlocks[prefix].from===blocks[prefix].from&&oldBlocks[prefix].to===blocks[prefix].to)prefix++;
  const shift=blocks.length&&oldBlocks.length?blocks.at(-1).from-oldBlocks.at(-1).from:0;
  while(suffix<oldBlocks.length-prefix&&suffix<blocks.length-prefix) {
    const a=oldBlocks[oldBlocks.length-1-suffix],b=blocks[blocks.length-1-suffix];
    if(a.id!==b.id||a.from+shift!==b.from||a.to+shift!==b.to)break;
    suffix++;
  }
  blockChange={prefix,suffix,shift};
}
function visibleStyles(input,from,to) {
  // Remember rendering context for any block whose styles cross to Swift, so
  // a later reference change cannot retain stale prepared style coverage.
  for(const block of selectedBlocks(from,to))prepareContent(block,input);
  const spans=[];
  tree.iterate({from,to,enter(n){
    if(n.to<=from||n.from>=to)return false;
    if(/^(ATXHeading[1-6]|SetextHeading[12]|StrongEmphasis|Emphasis|Link|URL|MathInline|MathBlock)$/.test(n.name)||n.name.includes('Mark'))
      spans.push({kind:n.name,from:Math.max(from,n.from),to:Math.min(to,n.to)});
  }});
  return spans;
}
function selectedBlocks(from,to) {
  let low=0,high=blocks.length;
  while(low<high){const mid=(low+high)>>1;if((mid===blocks.length-1?documentLength:blocks[mid].to)<=from)low=mid+1;else high=mid;}
  const selected=[];
  for(let i=low;i<blocks.length&&(i===0?0:blocks[i-1].to)<to;i++)selected.push(blocks[i]);
  return selected;
}

export function parseViewport(input,revision,from,to,changes=[],previousRevision=-1,includeSpans=true,includeHTML=true,includeFragments=true,includeManifest=true) {
  if(!tree||treeRevision!==revision) {
    const reuseCoordinates=!!tree&&treeRevision===previousRevision;
    let fragments=reuseCoordinates?TreeFragment.addTree(tree):[];
    for(const edit of changes) fragments=TreeFragment.applyChanges(fragments,[{fromA:edit.from,toA:edit.to,fromB:edit.from,toB:edit.from+edit.inserted}]);
    const partial=configured.startParse(input,fragments);let parsed=null,lastSlice=Date.now();
    while(!(parsed=partial.advance())) {
      if(Date.now()-lastSlice>=4) {
        if(typeof nativeIsCurrent==='function'&&!nativeIsCurrent())throw new Error('Superseded parse');
        lastSlice=Date.now();
      }
    }
    tree=parsed;treeRevision=revision;
    references.clear();
    tree.iterate({enter(n){if(n.name==='LinkReference') {
      const value=read(input,n.from,n.to), id=value.match(/^\[([^\]]+)\]:/)?.[1];
      if(id){const key=id.trim().replace(/\s+/g,' ').toLowerCase();if(!references.has(key))references.set(key,value);}
      return false;
    }
      // Definitions are block syntax. Inline descendants cannot contain them.
      if(leafKinds.test(n.name)&&!['BulletList','OrderedList','Blockquote'].includes(n.name))return false;
    }});
    prepareDocument(input,changes,reuseCoordinates);
  }
  const fragments=includeFragments?selectedBlocks(from,to).map(block=>{
    prepareContent(block,input);
    if(includeHTML&&block.html===undefined)block.html=renderHTML(block.markdown,block.kind);
    const {id,kind,from,to,markdown}=block;
    return {id,kind,from,to,markdown,html:includeHTML?block.html:undefined};
  }):[];
  const spans=includeSpans?visibleStyles(input,from,to):[];
  const manifest=includeManifest===true?blocks.map(({id,kind,from,to})=>({id,kind,from,to})):undefined;
  return JSON.stringify({revision,spans,fragments,blocks:manifest,blockChange:includeManifest==='delta'?{...blockChange,blocks:blocks.slice(blockChange.prefix,blocks.length-blockChange.suffix).map(({id,kind,from,to})=>({id,kind,from,to}))}:undefined});
}
globalThis.astraParse=parseViewport;
globalThis.astraInput=documentInput;
