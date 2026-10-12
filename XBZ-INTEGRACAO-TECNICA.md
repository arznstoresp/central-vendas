# XBZ-INTEGRACAO-TECNICA.md
### Documentação técnica — Integração de produtos XBZ na Central de Vendas ArznStoreSP
**Gerado em:** 2026-10-12 | **Repositório:** arznstoresp/central-vendas | **Branch:** main

---

## A. Como os 30 SKUs foram obtidos de verdade

### Método utilizado: curadoria manual assistida por IA

Os 30 SKUs **não foram obtidos por scraping, automação ou acesso à área restrita** (`minhaxbz.com.br`). O método foi:

1. **Navegação manual no site público** `https://www.xbzbrindes.com.br` — acesso humano ou por IA assistida em sessão de chat.
2. **Seleção manual de produtos** por categoria de brinde corporativo, com base em critérios editoriais (utilidade, giro, percepção de valor).
3. **Preenchimento direto no código-fonte** (`index.html`): nome, código XBZ, categoria, SKU interno, URL do produto, descrição e imagem.
4. **Imagens obtidas do site público da XBZ** e convertidas para base64 JPEG antes de serem embutidas no HTML.
5. **Descrições** copiadas ou parafraseadas das páginas de produto do site público XBZ.
6. **Preços não foram consultados** — os campos `custoInterno`, `precoBase` e `margem` estão vazios em todos os 30 produtos.

> **Evidência no código:** O campo `observacaoInterna` de cada produto contém frases como `"equivalente real XBZ para caneta corporativa"`, indicando curadoria assistida. Quatro produtos têm notas de substituição (p11, p15, p25, p30), o que confirma decisão editorial manual: nesses casos o produto original da categoria não existia na XBZ e foi substituído por um equivalente disponível.

### O que foi verificado vs. o que não foi

| Item | Status |
|---|---|
| Código XBZ (codigoXbz) | ✅ Verificável — corresponde ao path da URL pública (`xbzbrindes.com.br/{codigo}`) |
| Nome do produto | ✅ Baseado no site público |
| Descrição do produto | ✅ Baseada no site público |
| Imagem do produto | ✅ Obtida do site público, embutida como base64 JPEG |
| Preço / custo XBZ | ❌ NÃO VERIFICADO — campos vazios, sem consulta à Minha XBZ |
| Disponibilidade real | ❌ NÃO VERIFICADO — campo `minQtd` e `prazo` preenchidos como "Sob consulta" |
| Dados de venda mínima e múltiplos | ❌ NÃO VERIFICADO |

---

## B. Evidências técnicas no código

### Arquivo principal
```
/index.html  (único arquivo da aplicação — ~880KB, single-file HTML)
```

### Localização do catálogo no código

```javascript
// Linha ~1014 do index.html
var PRODUTOS = [
  { id:'p01', nome:'Caneta Metal', cat:'Escritório', sku:'ESC001',
    codigoXbz:'15530', fornecedor:'XBZ Brindes',
    linkFornecedor:'https://www.xbzbrindes.com.br/15530',
    imagem:'data:image/jpeg;base64,...',
    desc:'Caneta metal com acabamento emborrachado...',
    indicado:['Escritórios','Treinamentos','Feiras','Onboarding'],
    personalizacoes:['Gravação a laser','Impressão UV'],
    minQtd:'Sob consulta', prazo:'Sob consulta',
    nivel:'baixo', status:'venda-rapida',
    args:'Boa opção para prospecção...',
    observacaoInterna:'equivalente real XBZ para caneta corporativa',
    custoInterno:'', precoBase:'', margem:'',
    visivelVendedor:true },
  // ... 29 outros produtos
];
window.PRODUTOS = PRODUTOS;  // linha ~1046
```

### Campos do modelo de dados

| Campo | Tipo | Preenchido? | Origem |
|---|---|---|---|
| `id` | string (`p01`–`p30`) | ✅ todos | Gerado sequencialmente |
| `nome` | string | ✅ todos | Site público XBZ |
| `cat` | string | ✅ todos | Categorização manual |
| `sku` | string (interno) | ✅ todos | Gerado internamente (`ESC001`, `COR001`…) |
| `codigoXbz` | string | ✅ todos | Código do produto no site XBZ |
| `fornecedor` | string | ✅ todos | Sempre `'XBZ Brindes'` |
| `linkFornecedor` | URL | ✅ todos | `https://www.xbzbrindes.com.br/{codigoXbz}` |
| `imagem` | base64 JPEG | ✅ todos | Foto do site XBZ, embutida no HTML |
| `desc` | string | ✅ todos | Site público XBZ |
| `indicado` | array | ✅ todos | Curadoria manual |
| `personalizacoes` | array | ✅ todos | Curadoria manual |
| `minQtd` | string | ⚠️ "Sob consulta" | NÃO VERIFICADO |
| `prazo` | string | ⚠️ "Sob consulta" | NÃO VERIFICADO |
| `nivel` | string (`baixo`/`medio`) | ✅ todos | Curadoria manual |
| `status` | string | ⚠️ parcial | 11 com `venda-rapida`, 19 sem |
| `args` | string | ✅ todos | Gerado por IA |
| `observacaoInterna` | string | ✅ todos | Notas de curadoria |
| `custoInterno` | number | ❌ vazio | NÃO PREENCHIDO |
| `precoBase` | number | ❌ vazio | NÃO PREENCHIDO |
| `margem` | number | ❌ vazio | NÃO PREENCHIDO |
| `visivelVendedor` | boolean | ✅ todos | Sempre `true` |

### Tabela Supabase: `precos_xbz`

A aplicação lê (nunca escreve) essa tabela para sincronizar preços:

```sql
-- Colunas usadas pelo app:
codigo_xbz   TEXT    -- corresponde ao campo codigoXbz do produto
preco        NUMERIC -- custo unitário
disponivel   TEXT    -- 'SIM' ou 'NAO'
```

A tabela **não é populada pela aplicação**. Deve ser alimentada manualmente ou por script externo. A função de sync só lê:

```javascript
// Linha ~1391
async function syncXbzPrices(showToast) {
  var r = await sb.from('precos_xbz')
    .select('codigo_xbz,preco,disponivel')
    .eq('disponivel','SIM');
  // Atualiza prod.custoInterno e localStorage — nunca grava no Supabase
}
```

### Histórico Git — quando os produtos foram inseridos

Os 30 produtos estão presentes **desde o commit mais antigo do repositório** (`3eab7a0`, gerado em sessão anterior de chat). Não há commit de "importação" separado — os produtos foram incluídos diretamente no HTML na construção inicial do catálogo.

---

## C. Como reproduzir o procedimento para 100+ SKUs

### Pré-requisitos

- Acesso humano a `https://www.xbzbrindes.com.br` (sem automação — o site usa Cloudflare)
- Conta autorizada em `https://minhaxbz.com.br` para consulta de preços reais
- Editor de código ou planilha para montar os dados antes de inserir no HTML

### Passo a passo verificável

#### Etapa 1 — Seleção de produtos (site público)

Navegar manualmente em `https://www.xbzbrindes.com.br` e, para cada produto selecionado, anotar:

```
Código XBZ:      [aparece na URL, ex: xbzbrindes.com.br/15530]
Nome do produto: [título da página]
Descrição:       [texto descritivo da página]
URL da imagem:   [src da foto principal — normalmente CDN da XBZ]
```

Priorizar categorias corporativas: canetas, copos/garrafas, mochilas/sacolas, cadernos, tecnologia, kits.

#### Etapa 2 — Consulta de preços (Minha XBZ)

1. Acessar `https://minhaxbz.com.br` com login autorizado
2. Ir em **Consulta de Produtos**
3. Informar o código no campo **Produto**, qtd = 1, clicar em **Buscar Produtos**
4. Anotar: `preco`, `disponivel`, `venda_minima`, `multiplo`

> ⚠️ Não tente automatizar essa etapa — requer sessão autenticada + proteção anti-bot.

#### Etapa 3 — Download das imagens

Para cada produto, baixar a foto principal e converter para base64:

```bash
# Bash (Linux/Mac)
curl -o produto.jpg "https://[URL-DA-IMAGEM-XBZ]"
base64 -w 0 produto.jpg | sed 's/^/data:image\/jpeg;base64,/' > produto_b64.txt
```

Ou em Python:
```python
import base64
with open('produto.jpg','rb') as f:
    b64 = 'data:image/jpeg;base64,' + base64.b64encode(f.read()).decode()
```

> ⚠️ As imagens embutidas como base64 aumentam significativamente o tamanho do `index.html`. Com 100 produtos, o arquivo pode ultrapassar 2MB. Avaliar migração para URLs externas (Supabase Storage) antes de ampliar.

#### Etapa 4 — Montar o JSON do produto

Modelo de registro para copiar e adaptar:

```javascript
{
  id: 'p31',                         // próximo ID sequencial
  nome: 'Nome Exato do Produto',
  cat: 'Corporativo',                // categoria do catálogo
  sku: 'COR005',                     // SKU interno ArznStoreSP (categoria + sequencial)
  codigoXbz: '12345',                // código do site XBZ
  fornecedor: 'XBZ Brindes',
  linkFornecedor: 'https://www.xbzbrindes.com.br/12345',
  imagem: 'data:image/jpeg;base64,...',  // base64 da foto
  desc: 'Descrição do produto...',
  indicado: ['Empresas','Eventos'],
  personalizacoes: ['Serigrafia','Gravação a laser'],
  minQtd: '50',                      // preencher com dado real da Minha XBZ
  prazo: '10 dias úteis',            // preencher com dado real
  nivel: 'medio',                    // baixo | medio | alto
  status: 'venda-rapida',            // opcional
  args: 'Argumento de venda...',
  observacaoInterna: 'produto verificado na Minha XBZ em AAAA-MM-DD',
  custoInterno: 12.50,               // preço real da Minha XBZ
  precoBase: '',
  margem: '',
  visivelVendedor: true
}
```

#### Etapa 5 — Inserir no array PRODUTOS

Abrir `index.html`, localizar a linha `var PRODUTOS = [` (linha ~1014) e inserir o novo objeto antes do `];`. Manter o padrão de IDs sequenciais (`p31`, `p32`...) e SKUs por categoria.

#### Etapa 6 — Popular tabela `precos_xbz` no Supabase

```sql
-- Executar no SQL Editor do Supabase para cada produto com preço verificado
INSERT INTO public.precos_xbz (codigo_xbz, preco, disponivel)
VALUES ('12345', 12.50, 'SIM')
ON CONFLICT (codigo_xbz) DO UPDATE SET preco = EXCLUDED.preco, disponivel = EXCLUDED.disponivel;
```

#### Etapa 7 — Deduplicação

Antes de inserir, verificar duplicatas pelo `codigoXbz`:

```javascript
// Verificar no console do browser
PRODUTOS.filter(p => p.codigoXbz === '12345')
// deve retornar array vazio para confirmar que o código não existe
```

---

## D. Situação atual — o que funciona e o que falta

### ✅ Implementado e funcionando

| Componente | Arquivo | Linha |
|---|---|---|
| Catálogo com 30 produtos hardcoded | `index.html` | ~1014 |
| Renderização do catálogo com filtro por categoria | `index.html` | ~2590 |
| Modal de detalhe do produto | `index.html` | ~1770 |
| Link para produto no site XBZ | `index.html` | ~1779 |
| Sync de preços da tabela Supabase | `index.html` | ~1391 |
| Cálculo de preço de venda com margem | `index.html` | ~1856 |
| Botão "Sync XBZ" manual com timestamp | `index.html` | ~904, ~3472 |
| Tabela `precos_xbz` no Supabase com RLS | `supabase-migration.sql` | Passo 10 |

### ❌ Não implementado

| Componente | Status |
|---|---|
| Robô/scraper de coleta automática | Não existe |
| Edge Function para atualização agendada de preços | Não existe |
| Tabela de produtos no Supabase (os produtos vivem no HTML) | Não existe |
| Preenchimento real de `custoInterno` nos 30 produtos | Todos vazios |
| Venda mínima, múltiplo e prazo reais | Todos "Sob consulta" |
| Deduplicação automática ao inserir | Não existe |
| Upload de imagens para Supabase Storage | Não existe — imagens em base64 no HTML |

---

## Referências de arquivos

```
arznstoresp/central-vendas/
├── index.html                    ← aplicação completa (único arquivo ~880KB)
│   ├── linha ~904                ← painel XBZ Brindes (UI do fornecedor)
│   ├── linha ~1014               ← var PRODUTOS = [...] (catálogo hardcoded)
│   ├── linha ~1046               ← window.PRODUTOS = PRODUTOS
│   ├── linha ~1373               ← chamada inicial syncXbzPrices(false)
│   ├── linha ~1391               ← async function syncXbzPrices()
│   ├── linha ~1770               ← renderização do modal de produto
│   ├── linha ~2590               ← renderCatalog() com filtro por categoria
│   └── linha ~3472               ← exibição do timestamp de última sync
├── supabase-migration.sql        ← DDL de segurança (branch security/supabase-auth)
└── deploy_fix.ps1                ← script de deploy Vercel
```

## Dependências externas

| Dependência | Uso |
|---|---|
| Supabase JS Client v2 (CDN) | Autenticação e acesso ao banco |
| Tabela `precos_xbz` (Supabase) | Leitura de preços para sync |
| Site público `xbzbrindes.com.br` | Fonte original dos dados dos produtos |
| `minhaxbz.com.br` | Única fonte de preços reais (acesso manual autenticado) |

---

*Documento gerado por Claude Sonnet 4.6 com base em inspeção direta do código-fonte do repositório. Informações marcadas como NÃO VERIFICADO não puderam ser confirmadas sem acesso ao banco de produção ou à conta Minha XBZ.*
