# Catálogo XBZ — pipeline inicial
O workflow `.github/workflows/xbz-catalog.yml` valida `data/xbz-products.json` semanalmente e permite importar manualmente **somente produtos novos**, sempre com status `rascunho`. O arquivo começa vazio. Nenhuma coleta no site da XBZ está implementada. O job agendado NÃO grava dados.

## Configuração
No GitHub, em Settings > Secrets and variables > Actions, cadastrar:
- `SUPABASE_URL`: URL pública do projeto.
- `SUPABASE_SERVICE_ROLE_KEY`: chave privada Supabase (nunca no HTML, código ou logs).

Antes de executar uma importação, preencher `data/xbz-products.json` com registros reais e verificados da XBZ:
```json
[{"codigo_xbz":"CODIGO_REAL","nome":"Nome real","modelo":"Modelo","categoria":"Canetas","descricao":"Descrição verificada","imagem_url":"https://...","link_fornecedor":"https://www.xbzbrindes.com.br/..."}]
```
Exemplo acima é apenas estrutura, não um produto real. Executar Actions > XBZ - validar e importar catálogo > Run workflow; escolher `importar=true` apenas após revisar dados.

## Segurança e limites
- A tabela Supabase `produtos_xbz` possui RLS; service role é exclusiva do ambiente GitHub Actions.
- Registros existentes, inclusive validados, não são sobrescritos.
- Os novos registros permanecem em rascunho e não aparecem automaticamente aos vendedores.
- Não é um scraper. Coleta automática depende de fonte autorizada (API, feed ou acesso permitido), mapeamento e verificação dos termos do fornecedor.
- O catálogo do frontend ainda precisa ser conectado à tabela; este pipeline sozinho não adiciona produtos à tela.
