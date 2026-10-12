// XBZ data integrity helpers. No credentials, network requests or fabricated values.
// The public catalog is editorial until each supplier variation is verified.
export function normalizeXbzRecord(input, checkedAt = new Date().toISOString()) {
  if (!input || typeof input !== 'object') throw Error('Invalid XBZ record');
  const code = String(input.codigo_xbz || '').trim().toUpperCase();
  if (!/^[0-9]{4,6}[A-Z0-9-]*$/.test(code)) throw Error('Invalid XBZ code');
  const cost = Number(input.custo);
  if (!Number.isFinite(cost) || cost <= 0) throw Error('Supplier cost must be verified');
  if (input.disponivel !== true && input.disponivel !== false) throw Error('Supplier availability must be verified');
  const min = Number(input.venda_minima);
  const multiple = Number(input.multiplo);
  if (!Number.isInteger(min) || min < 1 || !Number.isInteger(multiple) || multiple < 1) throw Error('Minimum and multiple required');
  if (!/^\d{4}-\d{2}-\d{2}T/.test(checkedAt) || Number.isNaN(Date.parse(checkedAt))) throw Error('Invalid verification timestamp');
  return {
    codigo_xbz: code,
    sku_fornecedor: String(input.sku_fornecedor || '').trim(),
    nome: String(input.nome || '').trim(),
    custo: cost,
    disponivel: input.disponivel,
    venda_minima: min,
    multiplo: multiple,
    acrescimo_abaixo_minimo_pct: input.acrescimo_abaixo_minimo_pct == null ? null : Number(input.acrescimo_abaixo_minimo_pct),
    consultado_em: checkedAt,
    origem: 'Minha XBZ - consulta autenticada',
    status_validacao: 'verificado'
  };
}
export function canQuoteXbz(record, now = Date.now(), maxAgeHours = 6) {
  if (!record || record.status_validacao !== 'verificado' || record.disponivel !== true) return false;
  if (!(Number(record.custo) > 0)) return false;
  const age = now - Date.parse(record.consultado_em);
  return Number.isFinite(age) && age >= 0 && age <= maxAgeHours * 3600000;
}
export function quoteStatusXbz(record, now = Date.now()) {
  if (!record || record.status_validacao !== 'verificado') return 'Aguardando confirmacao XBZ';
  if (!record.disponivel) return 'Indisponivel na ultima consulta';
  return canQuoteXbz(record, now) ? 'Consulta recente - confirmar antes de fechar' : 'Consulta vencida - atualizar XBZ';
}
