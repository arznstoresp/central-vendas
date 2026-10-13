# XBZ-CATALOGO-ARZN

Catálogo de produtos XBZ para a ArznStoreSP — Brindes e Personalizados.

## Conteúdo

| Arquivo | Descrição |
|---|---|
| `imagens/` | 148 fotografias oficiais XBZ em JPEG |
| `produtos.json` | 150 produtos com dados estruturados |
| `produtos.csv` | Mesmos dados em formato planilha |
| `imagens-pendentes.csv` | 2 produtos com imagem indisponível |
| `relatorio-validacao.md` | Relatório completo da coleta |

## Dados de cada produto (`produtos.json`)

```json
{
  "codigo_xbz": "09318G",
  "nome": "Bolsa EVA",
  "categoria": "Mochilas e Bolsas",
  "imagem_principal": "imagens/09318G.jpg",
  "imagens_adicionais": [],
  "link_fornecedor": "https://www.xbzbrindes.com.br/img/produtos/1/Bolsa-EVA-30643-1791571822.jpg",
  "custo": null,
  "estoque": null,
  "status_imagem": "validada"
}
```

## Categorias disponíveis

- Mochilas e Bolsas
- Sacolas
- Nécessaires e Estojos
- Papelaria e Escritório
- Bebidas e Térmicos
- Kits e Conjuntos
- Chaveiros e Acessórios
- Eletro e Tecnologia
- Casa e Decoração
- Higiene e Cuidados
- Esportes e Fitness
- Saúde e Bem-estar
- Viagem e Lazer
- Outros

## Estatísticas

- **150 produtos** no catálogo
- **148 com foto validada** (98,7%)
- **2 pendentes** (HTTP 500 no servidor XBZ)
- Fonte: [xbzbrindes.com.br](https://www.xbzbrindes.com.br/)

## Uso na Central de Vendas

As imagens são servidas como arquivos estáticos em `public/img/xbz/{codigo}.jpg`.  
Não utilizar base64 embutido no HTML — conforme instrução do projeto.

## Fornecedor

- Site: https://www.xbzbrindes.com.br/
- Área de download: https://www.xbzbrindes.com.br/download/
