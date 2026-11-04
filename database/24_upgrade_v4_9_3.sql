-- DNM MES 4.9.3. Apply to the existing 4.9.2 database.
BEGIN;
SELECT pg_advisory_xact_lock(164040,1);
DO $$ BEGIN
 IF to_regprocedure('public.dnm_v492_process(uuid,integer,text,text,boolean)') IS NULL THEN
  RAISE EXCEPTION '4.9.2 SQL(23) 적용 여부를 확인하세요.';
 END IF;
END $$;

CREATE OR REPLACE FUNCTION dnm_private.daily_plan(o public.dnm_v4_records,p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE n bigint; allocated bigint; day date; mode text:=coalesce(p->>'production_mode','standard');
BEGIN
 IF mode NOT IN('standard','daily_assigned','daily_direct') THEN RAISE EXCEPTION '생산 방식을 확인하세요.'; END IF;
 IF EXISTS(SELECT FROM public.dnm_v4_records r WHERE kind='routing' AND parent_id=o.id AND state IN('DRAFT','RELEASED','DONE')
  AND (r.data->>'daily' IS NOT DISTINCT FROM 'true')<>(mode<>'standard')) THEN
  RAISE EXCEPTION '한 수주에 방산 전량 시트와 민수 분할 시트를 혼용할 수 없습니다.'; END IF;
 IF mode='daily_direct' THEN PERFORM dnm_private.need('routing','update'); END IF;
 IF mode='standard' THEN RETURN '{}'::jsonb; END IF;
 n:=public.dnm_v4_qty(p->'daily_qty','일일 계획수량',false);
 day:=(p->>'plan_date')::date;
 IF day IS NULL OR day NOT BETWEEN '2000-01-01' AND '2100-12-31' THEN RAISE EXCEPTION '작업 예정일을 확인하세요.'; END IF;
 SELECT coalesce(sum((data->>'qty')::bigint),0) INTO allocated FROM public.dnm_v4_records
 WHERE kind='routing' AND parent_id=o.id AND state IN('DRAFT','RELEASED','DONE') AND data->>'daily'='true';
 IF n+allocated>(o.data->>'qty')::bigint THEN RAISE EXCEPTION '남은 계획 가능 수량은 %개입니다.',(o.data->>'qty')::bigint-allocated; END IF;
 RETURN jsonb_build_object('daily',true,'field_direct',mode='daily_direct','plan_date',day,'qty',n);
END $$;

CREATE OR REPLACE FUNCTION dnm_private.daily_order_guard() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
DECLARE planned numeric;
BEGIN
 SELECT sum((data->>'qty')::numeric) INTO planned FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=OLD.id AND data->>'daily'='true' AND state IN('DRAFT','RELEASED','DONE');
 IF planned IS NOT NULL AND ((NEW.data->>'qty')::numeric<planned OR NEW.data->>'part_no' IS DISTINCT FROM OLD.data->>'part_no') THEN
  RAISE EXCEPTION '민수 일일 시트의 품번과 계획수량 합계를 확인하세요.'; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS dnm_v493_order_guard ON public.dnm_v4_records;
CREATE TRIGGER dnm_v493_order_guard BEFORE UPDATE OF data ON public.dnm_v4_records FOR EACH ROW
 WHEN(OLD.kind='order' AND ((OLD.data->'qty') IS DISTINCT FROM (NEW.data->'qty') OR (OLD.data->'part_no') IS DISTINCT FROM (NEW.data->'part_no')))
 EXECUTE FUNCTION dnm_private.daily_order_guard();

-- Quality observations are attached to a specific order and, for visual inspection, to its operation.
CREATE OR REPLACE FUNCTION dnm_private.inspection_details(orderid uuid,p jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE op public.dnm_v4_records; ro public.dnm_v4_records; method text:=p->>'inspection_method'; crit text;
BEGIN
 IF coalesce(method,'')='' THEN RETURN '{}';END IF;
 IF method NOT IN('visual','dimension','functional','other') THEN RAISE EXCEPTION '검사방법을 확인하세요.'; END IF;
 IF method='visual' AND p->>'stage'='INPROCESS' AND nullif(p->>'operation_id','') IS NULL THEN RAISE EXCEPTION '공정 육안검사는 대상 Routing 공정을 선택하세요.'; END IF;
 IF nullif(p->>'operation_id','') IS NOT NULL THEN
  SELECT * INTO op FROM public.dnm_v4_records WHERE id=(p->>'operation_id')::uuid AND kind='operation';
  SELECT * INTO ro FROM public.dnm_v4_records WHERE id=op.parent_id AND kind='routing' AND parent_id=orderid AND state IN('RELEASED','DONE');
  IF ro.id IS NULL THEN RAISE EXCEPTION '해당 수주의 유효한 Routing 공정을 선택하세요.';END IF;
  IF (p->>'total')::numeric>(op.data->>'qty')::numeric THEN RAISE EXCEPTION '선택한 공정의 계획수량을 초과합니다.';END IF;
  IF p->>'stage'='FINAL' AND ro.data->>'daily'='true' AND (ro.state<>'DONE' OR
   (p->>'total')::numeric+(SELECT coalesce(sum((q.data->>'total')::numeric),0) FROM public.dnm_v4_records q
    WHERE q.kind='quality' AND q.parent_id=orderid AND q.state='CONFIRMED' AND q.data->>'stage'='FINAL' AND q.data->>'route_id'=ro.id::text)>(ro.data->>'qty')::numeric)
  THEN RAISE EXCEPTION '선택한 일일 시트의 생산완료 여부와 누적 검사수량을 확인하세요.';END IF;
 END IF;
 crit:=btrim(coalesce(p->>'criterion',''));
 IF length(crit)>500 OR (method='visual' AND crit='') THEN RAISE EXCEPTION '검사 기준·확인 항목을 500자 이내로 입력하세요.'; END IF;
 IF method='visual' AND (p->>'defect')::numeric>0 THEN PERFORM public.dnm_v4_required(p->>'note','결함·조치 내용',2000);END IF;
 RETURN jsonb_build_object('inspection_method',method,'criterion',crit,'operation_id',op.id,'operation_name',op.title,
 'route_id',ro.id,'route_code',ro.code,'lot',ro.data->>'lot','inspector_name',(SELECT display_name FROM public.dnm_portal_profiles WHERE id=auth.uid()));
END $$;

-- Limit changes to the named branches of the installed 4.9.2 implementation.
CREATE OR REPLACE FUNCTION pg_temp.patch493(before_text text,after_text text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE src text:=pg_get_functiondef('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)'::regprocedure);
BEGIN
 IF strpos(src,after_text)>0 THEN RETURN; END IF;
 IF (length(src)-length(replace(src,before_text,'')))/length(before_text)<>1 THEN RAISE EXCEPTION '설치된 업무 SQL과 4.9.2 버전이 일치하지 않습니다. 적용을 중단합니다.'; END IF;
 EXECUTE replace(src,before_text,after_text);
END $$;
SELECT pg_temp.patch493($old$uid uuid:=auth.uid();role_name text;old$old$,$new$plan jsonb; uid uuid:=auth.uid();role_name text;old$new$);
SELECT pg_temp.patch493($old$arr:=payload->'steps';PERFORM public.dnm_v41_validate_steps(arr);$old$,$new$plan:=dnm_private.daily_plan(parent,payload);
  arr:=payload->'steps';PERFORM public.dnm_v41_validate_steps(arr);$new$);
SELECT pg_temp.patch493($old$IF EXISTS(SELECT 1 FROM public.dnm_v4_records w JOIN public.dnm_v4_records op ON w.parent_id=op.id JOIN public.dnm_v4_records ro ON op.parent_id=ro.id WHERE ro.parent_id=pid AND w.kind='worklog' AND w.state<>'CANCELLED') OR EXISTS(SELECT 1 FROM public.dnm_v4_records ro WHERE ro.kind='routing' AND ro.parent_id=pid AND ro.state='DONE') THEN RAISE$old$,$new$IF coalesce(plan->>'daily','false')<>'true' AND (EXISTS(SELECT 1 FROM public.dnm_v4_records w JOIN public.dnm_v4_records op ON w.parent_id=op.id JOIN public.dnm_v4_records ro ON op.parent_id=ro.id WHERE ro.parent_id=pid AND w.kind='worklog' AND w.state<>'CANCELLED') OR EXISTS(SELECT 1 FROM public.dnm_v4_records ro WHERE ro.kind='routing' AND ro.parent_id=pid AND ro.state='DONE')) THEN RAISE$new$);
SELECT pg_temp.patch493($old$IF EXISTS(SELECT 1 FROM public.dnm_v4_records ev JOIN public.dnm_v4_records op ON ev.parent_id=op.id JOIN public.dnm_v4_records ro ON op.parent_id=ro.id WHERE ro.parent_id=pid AND ev.kind='material') THEN RAISE$old$,$new$IF coalesce(plan->>'daily','false')<>'true' AND (EXISTS(SELECT 1 FROM public.dnm_v4_records ev JOIN public.dnm_v4_records op ON ev.parent_id=op.id JOIN public.dnm_v4_records ro ON op.parent_id=ro.id WHERE ro.parent_id=pid AND ev.kind='material')) THEN RAISE$new$);
SELECT pg_temp.patch493($old$IF EXISTS(SELECT 1 FROM public.dnm_v4_records w JOIN public.dnm_v4_records op ON w.parent_id=op.id JOIN public.dnm_v4_records ro ON op.parent_id=ro.id WHERE ro.parent_id=old.parent_id AND w.kind='worklog' AND w.state<>'CANCELLED') THEN RAISE$old$,$new$IF coalesce(old.data->>'daily','false')<>'true' AND (EXISTS(SELECT 1 FROM public.dnm_v4_records w JOIN public.dnm_v4_records op ON w.parent_id=op.id JOIN public.dnm_v4_records ro ON op.parent_id=ro.id WHERE ro.parent_id=old.parent_id AND w.kind='worklog' AND w.state<>'CANCELLED')) THEN RAISE$new$);
SELECT pg_temp.patch493($old$IF EXISTS(SELECT 1 FROM public.dnm_v4_records ro WHERE ro.kind='routing' AND ro.parent_id=old.parent_id AND ro.state='DONE') OR EXISTS(SELECT 1 FROM public.dnm_v4_records ev JOIN public.dnm_v4_records op ON ev.parent_id=op.id JOIN public.dnm_v4_records ro ON op.parent_id=ro.id WHERE ro.parent_id=old.parent_id AND ev.kind='material') THEN RAISE$old$,$new$IF coalesce(old.data->>'daily','false')<>'true' AND (EXISTS(SELECT 1 FROM public.dnm_v4_records ro WHERE ro.kind='routing' AND ro.parent_id=old.parent_id AND ro.state='DONE') OR EXISTS(SELECT 1 FROM public.dnm_v4_records ev JOIN public.dnm_v4_records op ON ev.parent_id=op.id JOIN public.dnm_v4_records ro ON op.parent_id=ro.id WHERE ro.parent_id=old.parent_id AND ev.kind='material')) THEN RAISE$new$);
SELECT pg_temp.patch493($old$r:=public.dnm_v4_put('routing',parent.code||'-R'||rev,parent.title,'DRAFT',pid,d);$old$,$new$d:=d||plan;
  r:=public.dnm_v4_put('routing',parent.code||CASE WHEN plan?'daily' THEN '-D' ELSE '-R' END||rev,parent.title,CASE WHEN plan->>'field_direct'='true' THEN 'RELEASED' ELSE 'DRAFT' END,pid,d);$new$);
SELECT pg_temp.patch493($old$other:=public.dnm_v4_put('operation',target_id::text||'-'||i,item->>'name','DRAFT',target_id,v);$old$,$new$v:=v||plan;
   IF plan->>'field_direct'='true' THEN v:=v||jsonb_build_object('employee_ids','[]'::jsonb,'employee_id',null,'equipment_id','');END IF;
   other:=public.dnm_v4_put('operation',target_id::text||'-'||i,item->>'name',CASE WHEN plan->>'field_direct'='true' THEN 'WAIT' ELSE 'DRAFT' END,target_id,v);$new$);
SELECT pg_temp.patch493($old$SET state='SUPERSEDED' WHERE kind='routing' AND parent_id=old.parent_id$old$,$new$SET state='SUPERSEDED' WHERE old.data->>'daily' IS DISTINCT FROM 'true' AND kind='routing' AND parent_id=old.parent_id$new$);
SELECT pg_temp.patch493($old$IF parent.state<>'RELEASED' THEN RAISE EXCEPTION '배포된 Routing이 아닙니다.';END IF;$old$,$new$IF parent.state<>'RELEASED' THEN RAISE EXCEPTION '배포된 Routing이 아닙니다.';END IF;
  IF parent.data->>'field_direct'='true' AND (nullif(payload->>'field_equipment','') IS NULL OR payload->>'field_equipment' IS DISTINCT FROM old.data->>'equipment_id' OR old.state<>'WAIT' OR p_action<>'start_work') THEN RAISE EXCEPTION '민수 현장 작업 시작에서 실제 설비를 선택하세요.';END IF;$new$);
SELECT pg_temp.patch493($old$IF NOT EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=old.id AND state IN('RELEASED','DONE')) OR EXISTS(SELECT 1 FROM public.dnm_v4_records op JOIN public.dnm_v4_records ro ON ro.id=op.parent_id WHERE ro.parent_id=old.id AND ro.state IN('RELEASED','DONE') AND op.kind='operation' AND op.state<>'DONE') THEN RAISE EXCEPTION '배포 Routing의 모든 공정 완료 후 최종검사 확정이 가능합니다.';END IF;$old$,$new$IF EXISTS(SELECT FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=old.id AND data->>'daily'='true' AND state IN('DRAFT','RELEASED','DONE')) THEN
     SELECT coalesce(sum((data->>'qty')::numeric),0) INTO total FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=old.id AND state='DONE' AND data->>'daily'='true';
     IF n+(SELECT coalesce(sum((data->>'total')::numeric),0) FROM public.dnm_v4_records WHERE kind='quality' AND parent_id=old.id AND state='CONFIRMED' AND data->>'stage'='FINAL')>total THEN RAISE EXCEPTION '완료한 민수 일일 시트의 누적 생산수량까지만 최종검사할 수 있습니다.';END IF;
    ELSIF NOT EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=old.id AND state IN('RELEASED','DONE')) OR EXISTS(SELECT 1 FROM public.dnm_v4_records op JOIN public.dnm_v4_records ro ON ro.id=op.parent_id WHERE ro.parent_id=old.id AND ro.state IN('RELEASED','DONE') AND op.kind='operation' AND op.state<>'DONE') THEN RAISE EXCEPTION '배포 Routing의 모든 공정 완료 후 최종검사 확정이 가능합니다.';END IF;$new$);
SELECT pg_temp.patch493($old$'inspected_by',uid);k:='quality';$old$,$new$'inspected_by',uid)||dnm_private.inspection_details(old.id,payload);k:='quality';$new$);
-- These wrappers also prevent a new form from silently saving through an older database.
-- Only disclose the unallocated quantity for an order the planner can already open.
CREATE OR REPLACE FUNCTION public.dnm_v493_plan_info(p_order uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE o public.dnm_v4_records; whole int; daily int; planned bigint;
BEGIN
 PERFORM dnm_private.need('orders','read');PERFORM dnm_private.need('routing','create');
 SELECT * INTO o FROM public.dnm_v4_records WHERE id=p_order AND kind='order' AND state='OPEN';
 IF o.id IS NULL OR NOT public.dnm_v4_readable(o.kind,o.data,o.created_by,o.id) THEN RAISE EXCEPTION '조회 가능한 진행 중 수주를 선택하세요.';END IF;
 SELECT count(*) FILTER(WHERE data->>'daily' IS DISTINCT FROM 'true'),count(*) FILTER(WHERE data->>'daily'='true'),
 coalesce(sum((data->>'qty')::bigint) FILTER(WHERE data->>'daily'='true'),0)
 INTO whole,daily,planned FROM public.dnm_v4_records WHERE parent_id=p_order AND kind='routing' AND state IN('DRAFT','RELEASED','DONE');
 RETURN jsonb_build_object('ok',true,'standard_count',whole,'daily_count',daily,'remaining',(o.data->>'qty')::bigint-planned);
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v493_daily_save(p jsonb,k uuid) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 SELECT public.dnm_v4_command('save_routing',p,k)
$$;
CREATE OR REPLACE FUNCTION public.dnm_v493_quality(p jsonb,k uuid) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 SELECT public.dnm_v4_command('quality',p,k)
$$;
CREATE OR REPLACE FUNCTION public.dnm_v493_inspection_ops(p_order uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE o public.dnm_v4_records; rows jsonb;
BEGIN
 PERFORM dnm_private.need('quality','create');
 SELECT * INTO o FROM public.dnm_v4_records WHERE id=p_order AND kind='order';
 IF o.id IS NULL OR NOT public.dnm_v4_readable(o.kind,o.data,o.created_by,o.id) THEN RAISE EXCEPTION '조회 가능한 수주를 선택하세요.'; END IF;
 SELECT jsonb_agg(jsonb_build_object('id',op.id,'name',r.code||' / '||(op.data->>'op_code')||' '||op.title) ORDER BY r.code, (op.data->>'seq')::int) INTO rows
 FROM public.dnm_v4_records r JOIN public.dnm_v4_records op ON op.parent_id=r.id AND op.kind='operation'
 WHERE r.kind='routing' AND r.parent_id=o.id AND r.state IN('DONE','RELEASED');
 RETURN jsonb_build_object('ok',true,'rows',coalesce(rows,'[]'));
END $$;
CREATE OR REPLACE FUNCTION dnm_private.field_worker() RETURNS public.dnm_v4_records
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE e public.dnm_v4_records;
BEGIN
 PERFORM dnm_private.need('worklogs','create');PERFORM dnm_private.need('worklogs','update');
 SELECT * INTO e FROM public.dnm_v4_records WHERE kind='employee' AND data->>'active'='true' AND data->>'profile_id'=auth.uid()::text;
 IF e.id IS NULL THEN RAISE EXCEPTION '이 계정에 연결된 사용 중인 작업자로 로그인하세요.';END IF;
 RETURN e;
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v493_field_choices() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE e public.dnm_v4_records; jobs jsonb; machines jsonb;
BEGIN
 e:=dnm_private.field_worker();
 SELECT jsonb_agg(jsonb_build_object('id',op.id,'version',op.version,'day',r.data->>'plan_date','route',r.code,'part',r.data->>'part_no','name',op.title,'seq',op.data->>'op_code',
 'remaining',(op.data->>'qty')::bigint-coalesce((op.data->>'confirmed_qty')::bigint,0)) ORDER BY r.data->>'plan_date',r.code,(op.data->>'seq')::int) INTO jobs
 FROM public.dnm_v4_records op JOIN public.dnm_v4_records r ON r.id=op.parent_id
 WHERE r.kind='routing' AND r.state='RELEASED' AND r.data->>'field_direct'='true' AND op.kind='operation' AND op.data->>'kind'='WORK' AND op.state='WAIT'
 AND NOT EXISTS(SELECT FROM public.dnm_v4_records prior WHERE prior.kind='operation' AND prior.parent_id=r.id AND (prior.data->>'seq')::int<(op.data->>'seq')::int AND prior.state<>'DONE');
 SELECT jsonb_agg(jsonb_build_object('id',id,'name',title,'code',code) ORDER BY title,code) INTO machines FROM public.dnm_v4_records WHERE kind='equipment' AND data->>'active'='true';
 RETURN jsonb_build_object('ok',true,'worker',e.title,'jobs',coalesce(jobs,'[]'),'machines',coalesce(machines,'[]'));
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v493_field_start(p_id uuid,p_version integer,p_equipment uuid,k uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE op public.dnm_v4_records; r public.dnm_v4_records; e public.dnm_v4_records; prev public.dnm_v4_requests; h text; result jsonb; team jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(164040,1); e:=dnm_private.field_worker();
 IF k IS NULL OR p_equipment IS NULL OR p_id IS NULL OR p_version IS NULL THEN RAISE EXCEPTION '일일 공정과 실제 설비를 선택하세요.';END IF;
 h:=md5(jsonb_build_array('field_start',p_id,p_version,p_equipment)::text);
 SELECT * INTO prev FROM public.dnm_v4_requests WHERE actor_id=auth.uid() AND request_key=k;
 IF FOUND THEN IF prev.payload_hash<>h THEN RAISE EXCEPTION '요청번호가 이미 사용되었습니다.';END IF;RETURN prev.result;END IF;
 SELECT * INTO op FROM public.dnm_v4_records WHERE id=p_id AND kind='operation' FOR UPDATE;
 SELECT * INTO r FROM public.dnm_v4_records WHERE id=op.parent_id AND kind='routing';
 IF r.data->>'field_direct' IS DISTINCT FROM 'true' OR r.state<>'RELEASED' OR op.data->>'kind' IS DISTINCT FROM 'WORK' OR op.state<>'WAIT' OR op.version IS DISTINCT FROM p_version THEN
  RAISE EXCEPTION '시작할 수 있는 민수 공정을 다시 선택하세요.';END IF;
 team:=public.dnm_v45_team(op.title,p_equipment,jsonb_build_array(e.id), (r.data->>'manager_id')::uuid);
 UPDATE public.dnm_v4_records SET data=data||team WHERE id=op.id RETURNING * INTO op;
 result:=public.dnm_v4_command('start_work',jsonb_build_object('id',op.id,'version',op.version,'employee_id',e.id,'field_equipment',p_equipment,'work_date',(now() AT TIME ZONE 'Asia/Seoul')::date),k);
 UPDATE public.dnm_v4_requests SET action='field_start',payload_hash=h WHERE actor_id=auth.uid() AND request_key=k;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v493_void_daily(p_id uuid,p_version int,p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dnm_v4_records;
BEGIN
 PERFORM dnm_private.need('routing','update');PERFORM pg_advisory_xact_lock(164040,1);
 SELECT * INTO r FROM public.dnm_v4_records WHERE id=p_id AND kind='routing' FOR UPDATE;
 IF r.data->>'daily' IS DISTINCT FROM 'true' OR (public.dnm_portal_role()<>'admin' AND r.data->>'manager_id' IS DISTINCT FROM auth.uid()::text) THEN RAISE EXCEPTION '담당자의 일일 시트만 취소할 수 있습니다.';END IF;
 IF r.state='CANCELLED' THEN RETURN '{"ok":true}';END IF;
 IF r.version IS DISTINCT FROM p_version OR r.state NOT IN('DRAFT','RELEASED') OR EXISTS(SELECT FROM public.dnm_v4_records op JOIN public.dnm_v4_records child ON child.parent_id=op.id WHERE op.kind='operation' AND op.parent_id=r.id) OR
 EXISTS(SELECT FROM public.dnm_v4_records WHERE kind='quality' AND data->>'route_id'=r.id::text) THEN RAISE EXCEPTION '변경되었거나 작업·검사 이력이 있는 시트입니다.';END IF;
 UPDATE public.dnm_v4_records SET state='CANCELLED',data=data||jsonb_build_object('cancel_reason',public.dnm_v4_required(p_reason,'취소 사유',500)) WHERE id=r.id;
 UPDATE public.dnm_v4_records SET state='CANCELLED' WHERE kind='operation' AND parent_id=r.id;
 RETURN '{"ok":true}';
END $$;
REVOKE ALL ON FUNCTION dnm_private.daily_plan(public.dnm_v4_records,jsonb),dnm_private.daily_order_guard(),dnm_private.inspection_details(uuid,jsonb),dnm_private.field_worker() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.dnm_v493_plan_info(uuid),public.dnm_v493_daily_save(jsonb,uuid),public.dnm_v493_quality(jsonb,uuid),public.dnm_v493_inspection_ops(uuid),public.dnm_v493_field_choices(),public.dnm_v493_field_start(uuid,int,uuid,uuid),public.dnm_v493_void_daily(uuid,int,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dnm_v493_plan_info(uuid),public.dnm_v493_daily_save(jsonb,uuid),public.dnm_v493_quality(jsonb,uuid),public.dnm_v493_inspection_ops(uuid),public.dnm_v493_field_choices(),public.dnm_v493_field_start(uuid,int,uuid,uuid),public.dnm_v493_void_daily(uuid,int,text) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
