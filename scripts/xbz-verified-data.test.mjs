import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeXbzRecord,canQuoteXbz,quoteStatusXbz,validateOrderQuantityXbz} from './xbz-verified-data.mjs';
const now = Date.parse('2026-10-12T23:00:00Z');
const checked = '2026-10-12T22:00:00Z';
const input = {fonte_confirmada:true,codigo_xbz:'09318G-AZC',sku_fornecedor:'X253219',nome:'BOLSA EVA',custo:51.84,disponivel:true,venda_minima:5,multiplo:1,acrescimo_abaixo_minimo_pct:5};
test('supplier record preserves verified attributes',()=>{
 const r=normalizeXbzRecord(input,checked);
 assert.equal(r.codigo_xbz,'09318G-AZC');
 assert.equal(r.custo,51.84);
 assert.equal(r.venda_minima,5);
 assert.equal(r.consultado_em,checked);
 assert.equal(r.status_validacao,'verificado');
});
test('rejects missing source evidence, price or timestamp',()=>{
 assert.throws(()=>normalizeXbzRecord({...input,fonte_confirmada:false},checked),/evidence/);
 assert.throws(()=>normalizeXbzRecord({...input,custo:0},checked),/cost/);
 assert.throws(()=>normalizeXbzRecord(input),/timestamp/);
 assert.throws(()=>normalizeXbzRecord(input,'2026-10-12T22:00:00'),/timestamp/);
});
test('stale and unavailable products cannot be quoted',()=>{
 const r=normalizeXbzRecord(input,checked);
 assert.equal(canQuoteXbz(r,now),true);
 assert.equal(canQuoteXbz(r,now+7*3600000),false);
 assert.match(quoteStatusXbz(r,now+7*3600000),/vencida/);
 assert.equal(canQuoteXbz({...r,disponivel:false},now),false);
 assert.match(quoteStatusXbz({...r,disponivel:false},now),/Indisponivel/);
 assert.equal(canQuoteXbz({...r,status_validacao:'pendente'},now),false);
});
test('minimum and multiple are checked',()=>{
 const r=normalizeXbzRecord(input,checked);
 assert.equal(validateOrderQuantityXbz(r,4).valid,false);
 assert.equal(validateOrderQuantityXbz(r,5).valid,true);
 assert.equal(validateOrderQuantityXbz({...r,multiplo:5},6).valid,false);
 assert.equal(validateOrderQuantityXbz({...r,multiplo:5},10).valid,true);
});
