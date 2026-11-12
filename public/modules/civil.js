import {$, all, area, btn, clock, closeModal, esc, exportCSV, input, message, modal, notice, num, pill, select, table} from './ui.js';
import {duration} from './domain.js';
import {permit} from './permissions.js';
import {blankStep, routeProgress} from './routing-domain.js';
import {mountSteps} from './step-editor.js';
import {civilOperationRows, civilProcessSummary, civilResultRows, civilRows, civilState, civilOrderChoices, isDeletedOrder, isCivilOrder, isCivilRoute, positiveInteger, splitCivilLots, validateCivilLots} from './civil-domain.js';
import {printCivilRouting} from './civil-print.js';

const today = () => new Date(Date.now() + 32400000).toISOString().slice(0, 10);
const stateOptions = [['open', '진행'], ['closed', '완료·불량 종결'], ['cancelled', '취소·이전 개정'], ['all', '전체']];
const orderLabel = order => [order.data?.shop_order_no || order.data?.shop_order || order.code, order.data?.part_no, order.title].filter(Boolean).join(' · ');
const dateLabel = date => date || '미정';
const civilButton = (action, label, id = '', style = 'secondary') => btn('civil:' + action, label, id, style);

export class CivilUI {
  constructor(main) {
    this.main = main;
    this.state = 'open';
    this.orderId = '';
    this.resultView = 'process';
    this.resultGroup = 'lot';
    this.resultDate = '';
    this.resultWorker = '';
    this.resultRoute = '';
    this.visibleResults = [];
    this.ticket = 0;
  }

  can(action = 'read', module = 'routing') {
    return permit(this.main.ctx, module, action);
  }

  require(action, module = 'routing') {
    if (!this.can(action, module)) throw Error('이 업무의 등록·수정 권한을 관리자에게 요청하세요.');
  }

  async load(page) {
    if (page === 'civilResults') return this.results();
    return this.routings();
  }

  async save(name, args) {
    const saved = await this.main.rpc(name, args);
    return this.main.refreshAfterSave(saved);
  }

  bindDialog(dialog) {
    let running = false;
    $('#v4form', dialog).addEventListener('click', async event => {
      const button = event.target.closest('[data-vaction]');
      if (!button || running) return;
      event.preventDefault();
      running = true;
      button.disabled = true;
      try {
        await this.main.action(button.dataset.vaction, button.dataset.id);
      } catch (error) {
        message(error.message);
      } finally {
        running = false;
        if (button.isConnected) button.disabled = false;
      }
    });
  }

  async routings() {
    const ticket = ++this.ticket;
    const [routes, orders] = await Promise.all([this.main.rec('routing'), this.main.rec('order')]);
    if (ticket !== this.ticket || this.main.page !== 'civilRouting') return;
    const civilOrders = civilOrderChoices(orders,routes);
    if(this.orderId&&!civilOrders.some(order=>order.id===this.orderId))this.orderId='';
    const rows = civilRows(routes, orders, {query: this.main.search, state: this.state, orderId: this.orderId});
    const create = this.can('create') ? civilButton('new', '민수 LOT 분할 작성', '', 'primary') : '';
    this.main.set(`<div class="card civil-page">${this.main.top(create)}
      <div class="filter-bar">${select('civilState', 'LOT 상태', stateOptions, this.state, 'id="civilState"')}
      ${select('civilOrder', '수주 / Shop Order', [['', '전체 수주'], ...civilOrders.map(order => [order.id, orderLabel(order)])], this.orderId, 'id="civilOrder"')}</div>
      ${table(['LOT 번호', 'Shop Order / Heat Code', '품번 / 품명', '작업 예정일 / 납기', 'LOT 수량', '상태', '관리'], this.main.pagedCells(rows, route => [
        civilButton('detail', route.data.lot || route.code, route.id), esc(route.data.shop_order_no || route.data.shop_order || route.data.production_no) + '<br>' + esc(route.data.heat_code || '—'),
        esc(route.data.part_no) + '<br>' + esc(route.title), esc(dateLabel(route.data.plan_date)) + '<br>' + esc(dateLabel(route.data.due_date)),
        num(route.data.qty), `<span class="pill p-${esc(route.state)}">${esc(civilState(route))}</span>`,
        civilButton('detail', '공정·배정', route.id) + civilButton('print', '민수 양식 출력', route.id)
      ]))}<div id="v4pager" class="pagination"></div></div>`);
    this.main.pageFooter(rows);
    $('#civilState').onchange = event => {this.state = event.target.value; this.main.pageNo = 1; this.routings().catch(error => message(error.message));};
    $('#civilOrder').onchange = event => {this.orderId = event.target.value; this.main.pageNo = 1; this.routings().catch(error => message(error.message));};
  }

  async routingForm(order = null) {
    this.require('create');
    if (!order) {
      const orders = civilOrderChoices(await this.main.rec('order'),[],{openOnly:true});
      if (!orders.length) return modal('민수 LOT 작성', notice('고객수주에서 생산 구분을 민수로 선택하고 수주를 먼저 등록하세요.'));
      return modal('LOT를 작성할 민수 수주 선택', select('order_id', '수주 / Shop Order', [['', '수주 선택'], ...orders.map(row => [row.id, orderLabel(row)])], '', 'required'), async form => {
        const selected = orders.find(row => row.id === form.order_id);
        if (!selected) throw Error('민수 수주를 선택하세요.');
        setTimeout(() => this.routingForm(selected).catch(error => message(error.message)), 0);
      }, '분할 계획 작성');
    }
    order=await this.main.s.one(order.id);
    if(isDeletedOrder(order)||order.state!=='OPEN')throw Error('삭제·마감된 수주에는 새 LOT를 작성할 수 없습니다. 현재 수주를 다시 선택하세요.');
    const [plan, refs, templates] = await Promise.all([
      this.main.rpc('dnm_v410_plan_info', {p_order: order.id}), this.main.refData(), this.main.rec('route_template')
    ]);
    if (Number(plan.remaining) <= 0) return modal('민수 LOT 계획 완료', notice('이 수주는 계획 가능 수량이 0개입니다. 기존 LOT의 수량과 상태를 확인하세요.'));
    const part = String(order.data.part_no || '').trim();
    const matched = templates.filter(row => (row.data.part_no || row.code) === part && row.data.active !== false && row.state !== 'INACTIVE' && row.data.review_required === false && row.data.steps?.length);
    const sources = [{id: '', title: '신규 공정 직접 작성', steps: [{...blankStep(), independent: false}]}, ...matched.map(row => ({id: row.id, title: row.code + ' · ' + row.title, steps: row.data.steps, version: row.version}))];
    let source = sources[0];
    let editor;
    let quantities = [];
    let previewError = '';
    const managers = (this.main.ctx.people || []).filter(person => person.production || person.role === 'admin');
    const defaultManager = managers.some(person => person.id === this.main.ctx.profile.id) ? this.main.ctx.profile.id : '';
    modal('민수 LOT 자동 분할 · ' + order.code, `
      <div class="detail-grid">${[['Shop Order', order.data.shop_order_no || order.data.shop_order || order.code], ['Heat Code', order.data.heat_code || '—'], ['품번', part], ['수주수량', num(order.data.qty)], ['기존 계획수량', num(plan.allocated)], ['계획 가능 수량', num(plan.remaining)]].map(([label, value]) => `<div><small>${esc(label)}</small><strong>${esc(value)}</strong></div>`).join('')}</div>
      <div class="fields">${input('total_qty', '이번 계획수량', plan.remaining, 'number', `required min="1" step="1" max="${Number(plan.remaining)}" id="civilTotal"`)}
      ${input('lot_qty', 'LOT당 기본 수량', plan.remaining, 'number', 'required min="1" step="1" id="civilSize"')}
      ${input('plan_date', '작업 예정일', today(), 'date', 'required')}${select('manager_id', '담당 생산관리자', [['', '선택하세요'], ...managers.map(person => [person.id, person.name])], defaultManager, 'required')}</div>
      <div class="civil-preview-header"><h3>LOT 분할 미리보기</h3><button type="button" class="secondary" id="civilRecalculate">분할 다시 계산</button></div>
      <p class="muted">LOT 번호는 저장 시 월별 공통 순번으로 부여됩니다. 예외 납품수량은 각 행에서 수정하세요.</p>
      <div id="civilLotPreview" class="civil-lot-preview"></div><p id="civilLotSummary" aria-live="polite"></p>
      ${select('template_id', '품번 일치 공정 불러오기', sources.map(row => [row.id, row.title]), '', 'id="civilSource"')}
      ${notice('계획 단계에서 설비·작업자를 선택할 수 있으며, 실제 작업일보 등록 시 변경할 수 있습니다. 순서에 관계없이 작업할 공정은 순서 무관에 체크하세요.')}
      <div class="fields">${input('input_date', '투입일', today(), 'date')}${input('pwi_no', 'PWI No', order.data.pwi_no || '')}${input('model', 'MODEL', order.data.model || order.data.project || '')}${input('material_spec', 'MATERIAL', order.data.material_spec || '')}</div>
      <div id="civilSteps" class="civil-sequence civil-step-editor"></div>${area('note', '작업계획 메모', '', 'maxlength="2000"')}
      <label class="check"><input type="checkbox" name="reviewed" required>LOT 수량과 공정을 확인했습니다.</label>`, async (form, key) => {
      if (form.reviewed !== 'on') throw Error('LOT 수량과 공정을 확인하세요.');
      if (previewError) throw Error(previewError);
      const total = positiveInteger(form.total_qty, '이번 계획수량');
      const lots = validateCivilLots(quantities.map(qty => ({qty})), plan.remaining);
      if (lots.reduce((sum, lot) => sum + lot.qty, 0) !== total) throw Error('LOT 수량 합계와 이번 계획수량을 같게 맞추세요.');
      const steps = editor.read();
      if (steps.length * lots.length > 30000) throw Error('한 번에 생성되는 공정은 30,000개 이하입니다. 이번 계획수량이나 LOT 개수를 조정하세요.');
      return this.save('dnm_v410_split', {p: {...form, order_id: order.id, order_version: order.version,
        total_qty: total, lot_qty: positiveInteger(form.lot_qty, 'LOT당 기본 수량'), quantities: lots.map(lot => lot.qty),
        template_id: source.id || null, template_version: source.version || null, steps}, k: key});
    }, 'LOT와 작업지시 초안 저장');
    const preview = () => {
      try {
        quantities = splitCivilLots($('#civilTotal').value, $('#civilSize').value).map(lot => lot.qty);
        if (quantities.reduce((sum, value) => sum + value, 0) > Number(plan.remaining)) throw Error('이번 계획수량이 계획 가능 수량을 초과합니다.');
        previewError = '';
        $('#civilLotPreview').innerHTML = table(['생성 순서', 'LOT 번호', '계획수량'], quantities.map((value, index) => [num(index + 1), '저장 시 자동 부여', input('civil_qty_' + index, (index + 1) + '번째 LOT 수량', value, 'number', `required min="1" step="1" data-lot-index="${index}"`)]));
        all('[data-lot-index]').forEach(field => field.oninput = () => {quantities[Number(field.dataset.lotIndex)] = field.value; summary();});
        summary();
      } catch (error) {
        previewError = error.message;
        quantities = [];
        $('#civilLotPreview').innerHTML = notice(error.message, 'warning');
        $('#civilLotSummary').textContent = '';
      }
    };
    const summary = () => {
      const total = quantities.reduce((sum, value) => sum + Number(value), 0);
      $('#civilLotSummary').textContent = `${quantities.length}개 LOT · 합계 ${num(total)}개 / 이번 계획 ${num($('#civilTotal').value)}개`;
    };
    $('#civilTotal').onchange = preview;
    $('#civilSize').onchange = preview;
    $('#civilRecalculate').onclick = preview;
    $('#civilSource').onchange = event => {
      source = sources.find(row => row.id === event.target.value) || sources[0];
      editor = mountSteps('#civilSteps', source.steps.map(step => ({...step, independent: step.independent === true})), refs);
    };
    editor = mountSteps('#civilSteps', source.steps, refs);
    preview();
  }

  async routeDetail(id) {
    const [route, operations] = await Promise.all([this.main.s.one(id), this.main.rec('operation', {parent: id})]);
    if (!isCivilRoute(route)) throw Error('민수 Routing을 선택하세요.');
    this.main.remember([route]);
    const ordered = civilOperationRows(operations, id);
    const progress = routeProgress(route, ordered);
    const blocked = route.state === 'RELEASED' ? await this.main.blockedOperations(ordered) : new Set();
    const canManage = this.can('update') && (this.main.ctx.profile.role === 'admin' || route.data.manager_id === this.main.ctx.profile.id);
    const editable = canManage && ['DRAFT', 'RELEASED'].includes(route.state);
    const running = route.state === 'RELEASED';
    const body = `<div class="detail-grid">${[['LOT', route.data.lot || route.code], ['Shop Order', route.data.shop_order_no || route.data.shop_order || route.data.production_no], ['Heat Code', route.data.heat_code], ['품번', route.data.part_no], ['LOT 수량', num(route.data.qty)], ['상태', civilState(route)], ['완료 공정', progress.done + ' / ' + progress.ops.length], ['작업 예정일', route.data.plan_date]].map(([label, value]) => `<div><small>${esc(label)}</small><strong>${esc(value || '—')}</strong></div>`).join('')}</div>
      ${route.data.document_refs_pending?notice('문서항목 확인대기: S/O·Heat Code를 확인하여 고객 제출 전에 보완하세요.','warning'):''}
      ${route.data.termination_reason ? notice('불량 종결 사유 · ' + route.data.termination_reason, 'warning') : ''}
      <div class="actions">${civilButton('print', '민수 Routing PDF·인쇄', id, 'primary')}${civilButton('results', '이 LOT 실적', id)}
      ${this.main.ctx.profile.role==='admin'&&route.data.source_routing_id&&!['CANCELLED','SUPERSEDED'].includes(route.state)?btn('transfer:refs','S/O·Heat 보완',id):''}
      ${editable ? civilButton('quantity', 'LOT 수량 수정', id) : ''}
      ${canManage && !['CANCELLED','SUPERSEDED'].includes(route.state) ? civilButton('deleteZero', '실적 0 LOT 삭제', id) : ''}
      ${canManage && ['RELEASED', 'DONE'].includes(route.state) ? civilButton('terminate', '불량 최종종결', id) : ''}${editable && route.state === 'DRAFT' ? btn('release', '작업지시 배포', id) : ''}</div>
      ${table(['공정번호', '공정 / 작업내용', '진행 순서', '계획 설비 / 작업자', '지시 / 누적 처리', '상태', '작업'], ordered.map(operation => [
        esc(operation.data.op_code), esc(operation.title) + '<br><small>' + esc(operation.data.note || '') + '</small>', (operation.data.independent ? '순서 무관' : blocked.has(operation.id) ? '순서 준수 · 선행 대기' : '순서 준수') +
          (editable && ['DRAFT', 'WAIT'].includes(operation.state) && !Number(operation.data.confirmed_qty) ? btn('sequenceSetting', '순서 설정', operation.id) : ''),
        esc(operation.data.equipment_name || operation.data.equipment_label || operation.data.equipment_code || '작업 시 선택') + '<br>' + esc(operation.data.employee_name || '작업 시 선택'),
        num(operation.data.qty) + ' / ' + num(operation.data.confirmed_qty), pill(operation.state),
        (editable && operation.data.kind === 'WORK' && ['DRAFT', 'WAIT'].includes(operation.state) ? btn('assign', '배정 수정', operation.id) : '') + (running && !blocked.has(operation.id) && operation.data.kind === 'WORK' && !['DONE', 'CANCELLED', 'TERMINATED'].includes(operation.state) && this.can('create', 'worklogs') ? btn('start', '작업 시작', operation.id) + btn('manual', '수기 작업일보', operation.id) :
          running && !blocked.has(operation.id) && operation.data.kind !== 'WORK' && this.can('update') && ['WAIT', 'HOLD'].includes(operation.state) ? btn('managerStep', '관리공정 처리', operation.id) : '')
      ]))}`;
    this.bindDialog(modal('민수 Routing · ' + (route.data.lot || route.code), body));
  }

  async changeLot(action, id) {
    this.require('update');
    const route = await this.main.s.one(id);
    if (!isCivilRoute(route)) throw Error('민수 Routing을 선택하세요.');
    const titles = {quantity: 'LOT 수량 수정', cancel: '미착수 LOT 취소', terminate: '불량으로 LOT 최종종결'};
    const descriptions = {
      quantity: '실제 처리수량과 수주 잔량을 검증하여 LOT 및 공정 지시수량에 반영합니다.',
      cancel: '작업·검사 이력이 없는 LOT를 취소합니다. 취소 수량은 수주의 계획 가능 수량으로 돌아갑니다.',
      terminate: '진행 중 작업과 수량 확인대기 건을 먼저 종료·확정하세요. 불량 종결 후 이 LOT의 추가 생산은 종료되며 등록된 실적과 수량은 이력으로 보관됩니다.'
    };
    modal(titles[action] + ' · ' + (route.data.lot || route.code), notice(descriptions[action], action === 'terminate' ? 'warning' : 'info') +
      (action === 'quantity' ? input('qty', '변경 후 LOT 총수량', route.data.qty, 'number', 'required min="1" step="1"') : '') +
      area('reason', action === 'terminate' ? '불량 내용 및 최종종결 사유' : '변경 사유', '', 'required maxlength="1000"') +
      '<label class="check"><input type="checkbox" name="reviewed" required>대상 LOT와 처리 내용을 확인했습니다.</label>', (form, key) => {
        if (form.reviewed !== 'on') throw Error('처리 내용을 확인하세요.');
        return this.save('dnm_v410_lot', {act: action, p: {id, version: route.version, reason: form.reason,
          ...(action === 'quantity' ? {qty: positiveInteger(form.qty, 'LOT 수량')} : {})}, k: key});
      }, action === 'terminate' ? '불량 최종종결 확정' : titles[action]);
  }

  async results() {
    const ticket = ++this.ticket;
    const [routes, operations, logs, orders] = await Promise.all(['routing', 'operation', 'worklog', 'order'].map(kind => this.main.rec(kind)));
    if (ticket !== this.ticket || this.main.page !== 'civilResults') return;
    const civil = civilRows(routes, orders, {state: 'all'});
    const selection = civilRows(routes, orders, {query: this.main.search, state: this.state}).filter(route => !this.resultRoute || route.id === this.resultRoute);
    const logRows = civilResultRows(civil, operations, logs, {query: this.main.search, routeId: this.resultRoute, date: this.resultDate, employee: this.resultWorker});
    if(this.main.loadLogEditStatus) await this.main.loadLogEditStatus(logRows.map(row=>row.log));
    if (ticket !== this.ticket || this.main.page !== 'civilResults') return;
    this.visibleResults = logRows;
    const workers = [...new Set(civilResultRows(civil, operations, logs).map(row => row.log.data.employee_name).filter(Boolean))].sort((a, b) => a.localeCompare(b, 'ko'));
    const diary = this.resultView === 'logs';
    const rows = diary ? logRows : selection;
    const controls = `<div class="filter-bar">${select('civilView', '실적 보기', [['process', '공정별 누적실적'], ['logs', '작업일보']], this.resultView, 'id="civilView"')}
      ${select('civilRouteFilter', 'LOT', [['', '전체 LOT'], ...civil.map(route => [route.id, route.data.lot || route.code])], this.resultRoute, 'id="civilRouteFilter"')}
      ${diary ? input('civilDate', '작업일 (전체는 공란)', this.resultDate, 'date', 'id="civilDate"') + select('civilWorker', '실제 작업자', [['', '전체 작업자'], ...workers.map(worker => [worker, worker])], this.resultWorker, 'id="civilWorker"') :
        select('civilGroup', '집계 기준', [['lot', 'LOT별'], ['order', '수주별 · 품번·납기·S/O']], this.resultGroup, 'id="civilGroup"') + select('civilState', 'LOT 상태', stateOptions, this.state, 'id="civilState"')}</div>`;
    this.main.set(`<div class="card civil-page">${this.main.top(diary ? civilButton('export', '현재 작업일보 CSV') : '')}${controls}
      ${diary ? this.logsTable(logRows) : this.processTable(selection, operations, orders)}<div id="v4pager" class="pagination"></div></div>`);
    this.main.pageFooter(diary || this.resultGroup === 'lot' ? rows : civilProcessSummary(selection, operations, orders, 'order').groups);
    const bind = (selector, key) => {const field = $(selector); if (field) field.onchange = event => {this[key] = event.target.value; this.main.pageNo = 1; this.results().catch(error => message(error.message));};};
    bind('#civilView', 'resultView'); bind('#civilGroup', 'resultGroup'); bind('#civilRouteFilter', 'resultRoute'); bind('#civilState', 'state'); bind('#civilDate', 'resultDate'); bind('#civilWorker', 'resultWorker');
  }

  processTable(routes, operations, orders) {
    const grouped = this.resultGroup === 'order';
    const summary = civilProcessSummary(routes, operations, orders, this.resultGroup);
    const heads = [grouped ? 'Shop Order / 수주번호' : 'LOT / Shop Order', '품번 / Heat Code', '납기', grouped ? '수주수량 / 계획수량' : '계획수량 / 상태', ...summary.columns.map(column => column.code + ' ' + column.name)];
    return notice('각 공정의 확정된 누적 처리수량입니다. 같은 물량이 여러 공정을 거치므로 공정 열의 수량을 합산하지 않습니다.') +
      `<div class="civil-process-table">${table(heads, this.main.pagedCells(summary.groups, group => {
        const route = group.routes[0];
        const order = group.order;
        return [grouped ? esc(route.data.shop_order_no || route.data.shop_order || order?.data.shop_order_no || route.data.production_no) + '<br>' + esc(order?.code || '') :
          civilButton('detail', route.data.lot || route.code, route.id) + '<br>' + esc(route.data.shop_order_no || route.data.shop_order || route.data.production_no),
          esc(route.data.part_no) + '<br>' + esc(route.data.heat_code || '—'), esc(route.data.due_date || '미정'),
          grouped ? (order ? num(order.data.qty) : '조회 권한 확인') + ' / ' + num(group.planned) + '<br><small>' + group.routes.length + '개 LOT</small>' : num(route.data.qty) + '<br>' + esc(civilState(route)),
          ...summary.columns.map(column => {
            const result = group.quantities.get(column.key);
            return result ? `<strong>${num(result.total)}</strong><br><small>${result.pending ? '수량 확인대기 포함' : result.terminated ? '불량 종결 포함' : result.complete ? '완료' : '진행'}</small>` : '—';
          })];
      }))}</div>`;
  }

  logsTable(rows) {
    return table(['작업일 / LOT', '공정', '실제 설비 / 작업자', '시작 / 종료', '총 / 양품 / 불량', '작업시간', '비고', '상태', '관리'], this.main.pagedCells(rows, row => [
      esc(row.workDate) + '<br>' + civilButton('detail', row.route.data.lot || row.route.code, row.route.id), esc(row.operation.data.op_code) + ' ' + esc(row.operation.title),
      esc(row.log.data.equipment_name || row.log.data.equipment_code) + '<br>' + esc(row.log.data.employee_name), esc(clock(row.log.data.start_at)) + '<br>' + esc(clock(row.log.data.end_at)),
      row.log.state === 'CONFIRMED' ? `${num(row.log.data.total)} / ${num(row.log.data.good)} / ${num(row.log.data.defect)}` : '미확정', esc(duration(row.log.data.minutes)), esc(row.log.data.memo||''), pill(row.log.state),
      row.log.state === 'ACTIVE' && this.can('update', 'worklogs') ? btn('stopLog', '작업 종료', row.log.id) : row.log.state === 'PENDING' && this.can('update', 'worklogs') ? btn('confirmLog', '수량 확인', row.log.id) : this.main.logEditButton?.(row.log)||'—'
    ]));
  }

  async print(id) {
    const route = await this.main.s.one(id);
    if (!isCivilRoute(route)) throw Error('민수 Routing을 선택하세요.');
    const [operations, logs, events] = await Promise.all([
      this.main.rec('operation', {parent: id}), this.main.rec('worklog'), this.main.rec('material')
    ]);
    return printCivilRouting({route, operations, logs, events});
  }

  help() {
    return modal('민수 생산관리 사용방법', '<ol class="help-list"><li>고객수주에서 민수 구분과 Shop Order·Heat Code를 등록합니다.</li><li>민수 LOT 분할 작성에서 계획수량과 LOT당 수량을 입력하고 공정을 확인합니다. 저장하면 YYMM-일련번호가 자동 부여됩니다.</li><li>초안을 배포한 후 작업을 시작합니다. 실제 작업자와 설비는 작업일보에서 선택·수정합니다.</li><li>민수 실적조회에서 LOT별 공정 누적수량과 실제 작업일보를 확인합니다.</li><li>미착수 취소는 계획수량을 반환합니다. 불량 최종종결은 사유와 실적을 보관하고 해당 LOT의 추가 작업을 종료합니다.</li></ol>');
  }

  async action(action, id) {
    const name = action.startsWith('civil:') ? action.slice(6) : action;
    if (name === 'new') return this.routingForm(id ? await this.main.s.one(id) : null);
    if (name === 'detail') return this.routeDetail(id);
    if (name === 'print') return this.print(id);
    if (['quantity', 'cancel', 'terminate'].includes(name)) return this.changeLot(name, id);
    if (name === 'results') {
      this.resultRoute = id;
      this.state = 'all';
      closeModal();
      return this.main.go('civilResults');
    }
    if (name === 'export') return exportCSV('DNM_민수작업일보_' + today() + '.csv', [['LOT', 'Shop Order', 'Heat Code', '품번', '작업일', '공정', '설비', '작업자', '시작', '종료', '총수량', '양품', '불량', '공수(분)', '상태', '비고'],
      ...this.visibleResults.map(({log, operation, route, workDate}) => [route.data.lot || route.code, route.data.shop_order_no || route.data.shop_order || route.data.production_no, route.data.heat_code, route.data.part_no, workDate, operation.title,
        log.data.equipment_name || log.data.equipment_code, log.data.employee_name, log.data.start_at, log.data.end_at,
        log.state === 'CONFIRMED' ? log.data.total : '', log.state === 'CONFIRMED' ? log.data.good : '', log.state === 'CONFIRMED' ? log.data.defect : '', log.data.minutes, log.state, log.data.memo])]);
    throw Error('민수 화면 작업을 다시 선택하세요.');
  }
}
