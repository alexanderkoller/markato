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
