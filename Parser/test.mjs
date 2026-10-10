import assert from 'node:assert/strict';
import {renderMath} from './math.mjs';
assert.match(renderMath('x^2'),/class="katex"/);
assert.match(renderMath('\\begin{aligned}a&=b\\\\c&=d\\end{aligned}',true),/katex-display/);
assert.match(renderMath('\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}',true),/katex/);
assert.match(renderMath('\\frac{'),/katex-error/);
assert(!renderMath('\\href{javascript:alert(1)}{x}').includes('href="javascript:'));
console.log('KaTeX inline/display, matrices, errors and untrusted-input checks passed.');
