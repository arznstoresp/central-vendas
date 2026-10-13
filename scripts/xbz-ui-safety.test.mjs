import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const html=readFileSync(new URL('../index.html',import.meta.url),'utf8');
test('XBZ UI never claims supplier synchronization without supplier integration',()=>{
 assert.doesNotMatch(html,/Última sync: 08\/10, 21:27/);
 assert.match(html,/XBZ: consulta automática indisponível/);
 const begin=html.indexOf('async function syncXbzPrices(showToast){');
 const end=html.indexOf('// ====================== STATE ======================',begin);
 assert.ok(begin>0&&end>begin);
 const fn=html.slice(begin,end);
 assert.doesNotMatch(fn,/from\('precos_xbz'\)/);
 assert.doesNotMatch(fn,/localStorage\.setItem\('cv_xbz_sync'/);
 assert.doesNotMatch(fn,/custoInterno\s*=/);
 assert.match(fn,/return false/);
});
