// XBZ: public catalog first, then authenticated SKU search. No orders or writes.
import { chromium } from 'playwright';
import { mkdir, writeFile } from 'node:fs/promises';
const browser=await chromium.launch({headless:true});
try {
 const publicPage=await browser.newPage();
 await publicPage.goto('https://www.xbzbrindes.com.br/brindes',{waitUntil:'domcontentloaded',timeout:60000});
 await publicPage.waitForTimeout(2500);
 const publicTitle=await publicPage.title();
 const publicBody=(await publicPage.locator('body').innerText()).slice(0,3000);
 const cloudflareBlocked=/just a moment|performing security verification|verify you are not a bot/i.test(publicTitle+' '+publicBody);
 const catalog=cloudflareBlocked?[]:await publicPage.locator('a[href]').evaluateAll(links=>{
  const found=new Map();
  for(const a of links){
   const url=new URL(a.href);
   if(url.hostname!=='www.xbzbrindes.com.br')continue;
   const code=decodeURIComponent(url.pathname.split('/').filter(Boolean).pop()||'').trim();
   if(!/^[0-9]{4,6}[A-Za-z]{0,3}$/.test(code))continue;
   const text=(a.innerText||'').replace(/\s+/g,' ').trim();
   const parent=a.closest('article,li,.produto,.item,.product,.box')||a.parentElement?.parentElement;
   const name=(parent?.innerText||text).replace(/\s+/g,' ').trim().replace(new RegExp('^'+code+'\\s*'),'').slice(0,180);
   const img=parent?.querySelector('img')?.getAttribute('src')||a.querySelector('img')?.getAttribute('src')||null;
   if(!found.has(code))found.set(code,{codigo_xbz:code,nome:name||code,link_fornecedor:url.href,imagem_url:img?new URL(img,url.href).href:null});
  }
  return [...found.values()];
 });
 const publicDiagnostics={
  url:publicPage.url(),
  title:await publicPage.title(),
  anchors:await publicPage.locator('a[href]').count(),
  candidateLinks:await publicPage.locator('a[href]').evaluateAll(els=>els.filter(a=>/produto|brinde|catalog|item/i.test(a.href)).slice(0,30).map(a=>({text:(a.innerText||'').trim().slice(0,90),path:new URL(a.href).pathname}))),
  visibleText:publicBody.slice(0,1800),
  blockedByCloudflare:cloudflareBlocked
 };
 await mkdir('artifacts',{recursive:true});
 await writeFile('artifacts/xbz-public-diagnostics.json',JSON.stringify(publicDiagnostics,null,2));
 if(catalog.length===0){
  await writeFile('artifacts/xbz-public-catalog.json',JSON.stringify({count:0,products:[]},null,2));
  console.error(cloudflareBlocked?'XBZ_PUBLIC_BLOCKED_BY_CLOUDFLARE: security verification prevents public catalog discovery. Use authorized supplier export or approved API; do not bypass verification.':'XBZ_PUBLIC_EMPTY: no public products detected. Inspect xbz-public-diagnostics.json');
  process.exitCode=1;
 }else{
 const user=process.env.XBZ_USER,pass=process.env.XBZ_PASSWORD;
 if(!user||!pass)throw Error('Missing XBZ_USER / XBZ_PASSWORD');
 const page=await browser.newPage();
 await page.goto('https://minhaxbz.com.br/',{waitUntil:'domcontentloaded',timeout:45000});
 const userInput=page.locator('input[autocomplete="username"],input[name*="user" i],input[placeholder*="usuário" i],input[placeholder*="usuario" i]').first();
 const passInput=page.locator('input[type="password"]').first();
 if(await userInput.count())await userInput.fill(user);else await page.locator('input').first().fill(user);
 await passInput.fill(pass);
 const login=page.getByRole('button',{name:/entrar|login|acessar/i}).first();
 if(await login.count())await login.click();else await passInput.press('Enter');
 await page.waitForTimeout(3500);
 const menu=page.locator('a[href]').filter({hasText:/PRODUTOS/i}).first();
 if(!await menu.count())throw Error('Menu Produtos not found');
 await menu.click();
 await page.waitForTimeout(2200);
 const queryInput=page.locator('#filtroNome,input[name="filtroNome"]').first();
 const qtyInput=page.locator('#filtroQuantidade,input[name="filtroQuantidade"]').first();
 if(!await queryInput.count()||!await qtyInput.count())throw Error('XBZ search inputs not found');
 const results=[];
 for(const product of catalog.slice(0,100)){
  await queryInput.fill(product.codigo_xbz);
  await qtyInput.fill('1');
  const search=page.getByRole('button',{name:/buscar produtos/i}).first();
  await search.click();
  await page.waitForTimeout(2500);
  const rows=await page.locator('table tbody tr').allInnerTexts();
  results.push({codigo_xbz:product.codigo_xbz,rows:rows.slice(0,3).map(s=>s.slice(0,280))});
 }
 await mkdir('artifacts',{recursive:true});
 await writeFile('artifacts/xbz-public-catalog.json',JSON.stringify({count:catalog.length,products:catalog},null,2));
 await writeFile('artifacts/xbz-crosscheck.json',JSON.stringify({searched:results.length,results},null,2));
 console.log('Public catalog:',catalog.length,'Authenticated searches:',results.length);
 } // public products found

}finally{await browser.close();}
