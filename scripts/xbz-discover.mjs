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
 await mkdir('artifacts',{recursive:true});
 await writeFile('artifacts/xbz-discovery.json',JSON.stringify({title,url:current,links},null,2));
 console.log('Diagnóstico concluído; links internos encontrados:',links.length,'(sem credenciais)');
} finally {await browser.close();}
