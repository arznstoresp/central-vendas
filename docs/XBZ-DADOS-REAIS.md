# Dados reais XBZ - base de integração

Este módulo é uma fundação isolada e NÃO está conectado à interface nem ao Supabase. Não executa consulta à Minha XBZ.

## Fonte de verdade
Somente uma consulta autorizada na Minha XBZ pode preencher custo, disponibilidade, venda mínima e múltiplo. O catálogo público fornece apenas informações editoriais. Nunca inferir preço ou estoque a partir do HTML existente.

## Contrato
`normalizeXbzRecord(input, checkedAt)` exige codigo_xbz, custo positivo, disponivel booleano, venda_minima e multiplo inteiros positivos. Preserva SKU, nome, acréscimo abaixo do mínimo e horário da consulta. `canQuoteXbz` verifica a idade do registro (6h como limite provisório de alerta, não garantia do fornecedor). `quoteStatusXbz` retorna status seguro.

## Exemplo validado visualmente em 12/10/2026
Bolsa EVA 09318G-AZC, SKU X253219, custo exibido R$ 51,84, disponibilidade SIM, mínimo 5, múltiplo 1, acréscimo abaixo do mínimo +5%. Não confundir disponibilidade SIM com estoque reservado. Outras variações requerem dados próprios e horário individual de consulta.

## Próximas etapas
1. Definir método de obtenção autorizado dos dados de Minha XBZ; nunca coletar nem registrar credenciais em URLs ou logs.
2. Criar tabela de variações com chave única codigo_xbz e campos de origem/consultado_em, políticas de acesso restritas a administradores.
3. Implementar importador com validação, pré-visualização e relatório de erros; não sobrescrever os 30 produtos existentes.
4. Ligar botão Atualizar Preços XBZ somente quando houver integração real; jamais simular sucesso ou atualizar o horário sem consultar.
5. Vendedor deve ver status, não custos internos, e confirmar preços/estoque antes de fechar pedidos.
