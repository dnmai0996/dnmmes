import test from 'node:test';
import assert from 'node:assert/strict';
import {civilProcessSummary, civilResultRows, civilRows, isCivilOrder, isCivilRoute, nameSortedActive, splitCivilLots, validateCivilLots} from '../public/modules/civil-domain.js';

const orders = [{id: 'order', kind: 'order', code: 'SO-001', title: '부싱', data: {order_type: 'CIVIL', qty: 384, shop_order_no: 'SHOP-001', heat_code: 'HEAT-002', due_date: '2026-12-01'}}];
const routes = [1, 2].map(n => ({id: 'r' + n, kind: 'routing', parent_id: 'order', state: 'RELEASED', code: '2611-000' + n, data: {daily: true, lot: '2611-000' + n, qty: 96}}));
const operations = routes.flatMap(route => [1, 2].map(seq => ({id: route.id + '-op' + seq, parent_id: route.id, title: '품질검사', state: 'DONE', data: {seq, op_code: String(seq * 10), qty: 96, confirmed_qty: seq === 1 ? 96 : 80}})));

test('civil identification preserves legacy daily routes while defence stays separate', () => {
  assert.equal(isCivilOrder(orders[0]), true);
  assert.equal(isCivilRoute(routes[0]), true);
  assert.equal(isCivilRoute({...routes[0], data: {}}), false);
  const rows = civilRows(routes, orders);
  assert.equal(rows[0].data.shop_order_no, 'SHOP-001');
  assert.equal(rows[0].data.heat_code, 'HEAT-002');
});

test('split has no fractional or lost quantities and validates per-lot edits', () => {
  assert.deepEqual(splitCivilLots(250, 96).map(lot => lot.qty), [96, 96, 58]);
  assert.deepEqual(validateCivilLots([{qty: 100}, {qty: 92}], 192).map(lot => lot.qty), [100, 92]);
  assert.throws(() => splitCivilLots(1.5, 1));
  assert.equal(splitCivilLots(500, 1).length, 500);
  assert.equal(validateCivilLots(splitCivilLots(500, 1), 500).length, 500);
  assert.throws(() => splitCivilLots(501, 1));
  assert.throws(() => validateCivilLots(Array.from({length:501},()=>({qty:1})), 501));
  assert.throws(() => validateCivilLots([{qty: 193}], 192));
  assert.throws(() => validateCivilLots([{qty: -1}], 192));
});

test('order aggregation counts order once and distinguishes repeated inspection stages', () => {
  const summary = civilProcessSummary(routes, operations, orders, 'order');
  assert.equal(summary.groups.length, 1);
  assert.equal(summary.groups[0].order.data.qty, 384);
  assert.equal(summary.groups[0].planned, 192);
  assert.equal(summary.columns.length, 2);
  assert.deepEqual([...summary.groups[0].quantities.values()].map(row => row.total), [192, 160]);
  const cancelled = {...routes[1], state: 'CANCELLED'};
  assert.equal(civilProcessSummary([routes[0], cancelled], operations, orders, 'order').groups[0].planned, 96);
  assert.equal(civilProcessSummary([routes[0], {...routes[1], state: 'TERMINATED'}], operations, orders, 'order').groups[0].planned, 192);
  assert.equal([...civilProcessSummary([routes[0], {...routes[1], state: 'TERMINATED'}], operations, orders, 'order').groups[0].quantities.values()][0].terminated, true);
});

test('legacy invalid start date does not break results and actual worker is used', () => {
  const logs = [{id: 'log', parent_id: operations[0].id, state: 'CONFIRMED', data: {start_at: 'invalid', employee_name: '김작업', total: 10}}];
  const rows = civilResultRows(routes, operations, logs, {employee: '김작업'});
  assert.equal(rows.length, 1);
  assert.equal(rows[0].workDate, '');
  assert.equal(civilResultRows(routes, operations, logs, {employee: '이작업'}).length, 0);
});

test('name-sorted choices accept server-filtered records and exclude explicit inactive masters', () => {
  const choices = [{id: 'z', title: '한설비', code: '2'}, {id: 'a', title: '가설비', code: '1', data: {department: '생산'}}, {id: 'x', title: '나설비', data: {active: false}}];
  assert.deepEqual(nameSortedActive(choices).map(row => row.id), ['a', 'z']);
});
