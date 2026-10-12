// Importador de catálogo XBZ: valida dados fornecidos, não faz scraping.
import { readFile } from 'node:fs/promises';
const url=process.env.SUPABASE_URL, key=process.env.SUPABASE_SERVICE_ROLE_KEY;
const path=process.argv[2]||'data/xbz-products.json';
const products=JSON.parse(await readFile(path,'utf8'));
if(!Array.isArray(products))throw Error('Arquivo deve conter uma lista JSON.');
const clean=[],seen=new Set();
for(const [i,p] of products.entries()){
 if(!p||typeof p!=='object')throw Error('Registro '+i+' inválido');
 const codigo=String(p.codigo_xbz||'').trim(),nome=String(p.nome||'').trim();
 if(!/^[a-zA-Z0-9._/-]{2,60}$/.test(codigo)||!nome||nome.length>180)throw Error('Código ou nome inválido no registro '+i);
 if(seen.has(codigo))throw Error('Código duplicado no lote: '+codigo);
 seen.add(codigo);
 const link=String(p.link_fornecedor||'').trim(),img=String(p.imagem_url||'').trim();
 for(const value of [link,img])if(value && !/^https:\/\//i.test(value))throw Error('URL inválida para '+codigo);
 if(link && !new URL(link).hostname.endsWith('xbzbrindes.com.br'))throw Error('Fornecedor não é XBZ: '+codigo);
 clean.push({codigo_xbz:codigo,nome,sku:String(p.sku||'').slice(0,80)||null,modelo:String(p.modelo||'').slice(0,120)||null,categoria:String(p.categoria||'').slice(0,120)||null,descricao:String(p.descricao||'').slice(0,3000)||null,imagem_url:img||null,link_fornecedor:link||null,status:'rascunho',origem:'xbz'});
}
if(!clean.length){console.log('Nenhum produto novo no arquivo; nenhuma alteração.');process.exit(0);}
if(!url||!key)throw Error('Configure SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY nos GitHub Actions Secrets.');
if(process.env.APPLY_IMPORT!=='true'){console.log('VALIDAÇÃO OK: '+clean.length+' registros, sem gravar no banco.');process.exit(0);}
const endpoint=url.replace(/\/$/,'')+'/rest/v1/produtos_xbz?on_conflict=codigo_xbz';
for(let i=0;i<clean.length;i+=100){
 const chunk=clean.slice(i,i+100);
 // Não substitui registros já validados: somente insere novos códigos.
 const codes=chunk.map(p=>p.codigo_xbz);
 const lookup=await fetch(url.replace(/\/$/,'')+'/rest/v1/produtos_xbz?select=codigo_xbz&codigo_xbz=in.('+codes.map(encodeURIComponent).join(',')+')',{headers:{apikey:key,Authorization:'Bearer '+key}});
 if(!lookup.ok)throw Error('Falha consultando duplicidades: '+lookup.status+' '+await lookup.text());
 const existing=new Set((await lookup.json()).map(p=>p.codigo_xbz));
 const fresh=chunk.filter(p=>!existing.has(p.codigo_xbz));
 if(!fresh.length)continue;
 const r=await fetch(endpoint,{method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json',Prefer:'return=minimal,resolution=ignore-duplicates'},body:JSON.stringify(fresh)});
 if(!r.ok)throw Error('Falha importando: '+r.status+' '+await r.text());
 console.log('Novos rascunhos cadastrados: '+fresh.length);
}
console.log('Importação concluída. Produtos aguardam validação administrativa.');
