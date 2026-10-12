// XBZ data integrity helpers. No credentials, network requests or fabricated values.
// The public catalog is editorial until each supplier variation is verified.
export function normalizeXbzRecord(input, checkedAt) {
  if (!input || typeof input !== 'object') throw Error('Invalid XBZ record');
  if (input.fonte_confirmada !== true) throw Error('Supplier consultation evidence is required');
  const code = String(input.codigo_xbz || '').trim().toUpperCase();
  if (!/^[0-9]{4,6}[A-Z0-9-]*$/.test(code)) throw Error('Invalid XBZ code');
  const cost = Number(input.custo);
  if (!Number.isFinite(cost) || cost <= 0) throw Error('Supplier cost must be verified');
  if (input.disponivel !== true && input.disponivel !== false) throw Error('Supplier availability must be verified');
  const min = Number(input.venda_minima);
  const multiple = Number(input.multiplo);
  if (!Number.isInteger(min) || min < 1 || !Number.isInteger(multiple) || multiple < 1) throw Error('Minimum and multiple required');
  if (typeof checkedAt !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(checkedAt) || !/(Z|[+-]\d{2}:\d{2})$/.test(checkedAt) || Number.isNaN(Date.parse(checkedAt))) throw Error('Explicit timezone-aware verification timestamp required');
  if (Date.parse(checkedAt) > Date.now() + 60000) throw Error('Verification cannot be in the future');
  const surcharge = input.acrescimo_abaixo_minimo_pct == null ? null : Number(input.acrescimo_abaixo_minimo_pct);
  if (surcharge !== null && (!Number.isFinite(surcharge) || surcharge < 0 || surcharge > 100)) throw Error('Invalid surcharge percentage');
  const sku = String(input.sku_fornecedor || '').trim();
  const name = String(input.nome || '').trim();
  if (!sku || !name) throw Error('Supplier SKU and name required');
  return {
    codigo_xbz: code,
    sku_fornecedor: sku,
    nome: name,
    custo: cost,
    disponivel: input.disponivel,
    venda_minima: min,
    multiplo: multiple,
    acrescimo_abaixo_minimo_pct: surcharge,
    consultado_em: checkedAt,
    origem: 'Minha XBZ - consulta autenticada',
    status_validacao: 'verificado'
  };
}
export function canQuoteXbz(record, now = Date.now(), maxAgeHours = 6) {
  if (!record || record.status_validacao !== 'verificado' || record.disponivel !== true) return false;
  if (!(Number(record.custo) > 0) || !Number.isInteger(record.venda_minima) || record.venda_minima < 1 || !Number.isInteger(record.multiplo) || record.multiplo < 1) return false;
  if (!Number.isFinite(maxAgeHours) || maxAgeHours <= 0) return false;
  const age = now - Date.parse(record.consultado_em);
  return Number.isFinite(age) && age >= 0 && age <= maxAgeHours * 3600000;
}
export function quoteStatusXbz(record, now = Date.now()) {
  if (!record || record.status_validacao !== 'verificado') return 'Aguardando confirmacao XBZ';
  if (!record.disponivel) return 'Indisponivel na ultima consulta';
  return canQuoteXbz(record, now) ? 'Consulta recente - confirmar antes de fechar' : 'Consulta vencida - atualizar XBZ';
}
export function validateOrderQuantityXbz(record, quantity) {
  if (!record || !Number.isInteger(quantity) || quantity < 1) return { valid:false, reason:'Quantidade invalida' };
  if (quantity < record.venda_minima) return { valid:false, reason:'Abaixo da venda minima - confirmar acrescimo e autorizacao' };
  if ((quantity - record.venda_minima) % record.multiplo !== 0) return { valid:false, reason:'Quantidade fora do multiplo permitido' };
  return { valid:true, reason:null };
}
