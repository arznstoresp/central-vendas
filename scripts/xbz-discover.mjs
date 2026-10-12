// Diagnóstico autenticado XBZ. Não exporta credenciais nem coleta dados pessoais.
import { chromium } from 'playwright';
import { writeFile, mkdir } from 'node:fs/promises';
const user=process.env.XBZ_USER,pass=process.env.XBZ_PASSWORD;
if(!user||!pass)throw Error('Configure XBZ_USER e XBZ_PASSWORD como GitHub Actions Secrets');
const browser=await chromium.launch({headless:true});
try {
 const page=await browser.newPage({acceptDownloads:false});
 await page.goto('https://minhaxbz.com.br/',{waitUntil:'domcontentloaded',timeout:45000});
 const inputs=page.locator('input');
 const userInput=page.locator('input[autocomplete="username"],input[name*="user" i],input[placeholder*="usuário" i],input[placeholder*="usuario" i]').first();
 const passInput=page.locator('input[type="password"]').first();
 if(await passInput.count()===0)throw Error('Campo de senha não identificado: formulário alterado');
 if(await userInput.count())await userInput.fill(user);else await inputs.first().fill(user);
 await passInput.fill(pass);
 const login=page.getByRole('button',{name:/entrar|login|acessar/i}).first();
 if(await login.count())await login.click();else await passInput.press('Enter');
 await page.waitForLoadState('domcontentloaded',{timeout:30000}).catch(()=>{});
 await page.waitForTimeout(3500);
 const title=await page.title(),current=page.url();
 const visible=(await page.locator('body').innerText()).slice(0,10000);
 if(/acesso não autorizado|não foi possível entrar|usuário ou senha inválid/i.test(visible))throw Error('Login não autorizado; revise credenciais privadas');
 const links=await page.locator('a[href]').evaluateAll(els=>els.map(a=>({text:(a.innerText||'').trim().slice(0,100),href:a.href})).filter(x=>x.text&&x.href.startsWith('https://minhaxbz.com.br')).slice(0,150));
 // Descoberta estrutural da tela de produtos, sem capturar clientes, pedidos ou segredos.
 const productsMenu=page.locator('a[href]').filter({hasText:/PRODUTOS/i}).first();
 let productsView={found:false,menuMatches:await productsMenu.count(),clickSucceeded:false};
 if(await productsMenu.count()){
   try{
     await productsMenu.click({timeout:12000});
     productsView.clickSucceeded=true;
   }catch(e){
     productsView.clickError=String(e.message||e).slice(0,180);
     // Click the link directly only when Playwright cannot activate it normally.
     try{await productsMenu.evaluate(el=>el.click());productsView.clickSucceeded=true;}catch{}
   }
   await page.waitForTimeout(3000);
   const headings=await page.locator('h1,h2,h3,h4').allTextContents();
   const buttons=await page.locator('button').evaluateAll(els=>els.map(e=>(e.innerText||e.getAttribute('aria-label')||'').trim().slice(0,60)).filter(Boolean).slice(0,50));
   const tables=await page.locator('table').count();
   const productLinks=await page.locator('a[href]').evaluateAll(els=>els.map(e=>({text:(e.innerText||'').trim().slice(0,50),path:new URL(e.href).pathname})).filter(x=>/produto|catalog|vitrine/i.test(x.text+' '+x.path)).slice(0,60));
   productsView={...productsView,found:true,urlPath:new URL(page.url()).pathname,headings:headings.slice(0,30),buttons,tables,productLinks};
 }
 await mkdir('artifacts',{recursive:true});
 await writeFile('artifacts/xbz-discovery.json',JSON.stringify({title,url:current,links,productsView},null,2));
 console.log('Diagnóstico concluído; links internos encontrados:',links.length,'(sem credenciais)');
} finally {await browser.close();}
