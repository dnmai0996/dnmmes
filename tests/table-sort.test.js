import test from 'node:test';
import assert from 'node:assert/strict';
import {compareSortValues,sortCellRows,displayedText,canSortHeader} from '../public/modules/table-sort.js';
import {table} from '../public/modules/ui.js';
import {MesController} from '../public/modules/mes.js';

test('Korean names, natural codes, quantities and decimals are ordered properly',()=>{
 const rows=[['NC-10','1,500'],['NC-2','75'],['NC-1','12.5']];
 assert.deepEqual(sortCellRows(rows,0).map(r=>r[0]),['NC-1','NC-2','NC-10']);
 assert.deepEqual(sortCellRows(rows,1).map(r=>r[0]),['NC-1','NC-2','NC-10']);
 assert.deepEqual(sortCellRows(rows,1,'desc').map(r=>r[0]),['NC-10','NC-2','NC-1']);
 assert.ok(compareSortValues('선삭 가공','연삭 가공')<0);
});
test('dates, missing values, and HTML cell labels are sorted as displayed',()=>{
 const rows=[['A','2026-12-01'],['B','2026-10-29'],['C','미확정'],['D','2026-11-11']];
 assert.deepEqual(sortCellRows(rows,1).map(r=>r[0]),['B','D','A','C']);
 assert.deepEqual(sortCellRows(rows,1,'desc').map(r=>r[0]),['A','D','B','C']);
 assert.equal(displayedText('<button type="button">10622867</button>'),'10622867');
 assert.equal(displayedText('<span class="pill">사용 중</span>'),'사용 중');
});
test('stable ties and sorting of blank fields regardless of direction',()=>{
 const rows=[['A','—'],['B','10'],['C','10'],['D','']];
 assert.deepEqual(sortCellRows(rows,1).map(r=>r[0]),['B','C','A','D']);
 assert.deepEqual(sortCellRows(rows,1,'desc').map(r=>r[0]),['B','C','A','D']);
});
test('headers are clickable only when columns have meaningful data',()=>{
 const output=table(['수량','납기일자','관리'],[['12','2026-10-29','수정']]);
 assert.match(output,/data-table-sort="0"/);
 assert.match(output,/data-table-sort="1"/);
 assert.doesNotMatch(output,/data-table-sort="2"/);
 assert.ok(canSortHeader('자재명'));
 assert.ok(!canSortHeader('관리'));
});
test('full filtered dataset sorted before pagination; reverse order persists across pages',()=>{
 const c=Object.create(MesController.prototype);
 c.page='orders';c.pageNo=1;c.headerSort=new Map();
 const data=Array.from({length:64},(_,i)=>({code:`SO-${64-i}`,qty:64-i}));
 c.headerSort.set('orders',{col:1,dir:'asc'});
 assert.equal(c.pagedCells(data,r=>[r.code,String(r.qty)]).length,30);
 assert.equal(c.pagedCells(data,r=>[r.code,String(r.qty)])[0][1],'1');
 c.pageNo=2;assert.equal(c.pagedCells(data,r=>[r.code,String(r.qty)])[0][1],'31');
 c.headerSort.set('orders',{col:1,dir:'desc'});
 c.pageNo=1;assert.equal(c.pagedCells(data,r=>[r.code,String(r.qty)])[0][1],'64');
 c.pageNo=3;assert.equal(c.pagedCells(data,r=>[r.code,String(r.qty)])[0][1],'4');
});
test('reference master table sorts full rows before taking page slice',()=>{
 const c=Object.create(MesController.prototype);c.page='equipment';c.headerSort=new Map([['equipment',{col:0,dir:'desc'}]]);
 const raw=Array.from({length:44},(_,i)=>[`NC-${String(i+1).padStart(3,'0')}`,String(i+1)]);
 assert.equal(c.sortedCells(raw)[0][0],'NC-044');
 assert.equal(c.sortedCells(raw).slice(30)[0][0],'NC-014');
});
