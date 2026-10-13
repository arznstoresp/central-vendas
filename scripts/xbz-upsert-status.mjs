/**
 * xbz-upsert-status.mjs
 * 
 * Atualiza o campo `status` de cada produto em produtos_xbz com base
 * nos dados de precos_xbz.
 * 
 * Uso:
 *   SUPABASE_URL=https://xxx.supabase.co SUPABASE_ANON_KEY=eyJ... node scripts/xbz-upsert-status.mjs
 * 
 * Ou configure .env.local com SUPABASE_URL e SUPABASE_ANON_KEY e rode:
 *   node -r dotenv/config scripts/xbz-upsert-status.mjs
 * 
 * SEGURANÇA: Nunca coloque URL ou chave no código. Use variáveis de ambiente.
 * Este script não apaga registros. Apenas faz UPSERT do campo status.
 */

import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  console.error('ERRO: Defina SUPABASE_URL e SUPABASE_ANON_KEY como variáveis de ambiente.');
  process.exit(1);
}

const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// ─── Lógica de status (espelhada do frontend) ───────────────────────────────

function calcXbzStatus(variantes) {
  let temConf = false, temCons = false, temIndisp = false;
  for (const v of variantes) {
    const disp = String(v.disponivel || '').trim();
    const precoReal = v.preco != null && Number(v.preco) > 0;
    const textoConsulte = String(v.preco_texto || '').includes('CONSULTE');
    if (disp.includes('INDISPON')) {
      temIndisp = true;
    } else if (disp.includes('CONSULTE')) {
      temCons = true;
    } else if (disp === 'SIM') {
      if (precoReal) { temConf = true; }
      else if (textoConsulte) { temCons = true; }
    }
  }
  if (temConf && !temCons && !temIndisp) return 'preco_confirmado';
  if (temCons && !temConf && !temIndisp) return 'sob_consulta';
  if (temIndisp && !temConf && !temCons)  return 'indisponivel';
  if (temIndisp || (temConf && temCons))  return 'misto';
  return 'pendente_auditoria';
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  console.log('Lendo precos_xbz...');
  const { data: precos, error: errPrecos } = await sb
    .from('precos_xbz')
    .select('codigo_variante,codigo_xbz,disponivel,preco,preco_texto');
  if (errPrecos) { console.error('Falha ao ler precos_xbz:', errPrecos.message); process.exit(1); }

  // Agrupar por codigo_xbz
  const mapa = {};
  for (const r of precos) {
    const c = String(r.codigo_xbz || '').trim();
    if (!c) continue;
    if (!mapa[c]) mapa[c] = [];
    mapa[c].push(r);
  }
  console.log(`Códigos únicos em precos_xbz: ${Object.keys(mapa).length}`);

  console.log('\nLendo produtos_xbz...');
  const { data: produtos, error: errProd } = await sb
    .from('produtos_xbz')
    .select('codigo_xbz,status');
  if (errProd) { console.error('Falha ao ler produtos_xbz:', errProd.message); process.exit(1); }
  console.log(`Produtos em produtos_xbz: ${produtos.length}`);

  // Calcular status para cada produto
  const upsert = [];
  const counters = {};
  for (const p of produtos) {
    const c = String(p.codigo_xbz || '').trim();
    // Código com '@' → forçar pendente_auditoria
    let status = c.includes('@') ? 'pendente_auditoria' : calcXbzStatus(mapa[c] || []);
    counters[status] = (counters[status] || 0) + 1;
    upsert.push({ codigo_xbz: c, status });
  }

  console.log('\n=== Status calculados ===');
  for (const [s, n] of Object.entries(counters).sort()) {
    console.log(`  ${s.padEnd(22)}: ${n}`);
  }
  console.log(`  ${'TOTAL'.padEnd(22)}: ${upsert.length}`);

  console.log('\nExecutando upsert em produtos_xbz (campo status)...');
  // Upsert em lotes de 50 para evitar timeout
  const BATCH = 50;
  let ok = 0, fail = 0;
  for (let i = 0; i < upsert.length; i += BATCH) {
    const batch = upsert.slice(i, i + BATCH);
    const { error } = await sb.from('produtos_xbz').upsert(batch, { onConflict: 'codigo_xbz' });
    if (error) {
      console.error(`  Lote ${i}–${i+BATCH}: ERRO — ${error.message}`);
      fail += batch.length;
    } else {
      ok += batch.length;
      process.stdout.write(`  Upsert: ${ok}/${upsert.length}\r`);
    }
  }
  console.log(`\nResultado: ${ok} ok | ${fail} falhas`);
  if (fail > 0) process.exit(1);
  console.log('Upsert concluído com sucesso.');
}

main().catch(err => { console.error('Erro fatal:', err); process.exit(1); });
