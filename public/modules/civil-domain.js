import {keywordMatch, routingSort} from './routing-domain.js';

export const CIVIL_PAGES = new Set(['civilRouting', 'civilResults']);
const collator = new Intl.Collator('ko', {numeric: true, sensitivity: 'base'});

export function isCivilOrder(order) {
  return ['CIVIL', '민수'].includes(String(order?.data?.order_type || order?.data?.production_type || '').toUpperCase());
}

export function isCivilRoute(route) {
  return route?.kind === 'routing' && (route.data?.daily === true || isCivilOrder(route));
}

export function civilState(route) {
  if (route.state === 'CANCELLED') return '취소';
  if (route.data?.terminated || route.state === 'TERMINATED') return '불량 종결';
  return {DRAFT: '미배포', RELEASED: '진행', DONE: '완료', SUPERSEDED: '이전 개정'}[route.state] || route.state;
}

export function civilRouteBucket(route) {
  if (route.state === 'CANCELLED' || route.state === 'SUPERSEDED') return 'cancelled';
  if (route.state === 'DONE' || route.state === 'TERMINATED' || route.data?.terminated) return 'closed';
  return 'open';
}

export function civilRows(routes, orders, {query = '', state = 'open', orderId = ''} = {}) {
  const byOrder = new Map(orders.map(order => [order.id, order]));
  return routes.filter(isCivilRoute).map(route => {
    const order = byOrder.get(route.parent_id || route.data?.order_id);
    return {...route, data: {...route.data, shop_order_no: route.data?.shop_order_no || route.data?.shop_order || order?.data?.shop_order_no || order?.data?.shop_order || '',
      heat_code: route.data?.heat_code || order?.data?.heat_code || '',
      due_date: route.data?.due_date || order?.data?.due_date || ''}};
  }).filter(route => (!orderId || route.parent_id === orderId || route.data.order_id === orderId) &&
    (state === 'all' || civilRouteBucket(route) === state) && keywordMatch(route, query)).sort(routingSort);
}

export function positiveInteger(value, label = '수량') {
  const n = Number(value);
  if (!String(value ?? '').trim() || !Number.isSafeInteger(n) || n < 1) throw Error(label + '은 1 이상의 정수로 입력하세요.');
  return n;
}

export function splitCivilLots(total, perLot, prefix = '') {
  const quantity = positiveInteger(total, '계획수량');
  const size = positiveInteger(perLot, 'LOT당 수량');
  const count = Math.ceil(quantity / size);
  if (count > 500) throw Error('한 번에 생성할 수 있는 LOT는 최대 500개입니다. LOT당 수량을 늘리세요.');
  return Array.from({length: count}, (_, index) => ({
    lot: prefix ? prefix.trim() + '-' + String(index + 1).padStart(3, '0') : '',
    qty: Math.min(size, quantity - index * size)
  }));
}

export function validateCivilLots(lots, remaining) {
  if (!Array.isArray(lots) || !lots.length || lots.length > 500) throw Error('LOT를 1~500개 작성하세요.');
  const cleaned = lots.map((lot, i) => ({...lot, lot: String(lot.lot || '').trim(), qty: positiveInteger(lot.qty, (i + 1) + '번째 LOT 수량')}));
  const names = cleaned.map(lot => lot.lot).filter(Boolean);
  if (names.length !== new Set(names).size) throw Error('LOT 번호가 중복되었습니다. 각 LOT 번호를 확인하세요.');
  if (cleaned.some(lot => lot.lot.length > 100)) throw Error('LOT 번호는 100자 이내로 입력하세요.');
  const total = cleaned.reduce((sum, lot) => sum + lot.qty, 0);
  if (!Number.isSafeInteger(total) || total > Number(remaining)) throw Error('LOT 수량 합계가 수주의 계획 가능 수량을 초과합니다.');
  return cleaned;
}

export function civilOperationRows(operations, routeId) {
  return operations.filter(op => op.parent_id === routeId).sort((a, b) => Number(a.data?.seq || 0) - Number(b.data?.seq || 0));
}

export function civilResultRows(routes, operations, logs, {query = '', routeId = '', date = '', employee = ''} = {}) {
  const routeById = new Map(routes.filter(isCivilRoute).map(route => [route.id, route]));
  const opById = new Map(operations.filter(op => routeById.has(op.parent_id)).map(op => [op.id, op]));
  return logs.flatMap(log => {
    const operation = opById.get(log.parent_id);
    if (!operation) return [];
    const route = routeById.get(operation.parent_id);
    if (routeId && route.id !== routeId) return [];
    const started = Date.parse(log.data?.start_at || '');
    const workDate = log.data?.work_date || (Number.isFinite(started) ? new Date(started + 32400000).toISOString().slice(0, 10) : '');
    if (date && date !== workDate) return [];
    if (employee && log.data?.employee_id !== employee && log.data?.profile_id !== employee && log.data?.employee_name !== employee) return [];
    const row = {log, operation, route, workDate};
    return keywordMatch(row, query) ? [row] : [];
  }).sort((a, b) => b.workDate.localeCompare(a.workDate) || collator.compare(a.route.code, b.route.code) || Number(a.operation.data.seq) - Number(b.operation.data.seq));
}

export function nameSortedActive(records) {
  return records.filter(record => (record.kind ? record.data?.active === true : record.active !== false && record.data?.active !== false) && !['INACTIVE', 'CANCELLED'].includes(record.state))
    .sort((a, b) => collator.compare(a.title || '', b.title || '') || collator.compare(a.code || '', b.code || ''));
}

export function civilProcessSummary(routes, operations, orders = [], mode = 'lot') {
  const orderById = new Map(orders.map(order => [order.id, order]));
  const visible = new Set(routes.map(route => route.id));
  const terminated = new Set(routes.filter(route => route.state === 'TERMINATED').map(route => route.id));
  const relevant = operations.filter(operation => visible.has(operation.parent_id));
  const keyFor = operation => [operation.data.seq, operation.data.op_code || '', operation.title].join('|');
  const columns = [...new Map(relevant.map(operation => [keyFor(operation), operation])).entries()]
    .map(([key, operation]) => ({key, code: operation.data.op_code, name: operation.title, seq: Number(operation.data.seq || 0)}))
    .sort((a, b) => a.seq - b.seq || collator.compare(a.code, b.code) || collator.compare(a.name, b.name));
  const groups = new Map();
  const routeGroups = new Map();
  for (const route of routes) {
    const orderId = route.parent_id || route.data.order_id;
    const order = orderById.get(orderId);
    const key = mode === 'order' ? orderId || route.id : route.id;
    if (!groups.has(key)) groups.set(key, {key, order, routes: [], quantities: new Map(), planned: 0});
    const group = groups.get(key);
    group.routes.push(route);
    if (!['CANCELLED', 'SUPERSEDED'].includes(route.state)) group.planned += Number(route.data.qty || 0);
    routeGroups.set(route.id, group);
  }
  for (const operation of relevant) {
    const group = routeGroups.get(operation.parent_id);
    const key = keyFor(operation);
    const previous = group.quantities.get(key) || {total: 0, pending: false, terminated: false, complete: true, count: 0};
    group.quantities.set(key, {total: previous.total + Number(operation.data.confirmed_qty || 0),
      pending: previous.pending || operation.state === 'PENDING', terminated: previous.terminated || operation.state === 'TERMINATED' || terminated.has(operation.parent_id), complete: previous.complete && operation.state === 'DONE', count: previous.count + 1});
  }
  return {columns, groups: [...groups.values()]};
}
