-- DNM MES 4.10.0. Run AFTER 26_upgrade_v4_9_5.sql in the existing project.
-- Additive, retry-safe upgrade. Business rows are retained, including cancelled LOTs.
-- SQL27 revision 2 (2026-11-12): accept both LF and Windows CRLF paste formats.
-- Existing leave-management tables, employee-number links and sync settings are retained.
BEGIN;
SELECT pg_advisory_xact_lock(164040,1);
DO $$ BEGIN
 IF to_regprocedure('public.dnm_v495_change_po(text,jsonb,uuid)') IS NULL THEN
  RAISE EXCEPTION '4.9.5 업데이트 SQL(26)을 먼저 적용하세요.';
 END IF;
END $$;

CREATE OR REPLACE FUNCTION dnm_private.v410_order_type(o public.dnm_v4_records) RETURNS text
LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT coalesce(nullif(o.data->>'order_type',''),CASE WHEN EXISTS(
  SELECT FROM public.dnm_v4_records r WHERE r.kind='routing' AND r.parent_id=o.id AND r.data->>'daily'='true'
 ) THEN 'CIVIL' ELSE 'DEFENSE' END)
$$;
CREATE OR REPLACE FUNCTION dnm_private.v410_allocated(oid uuid,exclude_id uuid DEFAULT NULL) RETURNS bigint
LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT coalesce(sum((r.data->>'qty')::bigint),0)::bigint FROM public.dnm_v4_records r
 WHERE r.kind='routing' AND r.parent_id=oid AND r.data->>'daily'='true'
 AND r.state NOT IN('CANCELLED','SUPERSEDED') AND (exclude_id IS NULL OR r.id<>exclude_id)
$$;

-- Preserve the deployed validator, including all previous import/number validation.
DO $$ BEGIN
 IF to_regprocedure('dnm_private.v495_order_valid(jsonb)') IS NULL THEN
  ALTER FUNCTION public.dnm_v4_order_valid(jsonb) RENAME TO v495_order_valid;
  ALTER FUNCTION public.v495_order_valid(jsonb) SET SCHEMA dnm_private;
 END IF;
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v4_order_valid(d jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE result jsonb; field_name text;
BEGIN
 result:=dnm_private.v495_order_valid(d);
 IF d ? 'order_type' AND (d->>'order_type' IS NULL OR d->>'order_type' NOT IN('CIVIL','DEFENSE')) THEN
  RAISE EXCEPTION '수주 구분은 민수 또는 방산으로 지정하세요.';
 END IF;
 FOREACH field_name IN ARRAY ARRAY['shop_order_no','heat_code'] LOOP
  IF d ? field_name THEN
   IF jsonb_typeof(d->field_name) IS DISTINCT FROM 'string' OR length(d->>field_name)>100 THEN
    RAISE EXCEPTION 'Shop Order No.와 Heat Code는 100자 이내 문자로 입력하세요.';
   END IF;
   result:=jsonb_set(result,ARRAY[field_name],to_jsonb(btrim(d->>field_name)));
  END IF;
 END LOOP;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION dnm_private.daily_order_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE planned bigint; current_type text;
BEGIN
 PERFORM pg_advisory_xact_lock(164040,1);
 planned:=dnm_private.v410_allocated(OLD.id);
 IF EXISTS(SELECT FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=OLD.id) THEN
  current_type:=dnm_private.v410_order_type(OLD);
  IF coalesce(nullif(NEW.data->>'order_type',''),current_type)<>current_type THEN
   RAISE EXCEPTION 'Routing 이력이 있는 수주의 민수·방산 구분은 변경할 수 없습니다.';
  END IF;
 END IF;
 IF (planned>0 AND NEW.data->>'part_no' IS DISTINCT FROM OLD.data->>'part_no') OR
    coalesce((NEW.data->>'qty')::numeric,0)<planned THEN
  RAISE EXCEPTION '민수 LOT의 품번과 배정수량 합계 %개를 확인하세요. 중단 LOT도 배정수량에 포함됩니다.',planned;
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS dnm_v493_order_guard ON public.dnm_v4_records;
CREATE TRIGGER dnm_v493_order_guard BEFORE UPDATE OF data ON public.dnm_v4_records FOR EACH ROW
 WHEN(OLD.kind='order') EXECUTE FUNCTION dnm_private.daily_order_guard();

CREATE OR REPLACE FUNCTION dnm_private.daily_plan(o public.dnm_v4_records,p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE n bigint; allocated bigint; day date; mode text:=coalesce(p->>'production_mode','standard'); typ text;
BEGIN
 PERFORM pg_advisory_xact_lock(164040,1);
 typ:=dnm_private.v410_order_type(o);
 IF mode NOT IN('standard','daily_assigned','daily_direct') THEN RAISE EXCEPTION '생산 방식을 확인하세요.'; END IF;
 IF (o.data->>'order_type'='DEFENSE' AND mode<>'standard') OR (typ='CIVIL' AND mode='standard') THEN
  RAISE EXCEPTION '민수 수주는 민수 LOT로, 방산 수주는 방산 Routing으로 작성하세요.';
 END IF;
 IF EXISTS(SELECT FROM public.dnm_v4_records r WHERE kind='routing' AND parent_id=o.id
  AND state NOT IN('CANCELLED','SUPERSEDED') AND (r.data->>'daily' IS NOT DISTINCT FROM 'true')<>(mode<>'standard')) THEN
  RAISE EXCEPTION '한 수주에 방산 시트와 민수 LOT를 혼용할 수 없습니다.';
 END IF;
 IF mode='standard' THEN RETURN '{}'::jsonb; END IF;
 IF mode='daily_direct' THEN PERFORM dnm_private.need('routing','update'); END IF;
 n:=public.dnm_v4_qty(p->'daily_qty','LOT 계획수량',false);day:=(p->>'plan_date')::date;
 IF day IS NULL OR day NOT BETWEEN '2000-01-01' AND '2100-12-31' THEN RAISE EXCEPTION '작업 예정일을 확인하세요.'; END IF;
 allocated:=dnm_private.v410_allocated(o.id);
 IF n+allocated>(o.data->>'qty')::bigint THEN RAISE EXCEPTION '남은 배정 가능 수량은 %개입니다.',(o.data->>'qty')::bigint-allocated; END IF;
 RETURN jsonb_build_object('daily',true,'order_type','CIVIL','field_direct',mode='daily_direct','plan_date',day,'qty',n);
END $$;

-- All writers share the existing transaction lock. Cancelled numbers are never reused.
CREATE OR REPLACE FUNCTION dnm_private.v410_route_code(o public.dnm_v4_records,plan jsonb,revision integer) RETURNS text
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE prefix text; serial bigint;
BEGIN
 IF plan->>'daily' IS DISTINCT FROM 'true' THEN RETURN o.code||'-R'||revision; END IF;
 PERFORM pg_advisory_xact_lock(164040,1);
 prefix:=to_char((plan->>'plan_date')::date,'YYMM');
 SELECT coalesce(max(substring(v FROM 6)::bigint),0)+1 INTO serial FROM (
  SELECT code v FROM public.dnm_v4_records WHERE kind='routing'
  UNION ALL SELECT data->>'lot' FROM public.dnm_v4_records WHERE kind='routing'
 ) all_codes WHERE v~('^'||prefix||'-[0-9]{1,12}$');
 RETURN prefix||'-'||lpad(serial::text,greatest(4,length(serial::text)),'0');
END $$;

-- Called inside the original private implementation so older wrappers and setup tools
-- receive the same terminal-state and order-open protections.
CREATE OR REPLACE FUNCTION dnm_private.v410_command_guard(act text,p jsonb) RETURNS void
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE target public.dnm_v4_records; ro public.dnm_v4_records; ord public.dnm_v4_records;
BEGIN
 IF act NOT IN('save_routing','release_routing','assign_operation','manager_step','start_work','manual_work',
  'finish_work','confirm_work','cancel_work','pause_work') THEN RETURN; END IF;
 IF act='save_routing' THEN RETURN; END IF;
 SELECT * INTO target FROM public.dnm_v4_records WHERE id=nullif(p->>'id','')::uuid;
 IF target.kind='routing' THEN ro:=target;
 ELSIF target.kind='operation' THEN SELECT * INTO ro FROM public.dnm_v4_records WHERE id=target.parent_id AND kind='routing';
 ELSIF target.kind='worklog' THEN
  SELECT r.* INTO ro FROM public.dnm_v4_records op JOIN public.dnm_v4_records r ON r.id=op.parent_id
  WHERE op.id=target.parent_id AND op.kind='operation' AND r.kind='routing';
 END IF;
 IF ro.id IS NULL THEN RETURN; END IF;
 IF ro.state IN('CANCELLED','TERMINATED','SUPERSEDED') THEN
  RAISE EXCEPTION '취소·중단·대체된 Routing의 작업 및 배정은 변경할 수 없습니다.';
 END IF;
 SELECT * INTO ord FROM public.dnm_v4_records WHERE id=ro.parent_id AND kind='order';
 IF ord.state IS DISTINCT FROM 'OPEN' THEN RAISE EXCEPTION '진행 중인 수주의 Routing만 처리할 수 있습니다.'; END IF;
END $$;

-- Actual worker/equipment are selected per work record; the instruction's assignments
-- are only defaults. This helper returns a value, never rewrites the operation.
DROP FUNCTION IF EXISTS dnm_private.v410_actual_team(public.dnm_v4_records,public.dnm_v4_records,jsonb);
CREATE OR REPLACE FUNCTION dnm_private.v410_actual_team(ro public.dnm_v4_records,op public.dnm_v4_records,p jsonb,finishing boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE em public.dnm_v4_records; eq public.dnm_v4_records; eid uuid; equipment uuid; team jsonb;
BEGIN
 IF ro.data->>'daily' IS DISTINCT FROM 'true' THEN RETURN '{}'::jsonb; END IF;
 eid:=nullif(p->>'employee_id','')::uuid;
 equipment:=coalesce(nullif(p->>'equipment_id','')::uuid,nullif(p->>'field_equipment','')::uuid);
 IF eid IS NULL OR equipment IS NULL THEN RAISE EXCEPTION '실제 작업자와 설비를 선택하세요.'; END IF;
 SELECT * INTO em FROM public.dnm_v4_records WHERE id=eid AND kind='employee' AND data->>'active'='true';
 SELECT * INTO eq FROM public.dnm_v4_records WHERE id=equipment AND kind='equipment' AND data->>'active'='true';
 IF em.id IS NULL OR eq.id IS NULL THEN RAISE EXCEPTION '사용 중인 작업자와 설비를 선택하세요.'; END IF;
 IF public.dnm_portal_role()<>'admin' AND em.data->>'profile_id' IS DISTINCT FROM auth.uid()::text
 AND (public.dnm_v4_can('production') AND ro.data->>'manager_id'=auth.uid()::text) IS NOT TRUE THEN
  RAISE EXCEPTION '본인 작업만 등록하거나 담당 생산관리자가 실제 작업자를 지정해야 합니다.' USING ERRCODE='42501';
 END IF;
 IF finishing THEN
  IF NOT EXISTS(SELECT FROM public.dnm_portal_profiles WHERE id=nullif(em.data->>'profile_id','')::uuid AND active)
   OR NOT(dnm_private.acl_for(nullif(em.data->>'profile_id','')::uuid,'worklogs','create') OR
          dnm_private.acl_for(nullif(em.data->>'profile_id','')::uuid,'worklogs','update')) THEN
   RAISE EXCEPTION '작업자의 활성 계정과 작업일보 권한을 확인하세요.'; END IF;
  team:=jsonb_build_object('equipment_id',eq.id,'equipment_code',eq.code,'employee_id',em.id,'employee_ids',jsonb_build_array(em.id::text),
   'employee_name',em.title,'profile_id',em.data->>'profile_id','profile_ids',jsonb_build_array(em.data->>'profile_id'),'manager_id',ro.data->>'manager_id');
 ELSE
  team:=public.dnm_v45_team(op.title,equipment,jsonb_build_array(eid),(ro.data->>'manager_id')::uuid);
 END IF;
 RETURN team||jsonb_build_object('equipment_name',eq.title,'employee_department',coalesce(em.data->>'department',''));
END $$;

CREATE OR REPLACE FUNCTION pg_temp.patch410(fn regprocedure,before_text text,after_text text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE src text:=replace(pg_get_functiondef(fn),E'\r\n',E'\n');
BEGIN
 -- Dollar-quoted patch arguments retain the pasted file's line endings.
 -- Compare all three strings in the same form; retain the exact-match guard.
 before_text:=replace(before_text,E'\r\n',E'\n');
 after_text:=replace(after_text,E'\r\n',E'\n');
 IF strpos(src,after_text)>0 THEN RETURN; END IF;
 IF (length(src)-length(replace(src,before_text,'')))/length(before_text)<>1 THEN
  RAISE EXCEPTION '설치된 함수 %가 4.9.5 예상 버전과 다릅니다. 업데이트 전체를 중단합니다.',fn;
 END IF;
 EXECUTE replace(src,before_text,after_text);
END $$;
SELECT pg_temp.patch410('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)',
 $o$target_id:=nullif(payload->>'id','')::uuid;expected:=$o$,
 $n$PERFORM dnm_private.v410_command_guard(p_action,payload);
 target_id:=nullif(payload->>'id','')::uuid;expected:=$n$);
SELECT pg_temp.patch410('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)',
 $o$d:=d||plan;
  r:=public.dnm_v4_put('routing',parent.code||CASE WHEN plan?'daily' THEN '-D' ELSE '-R' END||rev,parent.title,$o$,
 $n$c:=dnm_private.v410_route_code(parent,plan,rev);
  d:=d||plan||jsonb_build_object('shop_order_no',coalesce(parent.data->>'shop_order_no',''),'heat_code',coalesce(parent.data->>'heat_code',''));
  IF plan->>'daily'='true' THEN d:=d||jsonb_build_object('lot',c,'lot_number_version','4.10.0'); END IF;
  r:=public.dnm_v4_put('routing',c,parent.title,$n$);
SELECT pg_temp.patch410('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)',
 $o$IF EXISTS(SELECT 1 FROM public.dnm_v4_records op WHERE op.parent_id=old.id AND op.kind='operation' AND op.data->>'kind'='WORK' AND (coalesce(op.data->>'equipment_id','')=''$o$,
 $n$IF old.data->>'daily' IS DISTINCT FROM 'true' AND EXISTS(SELECT 1 FROM public.dnm_v4_records op WHERE op.parent_id=old.id AND op.kind='operation' AND op.data->>'kind'='WORK' AND (coalesce(op.data->>'equipment_id','')=''$n$);
SELECT pg_temp.patch410('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)',
 $o$FOR item IN SELECT to_jsonb(op) FROM public.dnm_v4_records op WHERE op.parent_id=old.id AND op.kind='operation' AND op.data->>'kind'='WORK' LOOP$o$,
 $n$FOR item IN SELECT to_jsonb(op) FROM public.dnm_v4_records op WHERE op.parent_id=old.id AND op.kind='operation' AND op.data->>'kind'='WORK'
   AND (old.data->>'daily' IS DISTINCT FROM 'true' OR (nullif(op.data->>'equipment_id','') IS NOT NULL
    AND (jsonb_array_length(coalesce(op.data->'employee_ids','[]'))>0 OR nullif(op.data->>'employee_id','') IS NOT NULL))) LOOP$n$);
SELECT pg_temp.patch410('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)',
 $o$IF parent.data->>'field_direct'='true' AND (nullif(payload->>'field_equipment','') IS NULL OR payload->>'field_equipment' IS DISTINCT FROM old.data->>'equipment_id' OR old.state<>'WAIT') THEN RAISE EXCEPTION '민수 현장 작업 시작 또는 수기 작업일보에서 실제 설비를 선택하세요.';END IF;$o$,
 $n$IF parent.data->>'daily'='true' THEN
   old.data:=old.data||dnm_private.v410_actual_team(parent,old,payload);
  END IF;$n$);

SELECT pg_temp.patch410('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)',
 $o$v:=v||plan;$o$,
 $n$IF item ? 'skl_op_no' THEN
    IF jsonb_typeof(item->'skl_op_no') IS DISTINCT FROM 'string' OR length(item->>'skl_op_no')>40 THEN
     RAISE EXCEPTION 'SKL 공정번호는 40자 이내로 입력하세요.'; END IF;
    v:=v||jsonb_build_object('skl_op_no',btrim(item->>'skl_op_no'));
   END IF;
   v:=v||plan;$n$);

SELECT pg_temp.patch410('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)',
 $o$IF d->>'input_date'<>'' THEN PERFORM (d->>'input_date')::date;END IF;PERFORM (d->>'issue_date')::date;$o$,
 $n$FOREACH k IN ARRAY ARRAY['pwi_no','model'] LOOP
   IF payload ? k AND (jsonb_typeof(payload->k) IS DISTINCT FROM 'string' OR length(payload->>k)>100) THEN
    RAISE EXCEPTION 'PWI와 MODEL은 100자 이내로 입력하세요.'; END IF;
   d:=d||jsonb_build_object(k,btrim(coalesce(payload->>k,parent.data->>k,'')));
  END LOOP;
  IF d->>'input_date'<>'' THEN PERFORM (d->>'input_date')::date;END IF;PERFORM (d->>'issue_date')::date;$n$);

SELECT pg_temp.patch410('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)',
 $o$AND state NOT IN('DONE','CANCELLED'));result:=$o$,
 $n$AND state NOT IN('DONE','CANCELLED','TERMINATED','SUPERSEDED'));result:=$n$);

CREATE OR REPLACE FUNCTION public.dnm_v410_save_order(p jsonb,k uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
<<save_order_call>>
DECLARE previous public.dnm_v4_requests; payload jsonb:=p; o public.dnm_v4_records;
 h text; result jsonb; prefix text; serial bigint;
BEGIN
 IF auth.uid() IS NULL OR public.dnm_portal_role() IS NULL OR k IS NULL OR jsonb_typeof(p) IS DISTINCT FROM 'object'
 OR length(p::text)>50000 THEN RAISE EXCEPTION '수주 요청과 요청번호를 확인하세요.'; END IF;
 PERFORM pg_advisory_xact_lock(164040,1);h:=md5('v410_order'||p::text);
 SELECT * INTO previous FROM public.dnm_v4_requests WHERE actor_id=auth.uid() AND request_key=k;
 IF FOUND THEN IF previous.payload_hash<>h THEN RAISE EXCEPTION '다른 내용에 사용된 요청번호입니다.'; END IF;RETURN previous.result;END IF;
 IF nullif(p->>'id','') IS NOT NULL THEN
  SELECT * INTO o FROM public.dnm_v4_records WHERE id=(p->>'id')::uuid AND kind='order';
  IF o.id IS NULL THEN RAISE EXCEPTION '수주를 다시 조회하세요.'; END IF;
  payload:=jsonb_set(payload,'{data,production_no}',to_jsonb(o.code));
 ELSIF p->'data'->>'order_type'='CIVIL' AND nullif(btrim(p->'data'->>'production_no'),'') IS NULL THEN
  prefix:='CIV-'||to_char(now() AT TIME ZONE 'Asia/Seoul','YYMM');
  SELECT coalesce(max(substring(code FROM 10)::bigint),0)+1 INTO serial FROM public.dnm_v4_records
   WHERE kind='order' AND code~('^'||prefix||'-[0-9]{1,12}$');
  payload:=jsonb_set(payload,'{data,production_no}',to_jsonb(prefix||'-'||lpad(serial::text,greatest(4,length(serial::text)),'0')));
 END IF;
 result:=public.dnm_v4_command('save_order',payload,k);
 SELECT * INTO o FROM public.dnm_v4_records WHERE id=(result->>'id')::uuid;
 result:=result||jsonb_build_object('code',o.code,'version',o.version);
 UPDATE public.dnm_v4_requests SET action='v410_order',payload_hash=h,result=save_order_call.result
  WHERE actor_id=auth.uid() AND request_key=k;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.dnm_v410_plan_info(p_order uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE o public.dnm_v4_records; allocated bigint; rows jsonb; standard_count int;
BEGIN
 PERFORM dnm_private.need('orders','read');PERFORM dnm_private.need('routing','read');
 SELECT * INTO o FROM public.dnm_v4_records WHERE id=p_order AND kind='order';
 IF o.id IS NULL OR NOT public.dnm_v4_readable(o.kind,o.data,o.created_by,o.id) THEN
  RAISE EXCEPTION '조회 가능한 수주를 선택하세요.' USING ERRCODE='42501'; END IF;
 allocated:=dnm_private.v410_allocated(o.id);
 SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.code,r.id),'[]') INTO rows FROM public.dnm_v4_records r
 WHERE r.kind='routing' AND r.parent_id=o.id AND r.data->>'daily'='true'
 AND public.dnm_v4_readable(r.kind,r.data,r.created_by,r.id);
 SELECT count(*) INTO standard_count FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=o.id
 AND data->>'daily' IS DISTINCT FROM 'true' AND state NOT IN('CANCELLED','SUPERSEDED');
 RETURN jsonb_build_object('ok',true,'order_type',dnm_private.v410_order_type(o),'order_version',o.version,
  'allocated',allocated,'remaining',(o.data->>'qty')::bigint-allocated,'lots',rows,'standard_count',standard_count);
END $$;
-- Older planning screens receive the same allocation, including terminated LOTs.
CREATE OR REPLACE FUNCTION public.dnm_v493_plan_info(p_order uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
 result:=public.dnm_v410_plan_info(p_order);
 RETURN result||jsonb_build_object('daily_count',(SELECT count(*) FROM public.dnm_v4_records
 WHERE kind='routing' AND parent_id=p_order AND data->>'daily'='true' AND state NOT IN('CANCELLED','SUPERSEDED')));
END $$;

CREATE OR REPLACE FUNCTION public.dnm_v410_split(p jsonb,k uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET statement_timeout='25s' AS $$
DECLARE uid uuid:=auth.uid(); o public.dnm_v4_records; r public.dnm_v4_records; previous public.dnm_v4_requests;
 h text; remaining bigint; total bigint; unit bigint; n bigint; amounts jsonb:='[]'; amount jsonb;
 payload jsonb; result jsonb; lots jsonb:='[]'; ids jsonb:='[]'; quantity_sum bigint:=0;
BEGIN
 PERFORM dnm_private.need('routing','create');PERFORM dnm_private.need('orders','read');
 IF uid IS NULL OR k IS NULL OR jsonb_typeof(p) IS DISTINCT FROM 'object' OR length(p::text)>150000 THEN
  RAISE EXCEPTION '민수 분할 요청과 요청번호를 확인하세요.'; END IF;
 PERFORM pg_advisory_xact_lock(164040,1);h:=md5('v410_split'||p::text);
 SELECT * INTO previous FROM public.dnm_v4_requests WHERE actor_id=uid AND request_key=k;
 IF FOUND THEN IF previous.payload_hash<>h THEN RAISE EXCEPTION '다른 내용에 사용된 요청번호입니다.'; END IF;RETURN previous.result;END IF;
 SELECT * INTO o FROM public.dnm_v4_records WHERE id=(p->>'order_id')::uuid AND kind='order' FOR UPDATE;
 IF o.id IS NULL OR o.state<>'OPEN' OR NOT public.dnm_v4_readable(o.kind,o.data,o.created_by,o.id) THEN
  RAISE EXCEPTION '조회 가능한 진행 중 수주를 선택하세요.' USING ERRCODE='42501'; END IF;
 IF o.version IS DISTINCT FROM (p->>'order_version')::int THEN RAISE EXCEPTION '수주가 변경되었습니다. 다시 조회하세요.' USING ERRCODE='40001'; END IF;
 IF o.data->>'order_type'='DEFENSE' THEN RAISE EXCEPTION '방산 수주는 민수 LOT로 분할할 수 없습니다.'; END IF;
 remaining:=(o.data->>'qty')::bigint-dnm_private.v410_allocated(o.id);
 total:=CASE WHEN p ? 'total_qty' THEN public.dnm_v4_qty(p->'total_qty','이번 배정수량',false) ELSE remaining END;
 IF total<=0 OR total>remaining THEN RAISE EXCEPTION '남은 배정 가능 수량 %개 이내로 입력하세요.',remaining; END IF;
 PERFORM public.dnm_v41_validate_steps(p->'steps');
 IF p ? 'quantities' THEN
  IF jsonb_typeof(p->'quantities') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'quantities') NOT BETWEEN 1 AND 200 THEN
   RAISE EXCEPTION '한 번에 1~200개 LOT를 작성하세요.'; END IF;
  FOR amount IN SELECT value FROM jsonb_array_elements(p->'quantities') LOOP
   n:=public.dnm_v4_qty(amount,'LOT 수량',false);quantity_sum:=quantity_sum+n;amounts:=amounts||to_jsonb(n);
  END LOOP;
  IF quantity_sum<>total THEN RAISE EXCEPTION 'LOT 수량 합계와 이번 배정수량 %개가 일치해야 합니다.',total; END IF;
 ELSE
  unit:=public.dnm_v4_qty(p->'lot_qty','LOT 분할수량',false);
  IF ceil(total::numeric/unit)>200 THEN RAISE EXCEPTION '한 번에 최대 200개 LOT를 생성합니다. 분할수량을 늘리거나 이번 배정수량을 줄이세요.'; END IF;
  n:=total;WHILE n>0 LOOP amounts:=amounts||to_jsonb(least(n,unit));n:=n-least(n,unit);END LOOP;
 END IF;
 IF jsonb_array_length(amounts)*jsonb_array_length(p->'steps')>5000 THEN
  RAISE EXCEPTION '한 번에 생성하는 LOT별 공정 합계는 5000개 이내입니다.'; END IF;
 FOR amount IN SELECT value FROM jsonb_array_elements(amounts) LOOP
  payload:=(p-ARRAY['id','version','lot_qty','total_qty','quantities'])||
   jsonb_build_object('production_mode','daily_assigned','daily_qty',amount);
  result:=public.dnm_v4_command('save_routing',payload,gen_random_uuid());
  SELECT * INTO r FROM public.dnm_v4_records WHERE id=(result->>'id')::uuid;
  ids:=ids||jsonb_build_array(r.id);lots:=lots||jsonb_build_array(jsonb_build_object('id',r.id,'code',r.code,'lot',r.data->>'lot','qty',r.data->'qty','version',r.version));
 END LOOP;
 result:=jsonb_build_object('ok',true,'ids',ids,'lots',lots,'count',jsonb_array_length(amounts),'remaining',remaining-total);
 INSERT INTO public.dnm_v4_requests(actor_id,request_key,action,payload_hash,result) VALUES(uid,k,'v410_split',h,result);
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.dnm_v410_lot(act text,p jsonb,k uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); r public.dnm_v4_records; o public.dnm_v4_records; op public.dnm_v4_records;
 previous public.dnm_v4_requests; h text; result jsonb; reason text; n bigint; done_qty bigint; floor_qty bigint;
 next_state text; changed jsonb; has_history boolean;
BEGIN
 PERFORM dnm_private.need('routing','update');PERFORM public.dnm_v4_need('production');
 IF uid IS NULL OR k IS NULL OR act IS NULL OR act NOT IN('quantity','cancel','terminate') OR
 jsonb_typeof(p) IS DISTINCT FROM 'object' OR length(p::text)>8000 THEN RAISE EXCEPTION 'LOT 변경 요청을 확인하세요.'; END IF;
 PERFORM pg_advisory_xact_lock(164040,1);h:=md5('v410_lot'||act||p::text);
 SELECT * INTO previous FROM public.dnm_v4_requests WHERE actor_id=uid AND request_key=k;
 IF FOUND THEN IF previous.payload_hash<>h THEN RAISE EXCEPTION '다른 내용에 사용된 요청번호입니다.';END IF;RETURN previous.result;END IF;
 SELECT * INTO r FROM public.dnm_v4_records WHERE id=(p->>'id')::uuid AND kind='routing' FOR UPDATE;
 IF r.id IS NULL OR r.data->>'daily' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION '민수 LOT를 선택하세요. 방산 Routing은 취소·중단할 수 없습니다.'; END IF;
 IF NOT public.dnm_v4_readable(r.kind,r.data,r.created_by,r.id) OR
  (public.dnm_portal_role()<>'admin' AND r.data->>'manager_id' IS DISTINCT FROM uid::text) THEN
  RAISE EXCEPTION '담당 생산관리자가 LOT를 변경해야 합니다.' USING ERRCODE='42501'; END IF;
 IF r.version IS DISTINCT FROM (p->>'version')::int THEN RAISE EXCEPTION 'LOT가 변경되었습니다. 다시 조회하세요.' USING ERRCODE='40001'; END IF;
 SELECT * INTO o FROM public.dnm_v4_records WHERE id=r.parent_id AND kind='order' FOR UPDATE;
 IF o.state IS DISTINCT FROM 'OPEN' OR (r.state NOT IN('DRAFT','RELEASED') AND NOT(act='terminate' AND r.state='DONE')) THEN
  RAISE EXCEPTION '진행 중 수주의 초안·배포 LOT를 선택하세요. 불량중단은 미검사·미출하 완료 LOT도 처리할 수 있습니다.'; END IF;
 reason:=public.dnm_v4_required(p->>'reason','변경 사유',1000);
 IF EXISTS(SELECT FROM public.dnm_v4_records w JOIN public.dnm_v4_records active_op ON active_op.id=w.parent_id
  WHERE active_op.parent_id=r.id AND w.kind='worklog' AND w.state IN('ACTIVE','PENDING')) THEN
  RAISE EXCEPTION '진행 중 작업을 종료하고 수량 확인대기 실적을 확정한 후 처리하세요.'; END IF;
 SELECT EXISTS(SELECT FROM public.dnm_v4_records hist_op JOIN public.dnm_v4_records h ON h.parent_id=hist_op.id WHERE hist_op.parent_id=r.id AND hist_op.kind='operation') OR
  EXISTS(SELECT FROM public.dnm_v4_records q WHERE q.kind='quality' AND (q.data->>'route_id'=r.id::text OR
   q.data->>'operation_id' IN(SELECT id::text FROM public.dnm_v4_records WHERE kind='operation' AND parent_id=r.id))) INTO has_history;
 changed:=r.data||jsonb_build_object('lot_change_reason',reason,'lot_changed_at',now(),'lot_changed_by',uid);
 next_state:=r.state;
 IF act='quantity' THEN
  IF EXISTS(SELECT FROM public.dnm_v4_records q WHERE q.kind='quality' AND q.parent_id=o.id AND
   (q.data->>'route_id'=r.id::text OR nullif(q.data->>'route_id','') IS NULL)) OR
   EXISTS(SELECT FROM public.dnm_v4_records WHERE kind IN('shipment','customer_return') AND parent_id=o.id) THEN
   RAISE EXCEPTION '검사·출하 이력이 있는 LOT는 수량을 변경할 수 없습니다. 품질담당자 검토가 필요합니다.'; END IF;
  n:=public.dnm_v4_qty(p->'qty','LOT 계획수량',false);
  IF n+dnm_private.v410_allocated(o.id,r.id)>(o.data->>'qty')::bigint THEN RAISE EXCEPTION '수주 수량을 초과하는 LOT 배정입니다.'; END IF;
  IF n=(r.data->>'qty')::bigint THEN RAISE EXCEPTION '변경할 LOT 수량을 입력하세요.'; END IF;
  FOR op IN SELECT * FROM public.dnm_v4_records WHERE kind='operation' AND parent_id=r.id ORDER BY id FOR UPDATE LOOP
   SELECT coalesce(sum((data->>'total')::bigint),0) INTO done_qty FROM public.dnm_v4_records WHERE kind='worklog' AND parent_id=op.id AND state='CONFIRMED';
   SELECT greatest(done_qty,coalesce((op.data->>'confirmed_qty')::bigint,0),coalesce(max((data->>'qty')::bigint),0)) INTO floor_qty
    FROM public.dnm_v4_records WHERE kind='material' AND parent_id=op.id AND data->>'state'='DONE';
   IF n<floor_qty THEN RAISE EXCEPTION '% 공정의 기록된 처리수량 %개 미만으로 줄일 수 없습니다.',op.title,floor_qty; END IF;
   IF EXISTS(SELECT FROM public.dnm_v4_records q WHERE q.kind='quality' AND q.state='CONFIRMED' AND q.data->>'operation_id'=op.id::text
    GROUP BY q.data->>'stage' HAVING sum((q.data->>'total')::bigint)>n) THEN RAISE EXCEPTION '등록된 검사수량보다 LOT 수량을 줄일 수 없습니다.'; END IF;
   UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('qty',n),state=CASE
    WHEN state='DRAFT' THEN 'DRAFT' WHEN floor_qty=n THEN 'DONE' WHEN state='DONE' THEN 'WAIT' ELSE state END WHERE id=op.id;
  END LOOP;
  changed:=changed||jsonb_build_object('qty',n,'quantity_history',coalesce(r.data->'quantity_history','[]')||
   jsonb_build_array(jsonb_build_object('from',r.data->'qty','to',n,'reason',reason,'at',now(),'by',uid)));
 ELSIF act='cancel' THEN
  IF has_history OR EXISTS(SELECT FROM public.dnm_v4_records WHERE kind='operation' AND parent_id=r.id AND state NOT IN('DRAFT','WAIT')) THEN
   RAISE EXCEPTION '실제 작업·검사·처리 이력이 있는 LOT는 삭제할 수 없습니다. 불량 발생 시 중단 처리하세요.'; END IF;
  next_state:='CANCELLED';changed:=changed||jsonb_build_object('cancel_reason',reason,'cancelled_at',now(),'cancelled_by',uid);
  UPDATE public.dnm_v4_records SET state='CANCELLED',data=data||jsonb_build_object('cancel_reason',reason,'cancelled_at',now(),'cancelled_by',uid)
   WHERE kind='operation' AND parent_id=r.id;
 ELSE
  IF EXISTS(SELECT FROM public.dnm_v4_records q WHERE q.kind='quality' AND q.parent_id=o.id AND q.state='CONFIRMED' AND q.data->>'stage'='FINAL'
    AND (q.data->>'route_id'=r.id::text OR nullif(q.data->>'route_id','') IS NULL)) OR
   EXISTS(SELECT FROM public.dnm_v4_records WHERE kind IN('shipment','customer_return') AND parent_id=o.id) THEN
   RAISE EXCEPTION '최종검사·출하 이력이 있는 LOT는 중단할 수 없습니다. 품질담당자의 검토가 필요합니다.'; END IF;
  IF r.state NOT IN('RELEASED','DONE') OR NOT EXISTS(
   SELECT FROM public.dnm_v4_records w JOIN public.dnm_v4_records defect_op ON defect_op.id=w.parent_id
   WHERE defect_op.parent_id=r.id AND w.kind='worklog' AND w.state='CONFIRMED' AND (w.data->>'defect')::numeric>0
   UNION ALL SELECT FROM public.dnm_v4_records q WHERE q.kind='quality' AND q.state='CONFIRMED' AND (q.data->>'defect')::numeric>0
   AND (q.data->>'route_id'=r.id::text OR q.data->>'operation_id' IN(SELECT id::text FROM public.dnm_v4_records WHERE kind='operation' AND parent_id=r.id))
  ) THEN RAISE EXCEPTION '확정된 불량 기록이 있는 배포·완료 LOT만 중단할 수 있습니다.'; END IF;
  next_state:='TERMINATED';changed:=changed||jsonb_build_object('termination_reason',reason,'terminated_at',now(),'terminated_by',uid);
  UPDATE public.dnm_v4_records SET state='TERMINATED',data=data||jsonb_build_object('termination_reason',reason,'terminated_at',now(),'terminated_by',uid)
   WHERE kind='operation' AND parent_id=r.id AND state<>'DONE';
 END IF;
 SELECT * INTO r FROM public.dnm_v4_put(r.kind,r.code,r.title,next_state,r.parent_id,changed,r.id,r.version);
 IF act='quantity' THEN PERFORM public.dnm_v41_sync_routing(r.id);SELECT * INTO r FROM public.dnm_v4_records WHERE id=r.id; END IF;
 result:=jsonb_build_object('ok',true,'id',r.id,'version',r.version,'state',r.state,'remaining',(o.data->>'qty')::bigint-dnm_private.v410_allocated(o.id));
 INSERT INTO public.dnm_v4_requests(actor_id,request_key,action,payload_hash,result) VALUES(uid,k,'v410_lot_'||act,h,result);
 RETURN result;
END $$;
-- Preserve the old endpoint but use identical permission, history and audit rules.
CREATE OR REPLACE FUNCTION public.dnm_v493_void_daily(p_id uuid,p_version int,p_reason text) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 SELECT public.dnm_v410_lot('cancel',jsonb_build_object('id',p_id,'version',p_version,'reason',p_reason),
  md5('v410legacy'||auth.uid()::text||p_id::text||p_version::text||coalesce(p_reason,''))::uuid)
$$;

CREATE OR REPLACE FUNCTION public.dnm_v410_work(act text,p jsonb,k uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
<<work_call>>
DECLARE uid uuid:=auth.uid(); target public.dnm_v4_records; op public.dnm_v4_records; ro public.dnm_v4_records;
 previous public.dnm_v4_requests; h text; result jsonb; team jsonb; updated public.dnm_v4_records;
 action_name text; reason text; changed_identity boolean;
BEGIN
 IF act IS NULL OR act NOT IN('start','manual','finish') OR uid IS NULL OR k IS NULL OR
 jsonb_typeof(p) IS DISTINCT FROM 'object' OR length(p::text)>15000 THEN RAISE EXCEPTION '민수 작업 요청을 확인하세요.'; END IF;
 PERFORM dnm_private.need('worklogs',CASE WHEN act='finish' THEN 'update' ELSE 'create' END);
 PERFORM public.dnm_v4_need('work');PERFORM pg_advisory_xact_lock(164040,1);
 h:=md5('v410_work'||act||p::text);
 SELECT * INTO previous FROM public.dnm_v4_requests WHERE actor_id=uid AND request_key=k;
 IF FOUND THEN IF previous.payload_hash<>h THEN RAISE EXCEPTION '다른 내용에 사용된 요청번호입니다.';END IF;RETURN previous.result;END IF;
 SELECT * INTO target FROM public.dnm_v4_records WHERE id=(p->>'id')::uuid FOR UPDATE;
 IF act='finish' THEN
  IF target.kind IS DISTINCT FROM 'worklog' OR target.state NOT IN('ACTIVE','PENDING') THEN RAISE EXCEPTION '진행 중 또는 수량 확인대기 작업일보를 선택하세요.'; END IF;
  IF (target.state='PENDING') IS DISTINCT FROM coalesce((p->>'confirm_pending')::boolean,false) THEN RAISE EXCEPTION '현재 작업일보 상태를 다시 조회하세요.'; END IF;
  SELECT * INTO op FROM public.dnm_v4_records WHERE id=target.parent_id AND kind='operation';
 ELSE op:=target; END IF;
 SELECT * INTO ro FROM public.dnm_v4_records WHERE id=op.parent_id AND kind='routing';
 IF op.kind IS DISTINCT FROM 'operation' OR ro.data->>'daily' IS DISTINCT FROM 'true' OR ro.state<>'RELEASED' THEN
  RAISE EXCEPTION '배포된 민수 LOT의 공정을 선택하세요.'; END IF;
 IF target.version IS DISTINCT FROM (p->>'version')::int THEN RAISE EXCEPTION '자료가 변경되었습니다. 다시 조회하세요.' USING ERRCODE='40001'; END IF;
 IF act='finish' AND target.data->>'profile_id' IS DISTINCT FROM uid::text AND public.dnm_portal_role()<>'admin'
 AND (public.dnm_v4_can('production') AND ro.data->>'manager_id'=uid::text) IS NOT TRUE THEN
  RAISE EXCEPTION '본인 또는 담당 작업만 종료할 수 있습니다.' USING ERRCODE='42501'; END IF;
 team:=dnm_private.v410_actual_team(ro,op,p,act='finish');
 IF act='finish' THEN
  changed_identity:=target.data->>'employee_id' IS DISTINCT FROM team->>'employee_id' OR target.data->>'equipment_id' IS DISTINCT FROM team->>'equipment_id';
  IF changed_identity THEN
   reason:=public.dnm_v4_required(p->>'change_reason','실제 작업자·설비 정정 사유',1000);
   IF EXISTS(SELECT FROM public.dnm_v4_records w WHERE w.kind='worklog' AND w.parent_id=op.id AND w.id<>target.id
    AND w.state IN('ACTIVE','CONFIRMED','PENDING') AND w.data->>'employee_id'=team->>'employee_id'
    AND (w.data->>'start_at')::timestamptz<CASE WHEN target.state='PENDING' THEN (target.data->>'end_at')::timestamptz ELSE now() END
    AND coalesce(nullif(w.data->>'end_at','')::timestamptz,now())>(target.data->>'start_at')::timestamptz) THEN
    RAISE EXCEPTION '정정할 작업자의 같은 공정 실적시간이 중복됩니다.'; END IF;
  END IF;
 END IF;
 action_name:=CASE act WHEN 'start' THEN 'start_work' WHEN 'manual' THEN 'manual_work' ELSE CASE WHEN target.state='PENDING' THEN 'confirm_work' ELSE 'finish_work' END END;
 -- The private implementation still checks ownership, active account, quantities,
 -- chronology, sequence, and idempotency. The explicit authorization above also
 -- supports a worker selecting a previously unassigned civilian operation.
 result:=dnm_private.dnm_v41_command_impl(action_name,p,k);
 IF act='finish' AND changed_identity THEN
  SELECT * INTO updated FROM public.dnm_v4_records WHERE id=(result->>'id')::uuid;
  SELECT * INTO updated FROM public.dnm_v4_put(updated.kind,updated.code,updated.title,updated.state,updated.parent_id,
   updated.data||team||jsonb_build_object('identity_history',coalesce(updated.data->'identity_history','[]')||
    jsonb_build_array(jsonb_build_object('previous_employee_id',target.data->'employee_id','previous_employee_name',target.data->'employee_name',
     'previous_profile_id',target.data->'profile_id','previous_equipment_id',target.data->'equipment_id','previous_equipment_code',target.data->'equipment_code',
     'employee_id',team->'employee_id','equipment_id',team->'equipment_id','reason',reason,'at',now(),'by',uid))),updated.id,updated.version);
 END IF;
 UPDATE public.dnm_v4_requests SET action='v410_work_'||act,payload_hash=h,result=work_call.result WHERE actor_id=uid AND request_key=k;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.dnm_v410_work_choices(p_operation uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); self_employee public.dnm_v4_records; op public.dnm_v4_records; ro public.dnm_v4_records;
 jobs jsonb; machines jsonb; employees jsonb; manager boolean:=false;
BEGIN
 PERFORM dnm_private.need('worklogs','read');
 IF NOT(public.dnm_v42_allowed('worklogs','create') OR public.dnm_v42_allowed('worklogs','update')) THEN
  RAISE EXCEPTION '작업일보 등록 또는 수정 권한이 필요합니다.' USING ERRCODE='42501'; END IF;
 SELECT * INTO self_employee FROM public.dnm_v4_records WHERE kind='employee' AND data->>'active'='true' AND data->>'profile_id'=uid::text;
 IF p_operation IS NOT NULL THEN
  SELECT * INTO op FROM public.dnm_v4_records WHERE id=p_operation AND kind='operation';
  SELECT * INTO ro FROM public.dnm_v4_records WHERE id=op.parent_id AND kind='routing';
  IF ro.data->>'daily' IS DISTINCT FROM 'true' OR ro.state<>'RELEASED' THEN RAISE EXCEPTION '배포된 민수 공정을 선택하세요.'; END IF;
  manager:=public.dnm_portal_role()='admin' OR (public.dnm_v4_can('production') AND ro.data->>'manager_id'=uid::text);
 ELSE manager:=public.dnm_portal_role()='admin'; END IF;
 IF self_employee.id IS NULL AND NOT manager AND NOT public.dnm_v4_can('production') THEN
  RAISE EXCEPTION '사용 중인 작업자 계정으로 로그인하세요.' USING ERRCODE='42501'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.code,x.id),'[]') INTO jobs FROM (
  SELECT job_op.*,r.code route_code,r.data->>'lot' lot,r.data->>'shop_order_no' shop_order_no,r.data->>'heat_code' heat_code,
   dnm_private.sequence_blocked(r,job_op) sequence_blocked
  FROM public.dnm_v4_records job_op JOIN public.dnm_v4_records r ON r.id=job_op.parent_id AND r.kind='routing'
  JOIN public.dnm_v4_records o ON o.id=r.parent_id AND o.kind='order' AND o.state='OPEN'
  WHERE job_op.kind='operation' AND job_op.data->>'kind'='WORK' AND job_op.state IN('WAIT','ACTIVE') AND r.state='RELEASED' AND r.data->>'daily'='true'
  AND (p_operation IS NULL OR job_op.id=p_operation)
  AND (self_employee.id IS NOT NULL OR public.dnm_portal_role()='admin' OR r.data->>'manager_id'=uid::text)
 ) x;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',e.id,'code',e.code,'title',e.title,'name',e.title) ORDER BY e.title,e.code),'[]') INTO machines
 FROM public.dnm_v4_records e WHERE e.kind='equipment' AND e.data->>'active'='true';
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',e.id,'code',e.code,'title',e.title,'name',e.title,
  'data',jsonb_build_object('department',coalesce(e.data->>'department',''))) ORDER BY e.title,e.code),'[]') INTO employees
 FROM public.dnm_v4_records e JOIN public.dnm_portal_profiles pr ON pr.id=nullif(e.data->>'profile_id','')::uuid AND pr.active
 WHERE e.kind='employee' AND e.data->>'active'='true' AND (manager OR e.id=self_employee.id)
 AND (dnm_private.acl_for(pr.id,'worklogs','create') OR dnm_private.acl_for(pr.id,'worklogs','update'));
 RETURN jsonb_build_object('ok',true,'jobs',jobs,'machines',machines,'employees',employees,'employee_id',self_employee.id);
END $$;

-- Actual substitute workers can reopen the instruction and their own history.
-- Original access rules (including purchasing reviewer access) are retained.
DO $$ BEGIN
 IF to_regprocedure('dnm_private.v495_own_record(text,jsonb,uuid,uuid)') IS NULL THEN
  ALTER FUNCTION dnm_private.own_record(text,jsonb,uuid,uuid) RENAME TO v495_own_record;
 END IF;
END $$;
CREATE OR REPLACE FUNCTION dnm_private.v410_work_owned(d jsonb) RETURNS boolean
LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT coalesce(d->>'profile_id'=auth.uid()::text,false) OR EXISTS(
  SELECT FROM jsonb_array_elements(coalesce(d->'identity_history','[]')) h
  WHERE h->>'previous_profile_id'=auth.uid()::text
 )
$$;
CREATE OR REPLACE FUNCTION dnm_private.own_record(k text,d jsonb,owner uuid,rid uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT dnm_private.v495_own_record(k,d,owner,rid) OR CASE
 WHEN k='worklog' THEN dnm_private.v410_work_owned(d)
 WHEN k='operation' THEN EXISTS(SELECT FROM public.dnm_v4_records w WHERE w.kind='worklog' AND w.parent_id=rid AND dnm_private.v410_work_owned(w.data))
 WHEN k='routing' THEN EXISTS(SELECT FROM public.dnm_v4_records op JOIN public.dnm_v4_records w ON w.parent_id=op.id AND w.kind='worklog'
  WHERE op.kind='operation' AND op.parent_id=rid AND dnm_private.v410_work_owned(w.data))
 WHEN k='equipment' THEN EXISTS(SELECT FROM public.dnm_v4_records w WHERE w.kind='worklog' AND dnm_private.v410_work_owned(w.data)
  AND (w.data->>'equipment_id'=rid::text OR EXISTS(SELECT FROM jsonb_array_elements(coalesce(w.data->'identity_history','[]')) h WHERE h->>'previous_equipment_id'=rid::text)))
 ELSE false END
$$;
REVOKE ALL ON FUNCTION dnm_private.v495_own_record(text,jsonb,uuid,uuid),dnm_private.v410_work_owned(jsonb),
 dnm_private.own_record(text,jsonb,uuid,uuid),public.dnm_v4_order_valid(jsonb) FROM PUBLIC,anon,authenticated;

-- Only public versioned entry points are exposed, never the private helpers.
REVOKE ALL ON FUNCTION dnm_private.v410_order_type(public.dnm_v4_records),dnm_private.v410_allocated(uuid,uuid),
 dnm_private.v495_order_valid(jsonb),dnm_private.v410_route_code(public.dnm_v4_records,jsonb,int),
 dnm_private.v410_command_guard(text,jsonb),dnm_private.v410_actual_team(public.dnm_v4_records,public.dnm_v4_records,jsonb,boolean)
 FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.dnm_v410_save_order(jsonb,uuid),public.dnm_v410_plan_info(uuid),
 public.dnm_v410_split(jsonb,uuid),public.dnm_v410_lot(text,jsonb,uuid),public.dnm_v410_work(text,jsonb,uuid),
 public.dnm_v410_work_choices(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dnm_v410_save_order(jsonb,uuid),public.dnm_v410_plan_info(uuid),
 public.dnm_v410_split(jsonb,uuid),public.dnm_v410_lot(text,jsonb,uuid),public.dnm_v410_work(text,jsonb,uuid),
 public.dnm_v410_work_choices(uuid) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
