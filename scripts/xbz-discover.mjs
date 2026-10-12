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
   // XBZ exige quantidade mínima 1 para pesquisar. Não conclui pedidos.
   const quantityCandidates=page.locator('input[name*="quant" i],input[id*="quant" i],input[placeholder*="quant" i],input[aria-label*="quant" i]');
   const quantityLabels=page.getByLabel(/quantidade/i);
   const quantity=await quantityCandidates.count()?quantityCandidates.first():quantityLabels.first();
   productsView.quantityFieldFound=(await quantity.count())>0;
   productsView.quantitySet=false;
   productsView.searchClicked=false;
   if(productsView.quantityFieldFound){
     try{
       await quantity.fill('1',{timeout:7000});
       productsView.quantitySet=true;
       const searchButton=page.getByRole('button',{name:/pesquisar|buscar/i}).first();
       const searchInput=page.locator('input[type="submit"][value*="pesquis" i],input[type="button"][value*="pesquis" i]').first();
       if(await searchButton.count()){await searchButton.click({timeout:9000});productsView.searchClicked=true;}
       else if(await searchInput.count()){await searchInput.click({timeout:9000});productsView.searchClicked=true;}
       if(productsView.searchClicked)await page.waitForTimeout(2500);
     }catch(e){productsView.searchError=String(e.message||e).slice(0,180);}
   }
   productsView.inputs=await page.locator('input').evaluateAll(els=>els.filter(e=>e.type!=='password'&&e.type!=='hidden').map(e=>({type:e.type,name:e.name,id:e.id,placeholder:e.placeholder,ariaLabel:e.getAttribute('aria-label')})).slice(0,35));
   // Apenas estrutura e amostra limitada de produtos após a pesquisa.
   // Não captura pedidos, contatos ou tokens.
   productsView.searchResults={
     tableRows:await page.locator('table tbody tr').count(),
     tableHeaders:(await page.locator('table thead th').allTextContents()).map(s=>s.trim()).slice(0,25),
     sampleRows:await page.locator('table tbody tr').evaluateAll(rows=>rows.slice(0,5).map(row=>row.innerText.trim().slice(0,350))),
     visibleProductCards:await page.locator('[class*="produto-card"],[class*="product-card"],[data-produto]').count(),
     paginationLabels:(await page.getByText(/próxima|anterior|página \\d|resultados|itens encontrados/i).allTextContents()).map(s=>s.trim().slice(0,90)).slice(0,12)
   };
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
