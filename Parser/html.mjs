import MarkdownIt from 'markdown-it';
import {tex} from '@mdit/plugin-tex';
import katex from 'katex';

const md = new MarkdownIt({html:false,linkify:false});
const validateLink=md.validateLink.bind(md);
// Local images are served through our scheme handler. File links are never opened by the web view.
md.validateLink=url=>/^file:/i.test(url)||validateLink(url);
md.use(tex,{delimiters:'all',mathFence:true,render:(content,displayMode)=>katex.renderToString(content,{displayMode,throwOnError:false,trust:false,strict:'ignore',maxExpand:1000})});
// Custom scheme transports local assets; rendering remains markdown-it's job.
const image = md.renderer.rules.image;
md.renderer.rules.image = (tokens,i,options,env,self) => {
  const token=tokens[i],source=token.attrGet('src');
  if(source && !/^(?:data:|astra-asset:)/i.test(source)) {
    token.attrSet('src','astra-asset://image/?source='+encodeURIComponent(source));
  }
  token.attrSet('loading','eager');
  return image(tokens,i,options,env,self);
};
export function renderHTML(markdown,kind='') {
  return kind==='Literal'||kind==='HTMLBlock'?'<pre>'+md.utils.escapeHtml(markdown)+'</pre>':md.render(markdown);
}
export function localPreview(text,from,revision) {
  const starts=[0];for(let i=0;i<text.length;i++)if(text[i]==='\n')starts.push(i+1);
  const env={},tokens=md.parse(text,env),fragments=[];
  for(let i=0;i<tokens.length;) {
    const first=tokens[i];if(!first.map){i++;continue;}
    let end=i+1;
    if(first.nesting===1)while(end<tokens.length){if(tokens[end++].level===0)break;}
    const a=from+(starts[first.map[0]]??text.length),b=from+(starts[first.map[1]]??text.length);
    fragments.push({kind:first.type,from:a,to:b,anchorFrom:a,anchorTo:b,markdown:text.slice(a-from,b-from),html:md.renderer.render(tokens.slice(i,end),md.options,env)});
    i=end;
  }
  return JSON.stringify({revision,spans:[],fragments});
}
globalThis.astraLocal=localPreview;
