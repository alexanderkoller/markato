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
let tree=null, treeRevision=-1;
const references=new Map();
const leafKinds=/^(Paragraph|ATXHeading[1-6]|SetextHeading[12]|FencedCode|CodeBlock|Table|MathBlock|HorizontalRule|HTMLBlock|BulletList|OrderedList|Blockquote)$/;

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
  const used=new Set();const re=/\[([^\]\n]+)\](?:\[([^\]\n]*)\])?/g;let m;
  while((m=re.exec(markdown)))used.add((m[2]||m[1]).trim().replace(/\s+/g,' ').toLowerCase());
  return [...used].filter(id=>references.has(id)).map(id=>references.get(id)).join('\n');
}
function fragment(input,node,includeHTML) {
  const a=node.from,b=node.to;
  let text;
  // Render complete semantic blocks. A table's column widths and a code
  // block's layout must not depend on which source rows are currently visible.
  text=read(input,a,b);
  const defs=referencedDefinitions(text);if(defs)text+='\n\n'+defs;
  return {kind:node.name,from:a,to:b,markdown:text,html:includeHTML?renderHTML(text,node.name):undefined};
}

export function parseViewport(input,revision,from,to,changes=[],previousRevision=-1,includeSpans=true,includeHTML=true) {
  if(!tree||treeRevision!==revision) {
    let fragments=tree&&treeRevision===previousRevision?TreeFragment.addTree(tree):[];
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
    }}});
  }
  const selected=[];
  tree.iterate({from,to,enter(n){
    if(n.to<=from||n.from>=to)return false;
    if(leafKinds.test(n.name)){selected.push(fragment(input,n.node,includeHTML));return false;}
  }});
  const spans=[];
  // Every fragment's highlighting range includes the viewport. Walk their
  // combined range once instead of emitting the same viewport spans per block.
  if(includeSpans&&selected.length) {
    const spanFrom=Math.min(from,...selected.map(f=>f.from));
    const spanTo=Math.max(to,...selected.map(f=>f.to));
    tree.iterate({from:spanFrom,to:spanTo,enter(n){
      if(!['Document','Paragraph'].includes(n.name))spans.push({kind:n.name,from:n.from,to:n.to});
    }});
  }
  return JSON.stringify({revision,spans,fragments:selected});
}
globalThis.astraParse=parseViewport;
globalThis.astraInput=documentInput;
