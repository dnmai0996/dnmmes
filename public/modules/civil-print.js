import {esc} from '../core.js';

const PAGE_ROWS = 18;
const dateFormatter = new Intl.DateTimeFormat('en-US', {
  timeZone: 'Asia/Seoul', year: '2-digit', month: '2-digit', day: '2-digit'
});
const text = value => esc(value ?? '').replaceAll('\n', '<br>');
const unique = values => [...new Set(values.filter(value => value !== null && value !== undefined && String(value).trim()))];

// Standard Code 128 element widths (bar, space, ...). Code Set B preserves
// printable ASCII exactly; the weighted modulo-103 checksum is mandatory.
const CODE128_WIDTHS = [
  '212222', '222122', '222221', '121223', '121322', '131222', '122213', '122312', '132212', '221213',
  '221312', '231212', '112232', '122132', '122231', '113222', '123122', '123221', '223211', '221132',
  '221231', '213212', '223112', '312131', '311222', '321122', '321221', '312212', '322112', '322211',
  '212123', '212321', '232121', '111323', '131123', '131321', '112313', '132113', '132311', '211313',
  '231113', '231311', '112133', '112331', '132131', '113123', '113321', '133121', '313121', '211331',
  '231131', '213113', '213311', '213131', '311123', '311321', '331121', '312113', '312311', '332111',
  '314111', '221411', '431111', '111224', '111422', '121124', '121421', '141122', '141221', '112214',
  '112412', '122114', '122411', '142112', '142211', '241211', '221114', '413111', '241112', '134111',
  '111242', '121142', '121241', '114212', '124112', '124211', '411212', '421112', '421211', '212141',
  '214121', '412121', '111143', '111341', '131141', '114113', '114311', '411113', '411311', '113141',
  '114131', '311141', '411131', '211412', '211214', '211232', '2331112'
];

export function civilLotBarcode(value) {
  const lot = String(value ?? '');
  if (!/^[\x20-\x7e]{1,60}$/.test(lot)) return '';
  const values = [...lot].map(character => character.charCodeAt(0) - 32);
  const checksum = values.reduce((sum, code, index) => sum + code * (index + 1), 104) % 103;
  let position = 10;
  const bars = [];
  for (const code of [104, ...values, checksum, 106]) {
    [...CODE128_WIDTHS[code]].forEach((width, index) => {
      if (index % 2 === 0) bars.push(`<rect x="${position}" y="0" width="${width}" height="32"/>`);
      position += Number(width);
    });
  }
  const width = position + 10;
  const moduleWidth = lot.length > 45 ? 0.25 : 0.33;
  return `<svg xmlns="http://www.w3.org/2000/svg" class="civil-lot-svg" role="img" aria-label="LOT ${esc(lot)}" viewBox="0 0 ${width} 32" width="${(width * moduleWidth).toFixed(2)}mm" height="8mm" preserveAspectRatio="none"><rect width="${width}" height="32" fill="white"/><g fill="black">${bars.join('')}</g></svg>`;
}

function printDate(value, fullYear = false) {
  if (!value) return '';
  const literal = String(value).match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (literal) return `${literal[2]}/${literal[3]}/${fullYear ? literal[1] : literal[1].slice(2)}`;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  if (fullYear) return new Intl.DateTimeFormat('en-US', {
    timeZone: 'Asia/Seoul', year: 'numeric', month: '2-digit', day: '2-digit'
  }).format(date);
  return dateFormatter.format(date);
}

function finiteQuantity(value) {
  if (value === null || value === undefined || value === '') return null;
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : null;
}

function operationResult(operation, logs, events) {
  const confirmed = logs.filter(log => log.parent_id === operation.id && log.state === 'CONFIRMED');
  const completed = events.filter(event => event.parent_id === operation.id &&
    event.state !== 'CANCELLED' && event.data?.state === 'DONE').sort((a, b) =>
      String(a.data?.date || a.created_at || '').localeCompare(String(b.data?.date || b.created_at || '')));
  const records = [...confirmed, ...completed].sort((a, b) =>
    String(a.data?.end_at || a.data?.date || a.created_at || '').localeCompare(
      String(b.data?.end_at || b.data?.date || b.created_at || '')));
  const last = records.at(-1);
  const quantities = confirmed.map(log => finiteQuantity(log.data?.total));
  let quantity = null;
  if (quantities.length && quantities.every(value => value !== null)) {
    quantity = quantities.reduce((total, value) => total + value, 0);
  } else if (!confirmed.length && completed.length) {
    quantity = finiteQuantity(completed.at(-1).data?.qty);
  }
  return {
    quantity: quantity === null ? '' : quantity.toLocaleString('ko-KR'),
    date: printDate(last?.data?.work_date || last?.data?.end_at || last?.data?.date || last?.created_at),
    workers: unique(confirmed.map(log => log.data?.employee_name)).join(', '),
    equipment: unique(confirmed.map(log => log.data?.equipment_code)).join(', ')
  };
}

function pageGroups(operations) {
  const pages = [];
  let rows = [];
  let height = 0;
  for (const operation of operations) {
    const noteLength = Math.min(String(operation.data?.note || '').length, 150);
    const units = Math.max(1, Math.ceil(noteLength / 65));
    if (height + units > PAGE_ROWS && rows.length) {
      pages.push({rows, units: height});
      rows = [];
      height = 0;
    }
    rows.push(operation);
    height += units;
  }
  pages.push({rows, units: height});
  return pages;
}

function sklCells(rows) {
  const cells = Array(rows.length).fill('');
  for (let index = 0; index < rows.length; index += 1) {
    const code = rows[index].data?.skl_op_no || '';
    let span = 1;
    while (code && index + span < rows.length && rows[index + span].data?.skl_op_no === code) span += 1;
    cells[index] = `<td rowspan="${span}" class="civil-skl">${text(code)}</td>`;
    index += span - 1;
  }
  return cells;
}

function headerMarkup(route) {
  const data = route.data || {};
  const fields = [
    ['LOT NO', data.lot], ['SHOP ORDER', data.shop_order_no || data.shop_order || data.production_no], ['INPUT DATE', printDate(data.input_date, true)],
    ['PWI NO', data.pwi_no], ['HEAT CODE', data.heat_code], ['MATERIAL', data.material_spec],
    ['MODEL', data.model || data.project], ['PART NUMBER', data.part_no], ['PART NAME', route.title]
  ];
  const lines = [];
  for (let index = 0; index < fields.length; index += 3) {
    lines.push(`<tr>${fields.slice(index, index + 3).map(([label, value]) =>
      `<th>${label}</th><td>${text(value)}</td>`).join('')}</tr>`);
  }
  const barcode = civilLotBarcode(data.lot);
  const wide = String(data.lot || '').length > 12 && barcode ? ' civil-wide-barcode' : '';
  return `<div class="civil-title${wide}"><span class="civil-document-code">${barcode || text(route.code)}</span><h1>ROUTING SHEET</h1></div>
    <table class="civil-meta"><colgroup>${'<col class="civil-label"><col class="civil-value">'.repeat(3)}</colgroup><tbody>${lines.join('')}</tbody></table>`;
}

function revisionMarkup(route) {
  const data = route.data || {};
  const revisions = Array.isArray(data.revisions) ? data.revisions : [{
    number: data.document_revision || '', content: data.revision_note || '', date: data.revision_date || ''
  }];
  const rows = revisions.length ? revisions : [{}];
  return `<table class="civil-revision"><colgroup><col class="civil-rev-number"><col class="civil-rev-content"><col class="civil-rev-date"><col><col><col></colgroup>
    <thead><tr>${['REV NO.', 'REVISION CONTENTS', 'REVISION DATE', 'PLANNER', 'REVIEW', 'APPROVAL'].map(label => `<th>${label}</th>`).join('')}</tr></thead>
    <tbody>${rows.map(revision => `<tr><td>${text(revision.number)}</td><td>${text(revision.content)}</td><td>${printDate(revision.date, true)}</td><td></td><td></td><td></td></tr>`).join('')}
    ${Array.from({length: Math.max(0, 4 - rows.length)}, () => `<tr>${'<td></td>'.repeat(6)}</tr>`).join('')}</tbody></table>`;
}

/** Printable civil route body. Only confirmed activity supplies quantities and worker names. */
export function civilRoutingMarkup(route, operations, logs = [], events = []) {
  const sorted = operations.filter(operation => operation.parent_id === route.id)
    .sort((a, b) => Number(a.data?.seq || 0) - Number(b.data?.seq || 0));
  const groups = pageGroups(sorted);
  const details = [];
  const output = groups.map((group, pageIndex) => {
    const skl = sklCells(group.rows);
    const rows = group.rows.map((operation, index) => {
      const data = operation.data || {};
      const result = operationResult(operation, logs, events);
      let note = String(data.note || '');
      if (note.length > 150) {
        details.push({code: data.op_code || operation.code, title: operation.title, note});
        note = `${note.slice(0, 150)}\n[작업내용 상세 ${details.length}]`;
      }
      return `<tr>${skl[index]}<td>${text(data.op_code || operation.code)}</td><td>${text(operation.title)}</td>
        <td>${text(result.equipment || data.equipment_code || data.equipment_label)}</td><td class="civil-job">${text(note)}</td>
        <td>${text(data.inspection_code)}</td><td>${result.quantity}</td><td>${result.date}</td><td>${text(result.workers)}</td><td></td></tr>`;
    }).join('');
    const blanks = Array.from({length: Math.max(1, PAGE_ROWS - group.units)}, () =>
      `<tr class="civil-blank">${'<td></td>'.repeat(10)}</tr>`).join('');
    const terminated = route.state === 'TERMINATED' ? `<p class="civil-terminated">불량 종결 · ${text(route.data?.termination_reason || route.data?.terminate_reason || route.data?.termination_note || '')}</p>` : '';
    return `<section class="civil-page">${headerMarkup(route)}${terminated}
      <table class="civil-steps"><colgroup>${['skl', 'code', 'name', 'machine', 'job', 'check', 'qty', 'date', 'worker', 'inspector'].map(name => `<col class="civil-col-${name}">`).join('')}</colgroup>
      <thead><tr><th>SKL<br><small>OP NO</small></th><th>공정번호<br>OPER NO.</th><th>공정명<br>OPER NAME</th><th>설비<br>MACHINE</th><th>작업 내용<br>JOB NAME</th><th>CODE</th><th>QTY</th><th>DATE<br><small>(MM/DD/YY)</small></th><th>OPER</th><th>INSP</th></tr></thead>
      <tbody>${rows}${blanks}</tbody></table>${revisionMarkup(route)}
      <div class="civil-footer"><span>F7031-03</span><strong>㈜ DNM</strong><span>${text(route.code)} · ${pageIndex + 1}/${groups.length}</span></div>
      <p class="civil-source-note">QTY 확정 누적 처리수량 · DATE 최종 확정 작업일 · 성명은 서명을 대체하지 않음 · 검사 및 결재 확인란은 서명용</p>
      ${route.data?.note ? `<p class="civil-route-note">${text(route.data.note)}</p>` : ''}</section>`;
  });
  if (details.length) {
    output.push(`<section class="civil-detail"><h2>ROUTING SHEET · 작업내용 상세</h2><p>${text(route.code)} / ${text(route.data?.lot)}</p>
      ${details.map((detail, index) => `<article><h3>${index + 1}. ${text(detail.code)} ${text(detail.title)}</h3><p>${text(detail.note)}</p></article>`).join('')}</section>`);
  }
  return output.join('');
}

let stylesheet;
function loadPrintStyles() {
  if (stylesheet) return stylesheet;
  stylesheet = new Promise((resolve, reject) => {
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = new URL('../civil-print.css', import.meta.url).href;
    link.onload = resolve;
    link.onerror = () => {
      link.remove();
      stylesheet = null;
      reject(new Error('민수 Routing 출력 양식을 불러오지 못했습니다. 다시 시도하세요.'));
    };
    document.head.append(link);
  });
  return stylesheet;
}

export async function printCivilRouting({route, operations, logs = [], events = [], order = null}) {
  await loadPrintStyles();
  const orderData = order?.data || {};
  const printable = {...route, title: route.title || orderData.part_name || '', data: {
    ...route.data,
    production_no: route.data?.production_no || orderData.production_no || '',
    shop_order_no: route.data?.shop_order_no || route.data?.shop_order || orderData.shop_order_no || orderData.shop_order || '',
    heat_code: route.data?.heat_code || orderData.heat_code || '',
    part_no: route.data?.part_no || orderData.part_no || '',
    model: route.data?.model || route.data?.project || orderData.project || ''
  }};
  document.querySelector('#printArea')?.remove();
  const area = document.createElement('section');
  area.id = 'printArea';
  area.className = 'civil-routing-print';
  area.innerHTML = civilRoutingMarkup(printable, operations, logs, events);
  document.body.append(area);
  await document.fonts?.ready;
  window.print();
}
