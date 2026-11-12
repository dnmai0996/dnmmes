-- DISPOSABLE TEST DATABASE ONLY. Apply bootstrap, legacy fixtures and migrations through 27.
-- Every fixture is rolled back. Never run this file against a company Supabase project.
BEGIN;
CREATE TEMP TABLE test410_refs(name text PRIMARY KEY,id uuid);
GRANT SELECT ON test410_refs TO authenticated;
CREATE OR REPLACE FUNCTION pg_temp.v410_version(p_id uuid) RETURNS integer LANGUAGE sql AS $$
 SELECT version FROM public.dnm_v4_records WHERE id=p_id
$$;
CREATE OR REPLACE FUNCTION pg_temp.v410_reject(statement text,label text,fragment text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 BEGIN
  EXECUTE statement;
 EXCEPTION WHEN OTHERS THEN
  IF fragment<>'' AND strpos(SQLERRM,fragment)=0 THEN
   RAISE EXCEPTION 'Unexpected failure for %: %',label,SQLERRM;
  END IF;
  RAISE NOTICE 'PASS: % rejected',label;
  RETURN;
 END;
 RAISE EXCEPTION 'ASSERT FAILED: % should be rejected',label;
END $$;
SELECT public.test_assert(has_function_privilege('authenticated','public.dnm_v410_split(jsonb,uuid)','EXECUTE'),'authenticated split entry point');
SELECT public.test_assert(NOT has_function_privilege('anon','public.dnm_v410_split(jsonb,uuid)','EXECUTE'),'anonymous split denied');
SELECT public.test_assert(NOT has_function_privilege('anon','public.dnm_v410_work(text,jsonb,uuid)','EXECUTE'),'anonymous actual work denied');

DO $$
DECLARE
 admin_id uuid:='11111111-1111-4111-8111-111111111111';
 worker_id uuid:='33333333-3333-4333-8333-333333333333';
 viewer_id uuid:='44444444-4444-4444-8444-444444444444';
 substitute_profile uuid:='41000000-0000-4000-8000-000000000001';
 order_id uuid; second_order uuid; third_order uuid; defense_order uuid; legacy_order uuid;
 equipment_id uuid; other_equipment uuid; employee_id uuid; substitute_employee uuid;
 route_id uuid; second_route uuid; third_route uuid; operation_id uuid; later_operation uuid; work_id uuid; saved_work jsonb;
 request_id uuid; payload jsonb; result jsonb; repeated jsonb; steps jsonb; item jsonb;
 serial_max integer; amount bigint; actual_version integer; before_data jsonb;
BEGIN
 PERFORM set_config('request.jwt.claim.sub',admin_id::text,true);
 INSERT INTO auth.users(id,email) VALUES(substitute_profile,'substitute-v410@example.invalid');
 UPDATE public.dnm_portal_profiles SET active=true,role='member',display_name='교대 시험작업자' WHERE id=substitute_profile;
 INSERT INTO public.dnm_v42_module_access(profile_id,module,can_read,can_create,can_update,scope)
 VALUES(substitute_profile,'worklogs',true,true,true,'own')
 ON CONFLICT(profile_id,module) DO UPDATE SET can_read=true,can_create=true,can_update=true,scope='own';
 UPDATE public.dnm_v42_module_access SET can_read=true,can_create=true,can_update=true,scope='own'
 WHERE profile_id=worker_id AND module='worklogs';
 SELECT id INTO employee_id FROM public.dnm_v4_records WHERE kind='employee' AND code='EMP-TEST';
 UPDATE public.dnm_v4_records SET data=data||'{"active":true}'::jsonb WHERE id=employee_id;
 result:=public.dnm_v4_command('save_master',jsonb_build_object('kind','equipment','code','T410-EQ-A','title','지시 설비','data',jsonb_build_object('active',true,'manager_id',admin_id)),gen_random_uuid());
 equipment_id:=(result->>'id')::uuid;
 result:=public.dnm_v4_command('save_master',jsonb_build_object('kind','equipment','code','T410-EQ-B','title','실사용 설비','data',jsonb_build_object('active',true,'manager_id',admin_id)),gen_random_uuid());
 other_equipment:=(result->>'id')::uuid;
 result:=public.dnm_v4_command('save_master',jsonb_build_object('kind','employee','code','T410-EMP-B','title','교대 시험작업자','data',jsonb_build_object('active',true,'department','가공','profile_id',substitute_profile)),gen_random_uuid());
 substitute_employee:=(result->>'id')::uuid;
 steps:=jsonb_build_array(
  jsonb_build_object('code','010','name','시험선삭','kind','WORK','equipment_id',equipment_id,'employee_id',employee_id,'employee_ids',jsonb_build_array(employee_id),'independent',false),
  jsonb_build_object('code','020','name','시험연마','kind','WORK','equipment_id',equipment_id,'employee_id',employee_id,'employee_ids',jsonb_build_array(employee_id),'independent',true)
 );
 payload:=jsonb_build_object('data',jsonb_build_object('production_no','T410-ORDER-A','customer','시험고객','part_no','T410-BUSH','part_name','시험 부싱','qty',10500,'order_type','CIVIL','shop_order_no','SO-410','heat_code','HEAT-410'));
 request_id:=gen_random_uuid();
 result:=public.dnm_v410_save_order(payload,request_id);order_id:=(result->>'id')::uuid;
 repeated:=public.dnm_v410_save_order(payload,request_id);
 PERFORM public.test_assert(result=repeated,'civilian order retry returns identical response');
 PERFORM public.test_assert((SELECT data->>'shop_order_no'='SO-410' AND data->>'heat_code'='HEAT-410' FROM public.dnm_v4_records WHERE id=order_id),'shop order and heat code persist');
 payload:=jsonb_build_object('order_id',order_id,'order_version',pg_temp.v410_version(order_id),'manager_id',admin_id,'lot_qty',4000,'plan_date','2026-11-12','production_mode','daily_assigned','steps',steps);
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_split(%L::jsonb,gen_random_uuid())',jsonb_set(payload,'{lot_qty}','1')::text),'batch over 200 lots is bounded');
 request_id:=gen_random_uuid();
 result:=public.dnm_v410_split(payload,request_id);
 repeated:=public.dnm_v410_split(payload,request_id);
 PERFORM public.test_assert(result=repeated,'batch request retry returns identical response');
 PERFORM public.test_assert((result->>'count')::integer=3 AND jsonb_array_length(result->'ids')=3,'10500 units split into three lots');
 PERFORM public.test_assert((SELECT array_agg((data->>'qty')::integer ORDER BY code)=ARRAY[4000,4000,2500] FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=order_id),'last lot receives exact 2500 remainder');
 PERFORM public.test_assert((public.dnm_v410_plan_info(order_id)->>'remaining')::bigint=0,'allocation consumes exact order quantity');
 PERFORM public.test_assert((SELECT bool_and(data->>'lot' ~ '^2611-[0-9]+$') FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=order_id),'lots use YYMM serial format');
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_split(%L::jsonb,%L)',jsonb_set(payload,'{lot_qty}','3000')::text,request_id),'retry with modified split input');
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_split(%L::jsonb,gen_random_uuid())',payload::text),'fully allocated order cannot overproduce');
 SELECT id INTO route_id FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=order_id ORDER BY code LIMIT 1;
 SELECT id INTO second_route FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=order_id ORDER BY code OFFSET 1 LIMIT 1;
 SELECT id INTO third_route FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=order_id ORDER BY code OFFSET 2 LIMIT 1;
 SELECT max(split_part(data->>'lot','-',2)::integer) INTO serial_max FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=order_id;
 payload:=jsonb_build_object('id',route_id,'version',pg_temp.v410_version(route_id),'qty',3500,'reason','배치 크기 조정');
 result:=public.dnm_v410_lot('quantity',payload,gen_random_uuid());
 PERFORM public.test_assert((public.dnm_v410_plan_info(order_id)->>'remaining')::integer=500,'quantity edit restores 500 units of planning capacity');
 PERFORM public.test_assert((SELECT bool_and((data->>'qty')::integer=3500) FROM public.dnm_v4_records WHERE kind='operation' AND parent_id=route_id),'quantity edit updates every operation quantity');
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_lot(''quantity'',%L::jsonb,gen_random_uuid())',jsonb_build_object('id',route_id,'version',pg_temp.v410_version(route_id),'qty',4001,'reason','초과 시험')::text),'lot edit cannot exceed remaining order allowance');
 PERFORM public.dnm_v410_lot('quantity',jsonb_build_object('id',route_id,'version',pg_temp.v410_version(route_id),'qty',4000,'reason','원 계획 복귀'),gen_random_uuid());
 actual_version:=pg_temp.v410_version(third_route);
 payload:=jsonb_build_object('id',third_route,'version',actual_version,'reason','시작 전 계획 취소');
 request_id:=gen_random_uuid();result:=public.dnm_v410_lot('cancel',payload,request_id);
 PERFORM public.test_assert(result=public.dnm_v410_lot('cancel',payload,request_id),'cancel retry is idempotent');
 PERFORM public.test_assert((SELECT state='CANCELLED' FROM public.dnm_v4_records WHERE id=third_route),'before-start cancellation retains route audit record');
 PERFORM public.test_assert((SELECT bool_and(state='CANCELLED') FROM public.dnm_v4_records WHERE kind='operation' AND parent_id=third_route),'before-start cancellation closes child operations');
 PERFORM public.test_assert((public.dnm_v410_plan_info(order_id)->>'remaining')::integer=2500,'cancelled pre-start lot restores allocation');
 result:=public.dnm_v410_split(jsonb_build_object('order_id',order_id,'order_version',pg_temp.v410_version(order_id),'manager_id',admin_id,'lot_qty',2500,'plan_date','2026-11-12','production_mode','daily_assigned','steps',steps),gen_random_uuid());
 PERFORM public.test_assert((result->>'count')::int=1,'cancelled lot can be recreated without duplicate allocation');
 PERFORM public.test_assert((SELECT max(split_part(data->>'lot','-',2)::integer)>serial_max FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=order_id),'cancelled LOT identifier is never reused');
 result:=public.dnm_v410_save_order(jsonb_build_object('data',jsonb_build_object('production_no','T410-ORDER-B','customer','시험고객','part_no','T410-BUSH','qty',200,'order_type','CIVIL','shop_order_no','SO-B','heat_code','H-B')),gen_random_uuid());second_order:=(result->>'id')::uuid;
 SELECT max(split_part(data->>'lot','-',2)::integer) INTO serial_max FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=order_id;
 result:=public.dnm_v410_split(jsonb_build_object('order_id',second_order,'order_version',pg_temp.v410_version(second_order),'manager_id',admin_id,'lot_qty',100,'plan_date','2026-11-25','production_mode','daily_assigned','steps',steps),gen_random_uuid());
 PERFORM public.test_assert((SELECT min(split_part(data->>'lot','-',2)::integer)>serial_max FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=second_order),'same-month serial is shared across orders');
 PERFORM public.test_assert((SELECT count(DISTINCT data->>'lot')=count(*) FROM public.dnm_v4_records WHERE kind='routing' AND parent_id IN(order_id,second_order)),'distinct LOT identifiers across orders');
 result:=public.dnm_v410_save_order(jsonb_build_object('data',jsonb_build_object('order_type','CIVIL','customer','시험고객','part_no','T410-AUTO','qty',20,'shop_order_no','SO-AUTO','heat_code','H-AUTO')),gen_random_uuid());third_order:=(result->>'id')::uuid;
 PERFORM public.test_assert(result->>'code' ~ '^CIV-[0-9]{4}-[0-9]+$','manual civilian order gets a persistent automatic order code');
 payload:=jsonb_build_object('order_id',third_order,'order_version',pg_temp.v410_version(third_order),'manager_id',admin_id,'total_qty',10,'quantities',jsonb_build_array(4,6),'plan_date','2026-12-01','steps',steps);
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_split(%L::jsonb,gen_random_uuid())',jsonb_set(payload,'{quantities}','[4,7]')::text),'explicit LOT quantities must total the intended allocation');
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_split(%L::jsonb,gen_random_uuid())',jsonb_set(payload,'{order_version}','0')::text),'stale order version');
 result:=public.dnm_v410_split(payload,gen_random_uuid());
 PERFORM public.test_assert((result->>'remaining')::int=10 AND (result->>'count')::int=2,'individual LOT quantities support partial-order allocation');
 PERFORM public.test_assert((SELECT array_agg((data->>'qty')::int ORDER BY code)=ARRAY[4,6] FROM public.dnm_v4_records WHERE parent_id=third_order AND kind='routing'),'explicit individual LOT amounts are retained');
 -- Worker needs the minimum worklog rights, never planning or another worker's identity.
 PERFORM set_config('request.jwt.claim.sub',viewer_id::text,true);
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_split(%L::jsonb,gen_random_uuid())',jsonb_build_object('order_id',second_order,'order_version',pg_temp.v410_version(second_order),'lot_qty',1,'plan_date','2026-11-12','steps',steps)::text),'viewer cannot split','권한');
 PERFORM set_config('request.jwt.claim.sub',worker_id::text,true);
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_lot(''cancel'',%L::jsonb,gen_random_uuid())',jsonb_build_object('id',second_route,'version',pg_temp.v410_version(second_route),'reason','권한 시험')::text),'work-only worker cannot cancel planning','권한');
 PERFORM set_config('request.jwt.claim.sub',admin_id::text,true);
 PERFORM public.dnm_v4_command('release_routing',jsonb_build_object('id',route_id,'version',pg_temp.v410_version(route_id)),gen_random_uuid());
 SELECT id,data INTO operation_id,before_data FROM public.dnm_v4_records WHERE kind='operation' AND parent_id=route_id ORDER BY (data->>'seq')::integer LIMIT 1;
 SELECT id INTO later_operation FROM public.dnm_v4_records WHERE kind='operation' AND parent_id=route_id ORDER BY (data->>'seq')::integer DESC LIMIT 1;
 result:=public.dnm_v410_work_choices(operation_id);
 PERFORM public.test_assert(EXISTS(SELECT FROM jsonb_array_elements(result->'machines') x WHERE x->>'id'=other_equipment::text),'actual-work entry lists eligible alternative equipment');
 PERFORM public.test_assert(EXISTS(SELECT FROM jsonb_array_elements(result->'employees') x WHERE x->>'id'=substitute_employee::text),'manager actual-work entry lists substitute worker');
 PERFORM set_config('request.jwt.claim.sub',worker_id::text,true);
 result:=public.dnm_v410_work_choices(operation_id);
 PERFORM public.test_assert(jsonb_array_length(result->'employees')=1 AND result->'employees'->0->>'id'=employee_id::text,'ordinary worker choices limit identity to own worker record');
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_work(''start'',%L::jsonb,gen_random_uuid())',jsonb_build_object('id',operation_id,'version',pg_temp.v410_version(operation_id),'employee_id',substitute_employee,'equipment_id',other_equipment)::text),'worker cannot impersonate another worker');
 PERFORM set_config('request.jwt.claim.sub',admin_id::text,true);
 payload:=jsonb_build_object('id',operation_id,'version',pg_temp.v410_version(operation_id),'employee_id',substitute_employee,'equipment_id',other_equipment,'work_date','2026-11-12');
 request_id:=gen_random_uuid();result:=public.dnm_v410_work('start',payload,request_id);work_id:=(result->>'id')::uuid;
 PERFORM public.test_assert(result=public.dnm_v410_work('start',payload,request_id),'actual-work start retry returns same log');
 PERFORM public.test_assert((SELECT data->>'equipment_id'=other_equipment::text AND data->>'employee_id'=substitute_employee::text AND data->>'employee_name'='교대 시험작업자' FROM public.dnm_v4_records WHERE id=work_id),'worklog snapshots actual equipment and substitute worker');
 PERFORM public.test_assert((SELECT data->>'equipment_id'=before_data->>'equipment_id' AND data->>'employee_id'=before_data->>'employee_id' FROM public.dnm_v4_records WHERE id=operation_id),'actual work preserves the original instruction assignment');
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_lot(''cancel'',%L::jsonb,gen_random_uuid())',jsonb_build_object('id',route_id,'version',pg_temp.v410_version(route_id),'reason','시작 후 취소')::text),'started lot cannot be deleted');
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v493_void_daily(%L,%s,%L)',route_id,pg_temp.v410_version(route_id),'구버전취소'),'legacy cancellation cannot delete started LOT');
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_lot(''quantity'',%L::jsonb,gen_random_uuid())',jsonb_build_object('id',route_id,'version',pg_temp.v410_version(route_id),'qty',3000,'reason','진행중 변경')::text),'active work blocks quantity edit');
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_lot(''terminate'',%L::jsonb,gen_random_uuid())',jsonb_build_object('id',route_id,'version',pg_temp.v410_version(route_id),'reason','진행중 중단')::text),'active work must be resolved before final termination');
 UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('start_at',now()-interval '1 hour') WHERE id=work_id;
 PERFORM public.dnm_v4_command('finish_work',jsonb_build_object('id',work_id,'version',pg_temp.v410_version(work_id),'total',100,'defect',5),gen_random_uuid());
 INSERT INTO test410_refs VALUES('actual_worklog',work_id),('actual_route',route_id),('actual_operation',operation_id),('actual_equipment',other_equipment);
 SELECT to_jsonb(r) INTO saved_work FROM public.dnm_v4_records r WHERE id=work_id;
 payload:=jsonb_build_object('id',route_id,'version',pg_temp.v410_version(route_id),'reason','가공 불량 확인으로 최종 중단');
 request_id:=gen_random_uuid();result:=public.dnm_v410_lot('terminate',payload,request_id);
 PERFORM public.test_assert(result=public.dnm_v410_lot('terminate',payload,request_id),'termination retry is idempotent');
 PERFORM public.test_assert((public.dnm_v410_plan_info(order_id)->>'remaining')::int=0,'terminated lots retain order allocation');
 PERFORM public.test_assert((public.dnm_v493_plan_info(order_id)->>'remaining')::int=0,'legacy planning endpoint includes terminated allocation');
 PERFORM public.test_assert((SELECT state='TERMINATED' FROM public.dnm_v4_records WHERE id=route_id),'defect termination closes the civilian lot');
 PERFORM public.test_assert((SELECT to_jsonb(r)=saved_work FROM public.dnm_v4_records r WHERE id=work_id),'defect termination retains exact confirmed worklog and quantities');
 PERFORM public.test_assert((SELECT bool_and(state IN('DONE','TERMINATED')) FROM public.dnm_v4_records WHERE parent_id=route_id AND kind='operation'),'defect termination closes remaining operations');
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v4_command(''start_work'',%L::jsonb,gen_random_uuid())',jsonb_build_object('id',later_operation,'version',pg_temp.v410_version(later_operation))::text),'old endpoint cannot restart terminated LOT');
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_lot(''quantity'',%L::jsonb,gen_random_uuid())',jsonb_build_object('id',route_id,'version',pg_temp.v410_version(route_id),'qty',99,'reason','실적 미만 수정')::text),'confirmed 100 units cannot be erased by quantity edit');
 -- Minimum-rights substitute can work an independent later operation and confirm pending counts.
 PERFORM public.dnm_v4_command('release_routing',jsonb_build_object('id',second_route,'version',pg_temp.v410_version(second_route)),gen_random_uuid());
 SELECT id INTO later_operation FROM public.dnm_v4_records WHERE parent_id=second_route AND kind='operation' ORDER BY (data->>'seq')::int DESC LIMIT 1;
 PERFORM set_config('request.jwt.claim.sub',substitute_profile::text,true);
 payload:=jsonb_build_object('id',later_operation,'version',pg_temp.v410_version(later_operation),'employee_id',substitute_employee,'equipment_id',other_equipment);
 result:=public.dnm_v410_work('start',payload,gen_random_uuid());work_id:=(result->>'id')::uuid;
 PERFORM public.test_assert((SELECT state='ACTIVE' FROM public.dnm_v4_records WHERE id=work_id),'minimum-rights worker can start independent later civilian operation');
 UPDATE public.dnm_v42_module_access SET can_create=false WHERE profile_id=substitute_profile AND module='worklogs';
 UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('start_at',now()-interval '1 hour') WHERE id=work_id;
 payload:=jsonb_build_object('id',work_id,'version',pg_temp.v410_version(work_id),'employee_id',substitute_employee,'equipment_id',other_equipment,'pending',true);
 result:=public.dnm_v410_work('finish',payload,gen_random_uuid());
 PERFORM public.test_assert((SELECT state='PENDING' FROM public.dnm_v4_records WHERE id=work_id),'update-only worker can close an active log pending quantity confirmation');
 payload:=jsonb_build_object('id',work_id,'version',pg_temp.v410_version(work_id),'employee_id',substitute_employee,'equipment_id',other_equipment,'confirm_pending',true,'total',50,'defect',0);
 result:=public.dnm_v410_work('finish',payload,gen_random_uuid());
 PERFORM public.test_assert((SELECT state='CONFIRMED' AND data->>'good'='50' FROM public.dnm_v4_records WHERE id=work_id),'update-only worker can confirm pending actual quantities');
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_work(''start'',%L::jsonb,gen_random_uuid())',jsonb_build_object('id',later_operation,'version',pg_temp.v410_version(later_operation),'employee_id',substitute_employee,'equipment_id',other_equipment)::text),'update-only worker cannot create a new worklog','권한');
 PERFORM set_config('request.jwt.claim.sub',admin_id::text,true);
 UPDATE public.dnm_v42_module_access SET can_create=true WHERE profile_id=substitute_profile AND module='worklogs';
 payload:=jsonb_build_object('id',later_operation,'version',pg_temp.v410_version(later_operation),'employee_id',substitute_employee,'equipment_id',other_equipment,'start_at',now()-interval '3 hours','end_at',now()-interval '2 hours','work_date',current_date,'total',20,'defect',1,'reason','누락일보 보완');
 result:=public.dnm_v410_work('manual',payload,gen_random_uuid());
 PERFORM public.test_assert((SELECT state='CONFIRMED' AND data->>'equipment_id'=other_equipment::text AND data->>'total'='20' FROM public.dnm_v4_records WHERE id=(result->>'id')::uuid),'manual civilian log retains actual equipment with out-of-order permission');
 payload:=jsonb_build_object('id',later_operation,'version',pg_temp.v410_version(later_operation),'employee_id',substitute_employee,'equipment_id',other_equipment);
 result:=public.dnm_v410_work('start',payload,gen_random_uuid());work_id:=(result->>'id')::uuid;
 UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('start_at',now()-interval '1 hour') WHERE id=work_id;
 payload:=jsonb_build_object('id',work_id,'version',pg_temp.v410_version(work_id),'employee_id',employee_id,'equipment_id',equipment_id,'total',30,'defect',2);
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_work(''finish'',%L::jsonb,gen_random_uuid())',payload::text),'actual identity correction requires a reason');
 payload:=payload||jsonb_build_object('change_reason','실제 작업자와 가동설비 대조 정정');
 result:=public.dnm_v410_work('finish',payload,gen_random_uuid());
 PERFORM public.test_assert((SELECT data->>'employee_id'=employee_id::text AND data->>'equipment_id'=equipment_id::text AND data->>'good'='28' FROM public.dnm_v4_records WHERE id=work_id),'actual employee and equipment can be corrected when final quantities are saved');
 PERFORM public.test_assert((SELECT data->'identity_history'->0->>'previous_employee_id'=substitute_employee::text AND data->'identity_history'->0->>'previous_equipment_id'=other_equipment::text AND data->'identity_history'->0->>'reason'='실제 작업자와 가동설비 대조 정정' FROM public.dnm_v4_records WHERE id=work_id),'identity correction retains prior actual snapshots and reason');
 -- Completed civilian LOTs can be terminated for confirmed defects before final quality or shipping.
 SELECT id INTO third_route FROM public.dnm_v4_records WHERE parent_id=third_order AND kind='routing' AND data->>'qty'='4';
 PERFORM public.dnm_v4_command('release_routing',jsonb_build_object('id',third_route,'version',pg_temp.v410_version(third_route)),gen_random_uuid());
 FOR item IN SELECT to_jsonb(x) FROM public.dnm_v4_records x WHERE x.parent_id=third_route AND x.kind='operation' ORDER BY (x.data->>'seq')::int LOOP
  result:=public.dnm_v410_work('manual',jsonb_build_object('id',item->>'id','version',item->'version','employee_id',employee_id,'equipment_id',equipment_id,'start_at',now()-interval '3 hours','end_at',now()-interval '2 hours','total',4,'defect',1,'reason','완료LOT 불량 경계 시험'),gen_random_uuid());
 END LOOP;
 PERFORM public.test_assert((SELECT state='DONE' FROM public.dnm_v4_records WHERE id=third_route),'all confirmed operations make the civilian LOT complete');
 amount:=(public.dnm_v410_plan_info(third_order)->>'allocated')::bigint;
 PERFORM public.dnm_v410_lot('terminate',jsonb_build_object('id',third_route,'version',pg_temp.v410_version(third_route),'reason','전량처리 후 확정불량 최종 중단'),gen_random_uuid());
 PERFORM public.test_assert((SELECT state='TERMINATED' FROM public.dnm_v4_records WHERE id=third_route),'DONE LOT with confirmed defects can terminate before final inspection');
 PERFORM public.test_assert((public.dnm_v410_plan_info(third_order)->>'allocated')::bigint=amount,'terminating a DONE LOT retains its allocation');
 SELECT id INTO third_route FROM public.dnm_v4_records WHERE parent_id=third_order AND kind='routing' AND data->>'qty'='6';
 PERFORM public.dnm_v4_command('release_routing',jsonb_build_object('id',third_route,'version',pg_temp.v410_version(third_route)),gen_random_uuid());
 FOR item IN SELECT to_jsonb(x) FROM public.dnm_v4_records x WHERE x.parent_id=third_route AND x.kind='operation' ORDER BY (x.data->>'seq')::int LOOP
  operation_id:=(item->>'id')::uuid;
  result:=public.dnm_v410_work('manual',jsonb_build_object('id',operation_id,'version',item->'version','employee_id',employee_id,'equipment_id',equipment_id,'start_at',now()-interval '3 hours','end_at',now()-interval '2 hours','total',6,'defect',0,'reason','무불량완료 경계 시험'),gen_random_uuid());
 END LOOP;
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_lot(''terminate'',%L::jsonb,gen_random_uuid())',jsonb_build_object('id',third_route,'version',pg_temp.v410_version(third_route),'reason','무불량 중단시도')::text),'DONE LOT without confirmed defect cannot terminate');
 result:=public.dnm_v493_quality(jsonb_build_object('id',third_order,'version',pg_temp.v410_version(third_order),'stage','FINAL','total',6,'defect',1,'inspection_method','dimension','operation_id',operation_id,'criterion','시험 치수','note','최종검사 불량 경계','report_no','T410-FINAL'),gen_random_uuid());
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_lot(''terminate'',%L::jsonb,gen_random_uuid())',jsonb_build_object('id',third_route,'version',pg_temp.v410_version(third_route),'reason','최종검사후 중단시도')::text),'DONE LOT with final inspection cannot terminate');
 PERFORM public.test_assert((SELECT state='DONE' FROM public.dnm_v4_records WHERE id=third_route),'failed post-inspection termination preserves completed state');
 -- Existing defense routes remain sequence-controlled and incompatible with civilian cancellation.
 result:=public.dnm_v4_command('save_order',jsonb_build_object('data',jsonb_build_object('production_no','T410-DEFENSE','customer','시험고객','part_no','T410-DEF','qty',10)),gen_random_uuid());defense_order:=(result->>'id')::uuid;
 steps:=jsonb_set(steps,'{1,independent}','false');
 result:=public.dnm_v4_command('save_routing',jsonb_build_object('order_id',defense_order,'order_version',pg_temp.v410_version(defense_order),'manager_id',admin_id,'lot','DEF-410','steps',steps),gen_random_uuid());route_id:=(result->>'id')::uuid;
 PERFORM public.dnm_v4_command('release_routing',jsonb_build_object('id',route_id,'version',pg_temp.v410_version(route_id)),gen_random_uuid());
 SELECT id INTO later_operation FROM public.dnm_v4_records WHERE kind='operation' AND parent_id=route_id ORDER BY (data->>'seq')::integer DESC LIMIT 1;
 INSERT INTO test410_refs VALUES('unrelated_operation',later_operation),('unrelated_order',defense_order);
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v4_command(''start_work'',%L::jsonb,gen_random_uuid())',jsonb_build_object('id',later_operation,'version',pg_temp.v410_version(later_operation))::text),'defense cannot skip the predecessor','선행');
 PERFORM pg_temp.v410_reject(format('SELECT public.dnm_v410_lot(''cancel'',%L::jsonb,gen_random_uuid())',jsonb_build_object('id',route_id,'version',pg_temp.v410_version(route_id),'reason','방산 취소 시도')::text),'civilian cancellation rejects defense sheets');
 PERFORM public.test_assert((SELECT name='이전 버전 보존 시험품' FROM public.dnm_portal_products WHERE code='LEGACY-V3'),'v3 product survives full upgrade and workflows');
 RAISE NOTICE 'PASS: v410 lifecycle integration complete';
END $$;
-- Row-level visibility is exercised with the real restricted database role.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','41000000-0000-4000-8000-000000000001',true);
SELECT public.test_assert(EXISTS(SELECT FROM public.dnm_v4_records WHERE id=(SELECT id FROM test410_refs WHERE name='actual_worklog')),'actual substitute can read own retained worklog under RLS');
SELECT public.test_assert(EXISTS(SELECT FROM public.dnm_v4_records WHERE id=(SELECT id FROM test410_refs WHERE name='actual_operation')),'actual substitute can read linked operation under RLS');
SELECT public.test_assert(EXISTS(SELECT FROM public.dnm_v4_records WHERE id=(SELECT id FROM test410_refs WHERE name='actual_route')),'actual substitute can read linked route under RLS');
SELECT public.test_assert(NOT EXISTS(SELECT FROM public.dnm_v4_records WHERE id=(SELECT id FROM test410_refs WHERE name='unrelated_operation')),'unrelated operation remains hidden under RLS');
SELECT public.test_assert(NOT EXISTS(SELECT FROM public.dnm_v4_records WHERE id=(SELECT id FROM test410_refs WHERE name='unrelated_order')),'unrelated defense order remains hidden under RLS');
RESET ROLE;
ROLLBACK;
