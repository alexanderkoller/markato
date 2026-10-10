import katex from 'katex';
export function renderMath(tex,displayMode=false) {
  return katex.renderToString(tex,{displayMode,throwOnError:false,trust:false,strict:'ignore',maxExpand:1000});
}
globalThis.astraMath=renderMath;
