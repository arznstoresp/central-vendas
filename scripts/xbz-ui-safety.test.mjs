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

test('public XBZ catalog includes at least 100 unique supplier models',()=>{
 const source=readFileSync(new URL('../data/xbz-public-models.js',import.meta.url),'utf8');
 const models=JSON.parse(source.slice(source.indexOf('['),source.lastIndexOf(']')+1));
 assert.ok(models.length>=100,'expected 100 distinct models');
 assert.equal(new Set(models.map(x=>x.codigo)).size,models.length);
 assert.ok(models.every(x=>/^[0-9]{4,6}[A-Z0-9]*$/.test(x.codigo)&&x.nome));
 assert.ok(html.includes('data/xbz-public-models.js'));
 assert.ok(html.includes('window.XBZ_PUBLIC_MODELS'));
 assert.match(html,/custoInterno:''/);
});

test('official catalog images are committed and valid JPEG files',()=>{
 const source=readFileSync(new URL('../data/xbz-public-models.js',import.meta.url),'utf8');
 const models=JSON.parse(source.slice(source.indexOf('['),source.lastIndexOf(']')+1));
 const withPhoto=models.filter(p=>p.imagem);
 assert.equal(models.length,150);
 assert.ok(withPhoto.length>=100);
 const missing=[];
 for(const model of withPhoto){
   assert.match(model.imagem,/^public\/img\/xbz\/[0-9A-Z]+\.jpg$/);
   try{
     const image=readFileSync(new URL('../'+model.imagem,import.meta.url));
     assert.ok(image.length>1000,model.codigo+' image is too small');
     assert.equal(image[0],0xff,model.codigo+' is not JPEG');
     assert.equal(image[1],0xd8,model.codigo+' is not JPEG');
   }catch(e){missing.push(model.codigo+': '+e.message);}
 }
 assert.deepEqual(missing,[]);
 assert.match(html,/img\.dataset\.xbzRetried/);
 assert.match(html,/Preço sob consulta/);
});
