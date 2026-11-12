-- DNM MES 4.10.1. Apply after SQL27 revision 2. Existing rows/settings/leave links are retained.
BEGIN;
SELECT pg_advisory_xact_lock(164040,1);
DO $$ BEGIN
 IF to_regprocedure('public.dnm_v410_split(jsonb,uuid)') IS NULL THEN
  RAISE EXCEPTION '4.10.0 수정 SQL27을 먼저 적용하세요.';
 END IF;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.patch4101(fn regprocedure,before_text text,after_text text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE src text:=replace(pg_get_functiondef(fn),E'\r\n',E'\n');
BEGIN
 before_text:=replace(before_text,E'\r\n',E'\n');after_text:=replace(after_text,E'\r\n',E'\n');
 IF strpos(src,after_text)>0 THEN RETURN;END IF;
 IF (length(src)-length(replace(src,before_text,'')))/length(before_text)<>1 THEN
  RAISE EXCEPTION '설치된 함수 %의 수정 위치를 확인할 수 없습니다. 전체 업데이트를 중단합니다.',fn;
 END IF;
 EXECUTE replace(src,before_text,after_text);
END $$;
SELECT pg_temp.patch4101('public.dnm_v410_split(jsonb,uuid)',
 $o$jsonb_array_length(p->'quantities') NOT BETWEEN 1 AND 200$o$,
 $n$jsonb_array_length(p->'quantities') NOT BETWEEN 1 AND 500$n$);
SELECT pg_temp.patch4101('public.dnm_v410_split(jsonb,uuid)',
 $o$한 번에 1~200개 LOT를 작성하세요.$o$,$n$한 번에 1~500개 LOT를 작성하세요.$n$);
SELECT pg_temp.patch4101('public.dnm_v410_split(jsonb,uuid)',
 $o$IF ceil(total::numeric/unit)>200 THEN RAISE EXCEPTION '한 번에 최대 200개 LOT를 생성합니다.$o$,
 $n$IF ceil(total::numeric/unit)>500 THEN RAISE EXCEPTION '한 번에 최대 500개 LOT를 생성합니다.$n$);
SELECT pg_temp.patch4101('public.dnm_v410_split(jsonb,uuid)',
 $o$jsonb_array_length(amounts)*jsonb_array_length(p->'steps')>5000$o$,
 $n$jsonb_array_length(amounts)*jsonb_array_length(p->'steps')>30000$n$);
SELECT pg_temp.patch4101('public.dnm_v410_split(jsonb,uuid)',
 $o$LOT별 공정 합계는 5000개 이내입니다.$o$,$n$LOT별 공정 합계는 30000개 이내입니다.$n$);
ALTER FUNCTION public.dnm_v410_split(jsonb,uuid) SET statement_timeout='90s';

CREATE OR REPLACE FUNCTION dnm_private.v4101_final_locked(rid uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT FROM public.dnm_v4_records r WHERE r.id=rid AND r.kind='routing' AND
  (nullif(r.data->>'diary_locked_at','') IS NOT NULL OR r.state='DONE')) OR EXISTS(
  SELECT FROM public.dnm_v4_records op WHERE op.kind='operation' AND op.parent_id=rid AND op.state='DONE'
   AND coalesce((op.data->>'seq')::int,0)=(SELECT max(coalesce((x.data->>'seq')::int,0))
    FROM public.dnm_v4_records x WHERE x.kind='operation' AND x.parent_id=rid))
$$;
-- Retain completion once the final operation finishes or is subsequently reopened.
-- Install only: existing records are not rewritten. Older DONE rows are recognized by the reader above.
CREATE OR REPLACE FUNCTION dnm_private.v4101_lock_final_diary() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF (NEW.data->>'seq')::int=(SELECT max((op.data->>'seq')::int) FROM public.dnm_v4_records op
   WHERE op.kind='operation' AND op.parent_id=NEW.parent_id) THEN
  UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('diary_locked_at',now())
   WHERE id=NEW.parent_id AND kind='routing' AND nullif(data->>'diary_locked_at','') IS NULL;
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS dnm_v4101_final_diary_lock ON public.dnm_v4_records;
CREATE TRIGGER dnm_v4101_final_diary_lock AFTER UPDATE OF state ON public.dnm_v4_records
 FOR EACH ROW WHEN(NEW.kind='operation' AND (NEW.state='DONE' OR OLD.state='DONE'))
 EXECUTE FUNCTION dnm_private.v4101_lock_final_diary();

-- The older cancellation entry point must obey the same final-process lock.
SELECT pg_temp.patch4101('dnm_private.v410_command_guard(text,jsonb)',
 $o$IF ro.id IS NULL THEN RETURN; END IF;$o$,
 $n$IF ro.id IS NULL THEN RETURN; END IF;
 IF act='cancel_work' AND target.state='CONFIRMED' AND dnm_private.v4101_final_locked(ro.id) THEN
  IF public.dnm_portal_role()<>'admin' THEN
   RAISE EXCEPTION '마지막 공정이 종료된 작업일보는 시스템 관리자만 수정할 수 있습니다.' USING ERRCODE='42501';
  END IF;
  UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('diary_locked_at',coalesce(data->>'diary_locked_at',now()::text)) WHERE id=ro.id;
 END IF;$n$);

-- A deleted order cannot be revived through an older client or order importer.
SELECT pg_temp.patch4101('dnm_private.daily_order_guard()',
 $o$planned:=dnm_private.v410_allocated(OLD.id);$o$,
 $n$IF OLD.data->>'deleted'='true' THEN RAISE EXCEPTION '삭제된 수주는 변경할 수 없습니다. 신규 수주로 등록하세요.';END IF;
 planned:=dnm_private.v410_allocated(OLD.id);$n$);
-- Only this workbook family is deduplicated by original LOT identity. Existing source rows are retained.
SELECT pg_temp.patch4101('public.dnm_v42_import(text,jsonb,jsonb,uuid)',
 $o$IF k='employee' AND EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='employee' AND title=t AND code<>c) THEN$o$,
 $n$IF k='source_routing' AND d->>'source_family'='DNM_BUSH_XLSM' AND EXISTS(
     SELECT 1 FROM public.dnm_v4_records WHERE kind='source_routing' AND (code=c OR title=t OR data->>'lot'=d->>'lot')) THEN
    cnt:=0;warnings:=warnings||jsonb_build_array(t||': 같은 LOT 원문이 있어 기존 자료를 보존했습니다.');
   ELSIF k='employee' AND EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='employee' AND title=t AND code<>c) THEN$n$);

CREATE OR REPLACE FUNCTION public.dnm_v4101_balances(ids uuid[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
 PERFORM dnm_private.need('orders','read');
 IF coalesce(cardinality(ids),0)>20000 THEN RAISE EXCEPTION '수주 조회 범위를 줄이세요.';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',o.id,'qty',(o.data->>'qty')::bigint,
  'allocated',a.n,'remaining',(o.data->>'qty')::bigint-a.n)),'[]') INTO result
 FROM public.dnm_v4_records o CROSS JOIN LATERAL(SELECT dnm_private.v410_allocated(o.id) n) a
 WHERE o.id=ANY(ids) AND o.kind='order' AND dnm_private.v410_order_type(o)='CIVIL'
 AND public.dnm_v4_readable(o.kind,o.data,o.created_by,o.id);
 RETURN jsonb_build_object('ok',true,'rows',result);
END $$;

CREATE OR REPLACE FUNCTION public.dnm_v4101_save_order(p jsonb,k uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE o public.dnm_v4_records; changed public.dnm_v4_records; previous public.dnm_v4_requests;
 d jsonb; field_name text; h text; result jsonb; allocated bigint; target_state text;
BEGIN
 IF nullif(p->>'id','') IS NULL THEN RETURN public.dnm_v410_save_order(p,k);END IF;
 PERFORM dnm_private.need('orders','update');PERFORM pg_advisory_xact_lock(164040,1);
 IF k IS NULL OR jsonb_typeof(p) IS DISTINCT FROM 'object' OR jsonb_typeof(p->'data') IS DISTINCT FROM 'object'
 OR length(p::text)>50000 THEN RAISE EXCEPTION '수주 수정 요청을 확인하세요.';END IF;
 h:=md5('v4101_order'||p::text);
 SELECT * INTO previous FROM public.dnm_v4_requests WHERE actor_id=auth.uid() AND request_key=k;
 IF FOUND THEN IF previous.payload_hash<>h THEN RAISE EXCEPTION '다른 내용에 사용된 요청번호입니다.';END IF;RETURN previous.result;END IF;
 SELECT * INTO o FROM public.dnm_v4_records WHERE kind='order' AND id=(p->>'id')::uuid FOR UPDATE;
 IF o.id IS NULL OR NOT public.dnm_v4_readable(o.kind,o.data,o.created_by,o.id) THEN
  RAISE EXCEPTION '수정 가능한 수주를 선택하세요.' USING ERRCODE='42501';END IF;
 IF dnm_private.v410_order_type(o)<>'CIVIL' THEN RETURN public.dnm_v410_save_order(p,k);END IF;
 IF o.state='CANCELLED' OR o.data->>'deleted'='true' THEN RAISE EXCEPTION '삭제된 수주는 수정할 수 없습니다.';END IF;
 IF o.version IS DISTINCT FROM (p->>'version')::int THEN RAISE EXCEPTION '수주가 변경되었습니다. 다시 조회하세요.' USING ERRCODE='40001';END IF;
 d:=o.data;
 FOREACH field_name IN ARRAY ARRAY['customer','part_no','part_name','qty','order_date','due_date','project','model','pwi_no',
  'material_spec','part_type','qpa','set_qty','unit_price','po_no','shop_order_no','heat_code','note'] LOOP
  IF p->'data' ? field_name THEN d:=jsonb_set(d,ARRAY[field_name],p->'data'->field_name);END IF;
 END LOOP;
 d:=public.dnm_v4_order_valid(d||jsonb_build_object('production_no',o.code,'order_type','CIVIL'));
 allocated:=dnm_private.v410_allocated(o.id);
 IF (d->>'qty')::bigint<allocated THEN RAISE EXCEPTION 'LOT 배정합계 %개보다 수주수량을 줄일 수 없습니다.',allocated;END IF;
 IF (d->>'qty')::numeric<(SELECT coalesce(sum((data->>'qty')::numeric),0) FROM public.dnm_v4_records WHERE kind='shipment' AND parent_id=o.id AND state<>'CANCELLED') THEN
  RAISE EXCEPTION '출하된 수량보다 수주수량을 줄일 수 없습니다.';END IF;
 target_state:=CASE WHEN o.state='CLOSED' AND (d->>'qty')::bigint>(o.data->>'qty')::bigint THEN 'OPEN' ELSE o.state END;
 d:=d||jsonb_build_object('order_edit_history',coalesce(o.data->'order_edit_history','[]')||jsonb_build_array(
  jsonb_build_object('at',now(),'by',auth.uid(),'previous_qty',o.data->'qty','qty',d->'qty','previous_state',o.state,'state',target_state)));
 SELECT * INTO changed FROM public.dnm_v4_put('order',o.code,coalesce(nullif(d->>'part_name',''),o.title),target_state,o.parent_id,d,o.id,o.version);
 result:=jsonb_build_object('ok',true,'id',changed.id,'code',changed.code,'version',changed.version,'allocated',allocated,'remaining',(d->>'qty')::bigint-allocated);
 INSERT INTO public.dnm_v4_requests(actor_id,request_key,action,payload_hash,result) VALUES(auth.uid(),k,'v4101_order',h,result);
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION dnm_private.v4101_zero_lot(rid uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT NOT EXISTS(SELECT FROM public.dnm_v4_records op WHERE op.kind='operation' AND op.parent_id=rid AND
  (coalesce((op.data->>'confirmed_qty')::numeric,0)>0 OR EXISTS(SELECT FROM public.dnm_v4_records w WHERE w.parent_id=op.id AND
    ((w.kind='worklog' AND (w.state IN('ACTIVE','PENDING') OR (w.state<>'CANCELLED' AND
      greatest(coalesce((w.data->>'total')::numeric,0),coalesce((w.data->>'good')::numeric,0),coalesce((w.data->>'defect')::numeric,0))>0))) OR
     (w.kind='material' AND w.state<>'CANCELLED' AND coalesce((w.data->>'qty')::numeric,0)>0)))))
 AND NOT EXISTS(SELECT FROM public.dnm_v4_records q WHERE q.kind IN('quality','shipment','customer_return') AND q.state<>'CANCELLED'
  AND (q.data->>'route_id'=rid::text OR q.data->>'operation_id' IN(SELECT id::text FROM public.dnm_v4_records WHERE kind='operation' AND parent_id=rid))
  AND greatest(coalesce((q.data->>'total')::numeric,0),coalesce((q.data->>'qty')::numeric,0),coalesce((q.data->>'good')::numeric,0))>0)
$$;
CREATE OR REPLACE FUNCTION dnm_private.v4101_delete_lot(rid uuid,reason text) RETURNS void
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE stamp jsonb:=jsonb_build_object('deleted',true,'delete_reason',reason,'deleted_at',now(),'deleted_by',auth.uid());
BEGIN
 IF NOT dnm_private.v4101_zero_lot(rid) THEN RAISE EXCEPTION '작업·검사 실적이 있거나 진행·확인대기 작업이 있습니다. 실적 0인 LOT만 삭제할 수 있습니다.';END IF;
 UPDATE public.dnm_v4_records SET state='CANCELLED',data=data||stamp WHERE kind='worklog'
 AND parent_id IN(SELECT id FROM public.dnm_v4_records WHERE kind='operation' AND parent_id=rid) AND state<>'CANCELLED';
 UPDATE public.dnm_v4_records SET state='CANCELLED',data=data||stamp WHERE kind='operation' AND parent_id=rid;
 UPDATE public.dnm_v4_records SET state='CANCELLED',data=data||stamp WHERE id=rid AND kind='routing';
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v4101_delete(kind text,p jsonb,k uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE target public.dnm_v4_records; ro public.dnm_v4_records; previous public.dnm_v4_requests;
 h text; reason text; result jsonb; oid uuid;
BEGIN
 IF kind IS NULL OR kind NOT IN('order','lot') OR k IS NULL OR jsonb_typeof(p) IS DISTINCT FROM 'object' OR length(p::text)>6000 THEN RAISE EXCEPTION '삭제 요청을 확인하세요.';END IF;
 PERFORM dnm_private.need(CASE WHEN kind='order' THEN 'orders' ELSE 'routing' END,'update');
 PERFORM pg_advisory_xact_lock(164040,1);h:=md5('v4101_delete'||kind||p::text);
 SELECT * INTO previous FROM public.dnm_v4_requests WHERE actor_id=auth.uid() AND request_key=k;
 IF FOUND THEN IF previous.payload_hash<>h THEN RAISE EXCEPTION '다른 내용에 사용된 요청번호입니다.';END IF;RETURN previous.result;END IF;
 SELECT * INTO target FROM public.dnm_v4_records t WHERE t.id=(p->>'id')::uuid AND t.kind=CASE WHEN dnm_v4101_delete.kind='order' THEN 'order' ELSE 'routing' END FOR UPDATE;
 IF target.id IS NULL OR NOT public.dnm_v4_readable(target.kind,target.data,target.created_by,target.id) THEN RAISE EXCEPTION '삭제 가능한 자료를 선택하세요.' USING ERRCODE='42501';END IF;
 IF target.version IS DISTINCT FROM (p->>'version')::int THEN RAISE EXCEPTION '자료가 변경되었습니다. 다시 조회하세요.' USING ERRCODE='40001';END IF;
 IF target.state IN('CANCELLED','SUPERSEDED') THEN RAISE EXCEPTION '이미 삭제되었거나 이전 개정 자료입니다.';END IF;
 reason:=public.dnm_v4_required(p->>'reason','삭제 사유',1000);
 IF kind='lot' THEN
  IF target.data->>'daily' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION '민수 LOT만 삭제할 수 있습니다.';END IF;
  IF public.dnm_portal_role()<>'admin' AND target.data->>'manager_id' IS DISTINCT FROM auth.uid()::text THEN RAISE EXCEPTION '담당 생산관리자만 LOT를 삭제할 수 있습니다.' USING ERRCODE='42501';END IF;
  oid:=target.parent_id;PERFORM dnm_private.v4101_delete_lot(target.id,reason);
 ELSE
  IF dnm_private.v410_order_type(target)<>'CIVIL' THEN RAISE EXCEPTION '민수 수주만 삭제할 수 있습니다.';END IF;
  oid:=target.id;
  IF EXISTS(SELECT FROM public.dnm_v4_records t WHERE t.parent_id=target.id AND t.kind IN('quality','shipment','customer_return') AND t.state<>'CANCELLED') THEN
   RAISE EXCEPTION '검사·출하·반품 기록이 있는 수주는 삭제할 수 없습니다. 실적 0인 개별 LOT를 선택하세요.';END IF;
  FOR ro IN SELECT * FROM public.dnm_v4_records t WHERE t.kind='routing' AND t.parent_id=target.id AND t.state NOT IN('CANCELLED','SUPERSEDED') ORDER BY id LOOP
   IF ro.data->>'daily' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION '방산 Routing을 포함한 수주는 삭제할 수 없습니다.';END IF;
   PERFORM dnm_private.v4101_delete_lot(ro.id,reason);
  END LOOP;
  UPDATE public.dnm_v4_records SET state='CANCELLED',data=data||jsonb_build_object('deleted',true,'delete_reason',reason,'deleted_at',now(),'deleted_by',auth.uid()) WHERE id=target.id;
 END IF;
 result:=jsonb_build_object('ok',true,'id',target.id,'deleted',true,'allocated',dnm_private.v410_allocated(oid));
 INSERT INTO public.dnm_v4_requests(actor_id,request_key,action,payload_hash,result) VALUES(auth.uid(),k,'v4101_delete_'||kind,h,result);
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.dnm_v4101_edit_status(ids uuid[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
 PERFORM dnm_private.need('worklogs','read');
 IF coalesce(cardinality(ids),0)>20000 THEN RAISE EXCEPTION '작업일보 조회 범위를 줄이세요.';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',w.id,'final_locked',dnm_private.v4101_final_locked(ro.id),
  'editable',public.dnm_v42_allowed('worklogs','update') AND w.state='CONFIRMED' AND ro.state NOT IN('CANCELLED','SUPERSEDED')
  AND (public.dnm_portal_role()='admin' OR (ro.state<>'TERMINATED' AND NOT dnm_private.v4101_final_locked(ro.id))))),'[]') INTO result
 FROM public.dnm_v4_records w JOIN public.dnm_v4_records op ON op.id=w.parent_id AND op.kind='operation'
 JOIN public.dnm_v4_records ro ON ro.id=op.parent_id AND ro.kind='routing'
 WHERE w.kind='worklog' AND w.id=ANY(ids) AND public.dnm_v4_readable(w.kind,w.data,w.created_by,w.id);
 RETURN jsonb_build_object('ok',true,'rows',result);
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v4101_edit_work(p jsonb,k uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE w public.dnm_v4_records; op public.dnm_v4_records; ro public.dnm_v4_records; previous public.dnm_v4_requests;
 uid uuid:=auth.uid(); h text; d jsonb; result jsonb; reason text; total_qty bigint; defects bigint; other_qty bigint;
 start_time timestamptz; end_time timestamptz; locked boolean; admin boolean; field_name text; team jsonb:='{}'; total_after bigint;
BEGIN
 PERFORM dnm_private.need('worklogs','update');PERFORM pg_advisory_xact_lock(164040,1);
 IF k IS NULL OR jsonb_typeof(p) IS DISTINCT FROM 'object' OR length(p::text)>15000 THEN RAISE EXCEPTION '작업일보 수정 요청을 확인하세요.';END IF;
 h:=md5('v4101_edit_work'||p::text);
 SELECT * INTO previous FROM public.dnm_v4_requests WHERE actor_id=uid AND request_key=k;
 IF FOUND THEN IF previous.payload_hash<>h THEN RAISE EXCEPTION '다른 내용에 사용된 요청번호입니다.';END IF;RETURN previous.result;END IF;
 SELECT * INTO w FROM public.dnm_v4_records WHERE id=(p->>'id')::uuid AND kind='worklog' FOR UPDATE;
 IF w.id IS NULL OR NOT public.dnm_v4_readable(w.kind,w.data,w.created_by,w.id) THEN RAISE EXCEPTION '수정 가능한 작업일보를 선택하세요.' USING ERRCODE='42501';END IF;
 IF w.state<>'CONFIRMED' THEN RAISE EXCEPTION '등록 완료된 작업일보만 수정할 수 있습니다. 진행·확인대기 작업은 종료·확정 메뉴를 사용하세요.';END IF;
 IF w.version IS DISTINCT FROM (p->>'version')::int THEN RAISE EXCEPTION '작업일보가 변경되었습니다. 다시 조회하세요.' USING ERRCODE='40001';END IF;
 SELECT * INTO op FROM public.dnm_v4_records WHERE id=w.parent_id AND kind='operation' FOR UPDATE;
 SELECT * INTO ro FROM public.dnm_v4_records WHERE id=op.parent_id AND kind='routing' FOR UPDATE;
 IF ro.id IS NULL OR ro.state IN('CANCELLED','SUPERSEDED') THEN RAISE EXCEPTION '삭제·이전 개정 LOT의 실적은 수정할 수 없습니다.';END IF;
 locked:=dnm_private.v4101_final_locked(ro.id);admin:=public.dnm_portal_role()='admin';
 IF NOT admin AND (locked OR ro.state='TERMINATED') THEN RAISE EXCEPTION '마지막 공정이 종료되거나 종결된 작업일보는 시스템 관리자만 수정할 수 있습니다.' USING ERRCODE='42501';END IF;
 reason:=public.dnm_v4_required(p->>'reason','수정 사유',1000);
 d:=w.data;
 FOREACH field_name IN ARRAY ARRAY['total','defect','work_date','start_at','end_at','note','memo','defect_note'] LOOP
  IF p ? field_name THEN d:=jsonb_set(d,ARRAY[field_name],p->field_name);END IF;
 END LOOP;
 FOREACH field_name IN ARRAY ARRAY['note','memo','defect_note'] LOOP
  IF d ? field_name AND (jsonb_typeof(d->field_name) IS DISTINCT FROM 'string' OR length(d->>field_name)>4000) THEN
   RAISE EXCEPTION '작업내용·비고·불량내용은 4,000자 이내 문자로 입력하세요.';END IF;
 END LOOP;
 total_qty:=public.dnm_v4_qty(d->'total','총 처리수량');defects:=public.dnm_v4_qty(d->'defect','불량수량');
 IF defects>total_qty THEN RAISE EXCEPTION '불량수량은 총 처리수량을 초과할 수 없습니다.';END IF;
 SELECT coalesce(sum((data->>'total')::bigint),0) INTO other_qty FROM public.dnm_v4_records WHERE kind='worklog' AND parent_id=op.id AND state='CONFIRMED' AND id<>w.id;
 total_after:=other_qty+total_qty;
 IF total_after>(op.data->>'qty')::bigint THEN RAISE EXCEPTION '수정 후 공정 누적수량이 LOT 지시수량을 초과합니다.';END IF;
 IF total_qty IS DISTINCT FROM (w.data->>'total')::bigint AND EXISTS(SELECT FROM public.dnm_v4_records later WHERE later.kind='operation' AND later.parent_id=ro.id
  AND (later.data->>'seq')::int>(op.data->>'seq')::int AND later.data->>'independent' IS DISTINCT FROM 'true'
  AND coalesce((later.data->>'confirmed_qty')::bigint,0)>total_after) THEN
  RAISE EXCEPTION '순서를 준수하는 후속 공정의 실적보다 누적수량을 줄일 수 없습니다.';END IF;
 IF total_qty IS DISTINCT FROM (w.data->>'total')::bigint AND EXISTS(SELECT FROM public.dnm_v4_records q WHERE q.kind='quality' AND q.state='CONFIRMED'
  AND (q.data->>'operation_id'=op.id::text OR (q.data->>'stage'='FINAL' AND q.data->>'route_id'=ro.id::text))
  GROUP BY q.data->>'stage' HAVING sum((q.data->>'total')::bigint)>total_after) THEN
  RAISE EXCEPTION '해당 공정의 확정 검사수량보다 누적수량을 줄일 수 없습니다.';END IF;
 IF total_qty<(w.data->>'total')::bigint AND EXISTS(SELECT FROM public.dnm_v4_records q
  WHERE q.parent_id=ro.parent_id AND q.state='CONFIRMED' AND nullif(q.data->>'route_id','') IS NULL
  AND (q.kind='shipment' OR (q.kind='quality' AND q.data->>'stage'='FINAL'))) THEN
  RAISE EXCEPTION 'LOT 연결이 없는 최종검사·출하 기록이 있습니다. 수량을 줄이기 전에 품질·출하 기록을 대조하세요. 비고 수정은 가능합니다.';END IF;
 start_time:=(d->>'start_at')::timestamptz;end_time:=(d->>'end_at')::timestamptz;
 IF start_time IS NULL OR end_time IS NULL OR end_time<=start_time OR end_time-start_time>interval '72 hours' THEN RAISE EXCEPTION '시작·종료시간과 72시간 이내 작업시간을 확인하세요.';END IF;
 IF end_time>now()+interval '2 minutes' THEN RAISE EXCEPTION '미래 작업실적으로 수정할 수 없습니다.';END IF;
 IF start_time IS DISTINCT FROM (w.data->>'start_at')::timestamptz AND dnm_private.manual_before_previous(ro,op,start_time) THEN
  RAISE EXCEPTION '선행 공정 완료 이전으로 작업시작을 변경할 수 없습니다.';END IF;
 IF coalesce(d->>'work_date','')='' THEN RAISE EXCEPTION '작업일자를 입력하세요.';END IF;PERFORM (d->>'work_date')::date;
 IF (p ? 'employee_id' AND p->>'employee_id' IS DISTINCT FROM w.data->>'employee_id') OR
    (p ? 'equipment_id' AND p->>'equipment_id' IS DISTINCT FROM w.data->>'equipment_id') THEN
  IF ro.data->>'daily' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION '방산 실적의 작업자·설비 변경은 지시 배정을 먼저 확인하세요.';END IF;
  team:=dnm_private.v410_actual_team(ro,op,jsonb_build_object('employee_id',coalesce(p->>'employee_id',w.data->>'employee_id'),
   'equipment_id',coalesce(p->>'equipment_id',w.data->>'equipment_id')),true);
 END IF;
 d:=d||team;
 IF EXISTS(SELECT FROM public.dnm_v4_records other WHERE other.kind='worklog' AND other.parent_id=op.id AND other.id<>w.id
  AND other.state IN('ACTIVE','PENDING','CONFIRMED') AND other.data->>'employee_id'=d->>'employee_id'
  AND (other.data->>'start_at')::timestamptz<end_time AND coalesce(nullif(other.data->>'end_at','')::timestamptz,now())>start_time) THEN
  RAISE EXCEPTION '같은 작업자의 같은 공정 작업시간이 중복됩니다.';END IF;
 d:=d||jsonb_build_object('total',total_qty,'defect',defects,'good',total_qty-defects,'minutes',public.dnm_v4_minutes(start_time,end_time),
  'edit_history',coalesce(w.data->'edit_history','[]')||jsonb_build_array(jsonb_build_object('at',now(),'by',uid,'reason',reason,
  'after_final',locked,'previous',w.data-ARRAY['edit_history','voice_original'])));
 IF locked AND nullif(ro.data->>'diary_locked_at','') IS NULL THEN
  UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('diary_locked_at',now()) WHERE id=ro.id;
 END IF;
 SELECT * INTO w FROM public.dnm_v4_put(w.kind,w.code,w.title,w.state,w.parent_id,d,w.id,w.version);
 UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('confirmed_qty',total_after),state=CASE
  WHEN state='TERMINATED' THEN state
  WHEN EXISTS(SELECT FROM public.dnm_v4_records WHERE kind='worklog' AND parent_id=op.id AND state='ACTIVE') THEN 'ACTIVE'
  WHEN EXISTS(SELECT FROM public.dnm_v4_records WHERE kind='worklog' AND parent_id=op.id AND state='PENDING') THEN 'PENDING'
  WHEN total_after=(data->>'qty')::bigint THEN 'DONE' ELSE 'WAIT' END WHERE id=op.id;
 PERFORM public.dnm_v41_sync_routing(ro.id);
 result:=jsonb_build_object('ok',true,'id',w.id,'version',w.version,'total',total_qty,'defect',defects,'final_locked',dnm_private.v4101_final_locked(ro.id));
 INSERT INTO public.dnm_v4_requests(actor_id,request_key,action,payload_hash,result) VALUES(uid,k,'v4101_edit_work',h,result);
 RETURN result;
END $$;

-- Memo storage for normal/manual/voice completion paths, including the existing controller.
SELECT pg_temp.patch4101('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)',
 $o$'defect_note',coalesce(payload->>'defect_note',''),'note',coalesce(payload->>'note',old.data->>'note','')$o$,
 $n$'defect_note',coalesce(payload->>'defect_note',''),'memo',left(coalesce(payload->>'memo',old.data->>'memo',''),4000),'note',coalesce(payload->>'note',old.data->>'note','')$n$);
SELECT pg_temp.patch4101('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)',
 $o$'profile_id',emp.data->>'profile_id','note',coalesce(payload->>'note','')$o$,
 $n$'profile_id',emp.data->>'profile_id','memo',left(coalesce(payload->>'memo',''),4000),'note',coalesce(payload->>'note','')$n$);

REVOKE ALL ON FUNCTION dnm_private.v4101_lock_final_diary(),dnm_private.v4101_final_locked(uuid),dnm_private.v4101_zero_lot(uuid),dnm_private.v4101_delete_lot(uuid,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.dnm_v4101_balances(uuid[]),public.dnm_v4101_save_order(jsonb,uuid),public.dnm_v4101_delete(text,jsonb,uuid),
 public.dnm_v4101_edit_status(uuid[]),public.dnm_v4101_edit_work(jsonb,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v4101_balances(uuid[]),public.dnm_v4101_save_order(jsonb,uuid),public.dnm_v4101_delete(text,jsonb,uuid),
 public.dnm_v4101_edit_status(uuid[]),public.dnm_v4101_edit_work(jsonb,uuid) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
