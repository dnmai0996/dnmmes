-- DNM MES 4.10.3. Apply once after SQL28 (re-running this file is safe).
-- Additive functions and one insert/update guard only. No existing business-row rewrite.
BEGIN;
SELECT pg_advisory_xact_lock(164040,1);
DO $$ BEGIN
 IF to_regprocedure('public.dnm_v4101_save_order(jsonb,uuid)') IS NULL THEN
  RAISE EXCEPTION 'SQL28(4.10.1)을 먼저 적용하세요. 기존 자료를 초기화하지 마세요.';
 END IF;
END $$;

CREATE OR REPLACE FUNCTION dnm_private.v4103_deleted_order_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF NEW.state NOT IN('CANCELLED','SUPERSEDED') AND EXISTS(
  SELECT FROM public.dnm_v4_records o WHERE o.id=NEW.parent_id AND o.kind='order'
   AND (o.state='CANCELLED' OR o.data->>'deleted'='true')) THEN
  RAISE EXCEPTION '삭제된 수주에는 Routing을 작성하거나 다시 활성화할 수 없습니다.';
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS dnm_v4103_deleted_order_guard ON public.dnm_v4_records;
CREATE TRIGGER dnm_v4103_deleted_order_guard BEFORE INSERT OR UPDATE ON public.dnm_v4_records
 FOR EACH ROW WHEN(NEW.kind='routing') EXECUTE FUNCTION dnm_private.v4103_deleted_order_guard();

CREATE OR REPLACE FUNCTION dnm_private.v4103_values(src public.dnm_v4_records,patch jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE d jsonb; result jsonb:='{}'; f text; v text; lot text;
BEGIN
 IF jsonb_typeof(patch) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION '보완 항목 형식을 확인하세요.';END IF;
 lot:=coalesce(nullif(src.data->>'lot',''),src.title);
 d:=jsonb_build_object('lot',lot,'part_no',coalesce(src.data->>'part_no',src.data->>'part_revision',''),
  'part_name',coalesce(src.data->>'part_name',''),'part_type',coalesce(src.data->>'part_type',''),
  'shop_order_no',coalesce(src.data->>'shop_order_no',src.data->>'so_raw',''),'heat_code',coalesce(src.data->>'heat_code',''),
  'qty',src.data->'qty','input_date',coalesce(src.data->>'input_date',''),'current_state','','note',coalesce(src.data->>'note',''))
  ||coalesce(src.data->'mes_transfer'->'review','{}')||patch;
 IF d->>'lot' IS DISTINCT FROM lot THEN RAISE EXCEPTION '원본 LOT 번호는 변경할 수 없습니다. 다른 원문을 선택하세요.';END IF;
 FOREACH f IN ARRAY ARRAY['lot','part_no','part_name','part_type','shop_order_no','heat_code','input_date','current_state','note'] LOOP
  IF d->f IS NOT NULL AND d->f<>'null' AND jsonb_typeof(d->f)<>'string' THEN RAISE EXCEPTION '% 항목은 문자로 입력하세요.',f;END IF;
  v:=btrim(coalesce(d->>f,''));
  IF length(v)>(CASE WHEN f='note' THEN 2000 WHEN f='part_name' THEN 200 ELSE 100 END) THEN RAISE EXCEPTION '% 항목 길이를 확인하세요.',f;END IF;
  result:=result||jsonb_build_object(f,v);
 END LOOP;
 IF result->>'lot'='' THEN RAISE EXCEPTION '원본 LOT 번호가 없습니다.';END IF;
 IF nullif(d->>'qty','') IS NOT NULL THEN result:=result||jsonb_build_object('qty',public.dnm_v4_qty(d->'qty','LOT 수량',false));
 ELSE result:=result||jsonb_build_object('qty',NULL);END IF;
 IF result->>'current_state' NOT IN('','NOT_STARTED','IN_PROGRESS','COMPLETED') THEN RAISE EXCEPTION '현재 진행상태를 확인하세요.';END IF;
 IF result->>'input_date'<>'' THEN
  IF result->>'input_date'!~'^\d{4}-\d{2}-\d{2}$' OR (result->>'input_date')::date NOT BETWEEN '2000-01-01' AND '2100-12-31' THEN RAISE EXCEPTION '투입일을 확인하세요.';END IF;
 END IF;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.dnm_v4103_source_review(p jsonb,k uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE prev public.dnm_v4_requests;src public.dnm_v4_records;item jsonb;d jsonb;meta jsonb;
 act text:=p->>'action';reason text;h text;result jsonb;changed jsonb:='[]';
BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION '관리자만 원문 전환 자료를 검토할 수 있습니다.' USING ERRCODE='42501';END IF;
 IF k IS NULL OR jsonb_typeof(p) IS DISTINCT FROM 'object' OR length(p::text)>1500000 OR act IS NULL OR act NOT IN('save','exclude','reopen') OR
  jsonb_typeof(p->'rows') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'rows') NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION '검토 대상 1~500건과 요청번호를 확인하세요.';END IF;
 reason:=public.dnm_v4_required(p->>'reason','검토 사유',1000);
 PERFORM pg_advisory_xact_lock(164040,1);h:=md5('v4103_review'||p::text);
 SELECT * INTO prev FROM public.dnm_v4_requests WHERE actor_id=auth.uid() AND request_key=k;
 IF FOUND THEN IF prev.payload_hash<>h THEN RAISE EXCEPTION '다른 내용에 사용된 요청번호입니다.';END IF;RETURN prev.result;END IF;
 IF (SELECT count(DISTINCT value->>'id') FROM jsonb_array_elements(p->'rows'))<>jsonb_array_length(p->'rows') THEN RAISE EXCEPTION '같은 원문을 중복 선택했습니다.';END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(p->'rows') LOOP
  SELECT * INTO src FROM public.dnm_v4_records WHERE id=(item->>'id')::uuid AND kind='source_routing' FOR UPDATE;
  IF src.id IS NULL THEN RAISE EXCEPTION '등록된 원문 자료를 선택하세요.';END IF;
  IF src.version IS DISTINCT FROM (item->>'version')::int THEN RAISE EXCEPTION '원문 검토 내용이 변경되었습니다. 다시 조회하세요.' USING ERRCODE='40001';END IF;
  IF EXISTS(SELECT FROM public.dnm_v4_records r WHERE r.kind='routing' AND r.data->>'source_routing_id'=src.id::text AND r.state NOT IN('CANCELLED','SUPERSEDED')) THEN
   RAISE EXCEPTION '이미 운영 전환한 원문입니다. 연결된 수주·LOT에서 관리하세요.';END IF;
  meta:=coalesce(src.data->'mes_transfer','{}');
  d:=dnm_private.v4103_values(src,coalesce(item->'values','{}'));
  meta:=meta||jsonb_build_object('review',d,'status',CASE WHEN act='exclude' THEN 'EXCLUDED' WHEN act='reopen' THEN 'PENDING' ELSE coalesce(meta->>'status','PENDING') END,
   'reason',reason,'reviewed_at',now(),'reviewed_by',auth.uid(),'last_error',NULL);
  UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('mes_transfer',meta) WHERE id=src.id RETURNING * INTO src;
  changed:=changed||jsonb_build_array(jsonb_build_object('id',src.id,'version',src.version));
 END LOOP;
 result:=jsonb_build_object('ok',true,'rows',changed,'count',jsonb_array_length(changed));
 INSERT INTO public.dnm_v4_requests(actor_id,request_key,action,payload_hash,result) VALUES(auth.uid(),k,'v4103_review_'||act,h,result);
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.dnm_v4103_convert_sources(p jsonb,k uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET statement_timeout='150s' AS $$
DECLARE prev public.dnm_v4_requests;src public.dnm_v4_records;ord public.dnm_v4_records;route public.dnm_v4_records;
 item jsonb;d jsonb;entry jsonb;meta jsonb;payload jsonb;result jsonb;created jsonb;valid jsonb:='[]';issues jsonb:='[]';linked jsonb:='[]';amounts jsonb:='[]';
 h text;reason text;part text;typ text;lot text;issue text;total bigint:=0;available bigint;new_order boolean;release_now boolean;allow_missing boolean;skip_bad boolean;idx int:=0;uid uuid:=auth.uid();new_ids uuid[];
BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION '관리자만 원문을 수주·작업지시로 전환할 수 있습니다.' USING ERRCODE='42501';END IF;
 IF uid IS NULL OR k IS NULL OR jsonb_typeof(p) IS DISTINCT FROM 'object' OR length(p::text)>2000000 OR jsonb_typeof(p->'rows') IS DISTINCT FROM 'array' OR
  jsonb_array_length(p->'rows') NOT BETWEEN 1 AND 500 OR p->>'reviewed' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION '전환 대상 1~500건과 검토 확인을 선택하세요.';END IF;
 reason:=public.dnm_v4_required(p->>'reason','전환 사유',1000);
 part:=public.dnm_v4_required(p->>'part_no','품번',100);typ:=coalesce(p->>'part_type','');
 release_now:=coalesce((p->>'release')::boolean,false);allow_missing:=coalesce((p->>'allow_missing_refs')::boolean,false);skip_bad:=coalesce((p->>'skip_invalid')::boolean,false);
 PERFORM public.dnm_v41_validate_steps(p->'steps');
 IF jsonb_array_length(p->'steps')*jsonb_array_length(p->'rows')>30000 THEN RAISE EXCEPTION '한 번에 생성하는 공정은 30,000개 이내입니다.';END IF;
 IF (SELECT count(DISTINCT value->>'id') FROM jsonb_array_elements(p->'rows'))<>jsonb_array_length(p->'rows') THEN RAISE EXCEPTION '같은 원문을 중복 선택했습니다.';END IF;
 PERFORM pg_advisory_xact_lock(164040,1);h:=md5('v4103_convert'||p::text);
 SELECT * INTO prev FROM public.dnm_v4_requests WHERE actor_id=uid AND request_key=k;
 IF FOUND THEN IF prev.payload_hash<>h THEN RAISE EXCEPTION '다른 내용에 사용된 요청번호입니다.';END IF;RETURN prev.result;END IF;
 new_order:=nullif(p->>'order_id','') IS NULL;
 IF NOT new_order THEN
  SELECT * INTO ord FROM public.dnm_v4_records WHERE id=(p->>'order_id')::uuid AND kind='order' FOR UPDATE;
  IF ord.id IS NULL OR ord.state<>'OPEN' OR ord.data->>'deleted'='true' OR dnm_private.v410_order_type(ord)<>'CIVIL' THEN RAISE EXCEPTION '삭제되지 않은 진행 중 민수 수주를 선택하세요.';END IF;
  IF ord.version IS DISTINCT FROM (p->>'order_version')::int THEN RAISE EXCEPTION '수주가 변경되었습니다. 다시 조회하세요.' USING ERRCODE='40001';END IF;
  IF ord.data->>'part_no' IS DISTINCT FROM part THEN RAISE EXCEPTION '원문과 연결 수주의 품번을 일치시키세요.';END IF;
 ELSE
  IF p->'order'->>'part_no' IS DISTINCT FROM part THEN RAISE EXCEPTION '새 수주의 품번을 확인하세요.';END IF;
 END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(p->'rows') LOOP
  src:=NULL;issue:=NULL;d:=NULL;lot:=NULL;
  BEGIN
   SELECT * INTO src FROM public.dnm_v4_records WHERE id=(item->>'id')::uuid AND kind='source_routing' FOR UPDATE;
   IF src.id IS NULL THEN RAISE EXCEPTION '등록된 원문을 찾지 못했습니다.';END IF;
   lot:=coalesce(nullif(src.data->>'lot',''),src.title);
   IF EXISTS(SELECT FROM public.dnm_v4_records r WHERE r.kind='routing' AND r.data->>'source_routing_id'=src.id::text AND r.state NOT IN('CANCELLED','SUPERSEDED')) THEN
    issues:=issues||jsonb_build_array(jsonb_build_object('id',src.id,'lot',lot,'code','ALREADY_CONVERTED','message','이미 전환된 원문입니다. 기존 LOT를 보존했습니다.'));CONTINUE;
   END IF;
   IF src.version IS DISTINCT FROM (item->>'version')::int THEN RAISE EXCEPTION '검토 내용이 변경되었습니다. 다시 조회하세요.';END IF;
   IF src.data->'mes_transfer'->>'status' IN('EXCLUDED','CONVERTED') THEN RAISE EXCEPTION '제외·전환 이력 자료입니다. 먼저 재검토로 돌린 뒤 확인하세요.';END IF;
   d:=dnm_private.v4103_values(src,coalesce(item->'values','{}'));
   IF d->>'part_no' IS DISTINCT FROM part OR d->>'part_type' IS DISTINCT FROM typ THEN RAISE EXCEPTION '품번과 TYPE이 같은 자료끼리 전환하세요.';END IF;
   IF nullif(d->>'part_name','') IS NULL OR d->>'qty' IS NULL THEN RAISE EXCEPTION '품명과 LOT 수량을 보완하세요.';END IF;
   IF d->>'current_state' NOT IN('NOT_STARTED','IN_PROGRESS') THEN RAISE EXCEPTION '현재 상태를 미착수 또는 작업 중으로 확인하세요. 완료·납품 자료는 제외하세요.';END IF;
   IF nullif(d->>'shop_order_no','') IS NOT NULL AND nullif(CASE WHEN new_order THEN p->'order'->>'shop_order_no' ELSE ord.data->>'shop_order_no' END,'') IS NOT NULL AND d->>'shop_order_no' IS DISTINCT FROM (CASE WHEN new_order THEN p->'order'->>'shop_order_no' ELSE ord.data->>'shop_order_no' END) THEN RAISE EXCEPTION '원문 S/O와 연결 수주의 S/O가 다릅니다.';END IF;
   d:=d||jsonb_build_object('shop_order_no',coalesce(nullif(d->>'shop_order_no',''),CASE WHEN new_order THEN p->'order'->>'shop_order_no' ELSE ord.data->>'shop_order_no' END,''),
    'heat_code',coalesce(nullif(d->>'heat_code',''),CASE WHEN new_order THEN p->'order'->>'heat_code' ELSE ord.data->>'heat_code' END,''));
   IF NOT allow_missing AND (d->>'shop_order_no'='' OR d->>'heat_code'='') THEN RAISE EXCEPTION 'S/O·Heat Code를 보완하거나 미기재 문서항목 확인을 선택하세요.';END IF;
   IF EXISTS(SELECT FROM public.dnm_v4_records r WHERE r.kind='routing' AND r.state NOT IN('CANCELLED','SUPERSEDED') AND (r.code=lot OR r.data->>'lot'=lot OR r.data->>'source_lot'=lot)) THEN RAISE EXCEPTION '같은 원본 LOT의 운영 Routing이 이미 있습니다. 원문 연결을 확인하세요.';END IF;
   IF (SELECT count(*) FROM jsonb_array_elements(p->'rows') v JOIN public.dnm_v4_records s ON s.id=(v.value->>'id')::uuid AND s.kind='source_routing' WHERE coalesce(nullif(s.data->>'lot',''),s.title)=lot)>1 THEN RAISE EXCEPTION '선택 자료에 같은 LOT 원문이 여러 건입니다. 사용할 원문 한 건을 확인하세요.';END IF;
  EXCEPTION WHEN raise_exception OR invalid_text_representation OR datetime_field_overflow OR invalid_datetime_format OR numeric_value_out_of_range THEN issue:=SQLERRM;
  END;
  IF issue IS NOT NULL THEN
   IF NOT skip_bad THEN RAISE EXCEPTION '%: %',coalesce(lot,item->>'id'),issue;END IF;
   issues:=issues||jsonb_build_array(jsonb_build_object('id',item->>'id','lot',coalesce(lot,''),'code','REVIEW_REQUIRED','message',issue));
   IF src.id IS NOT NULL AND (CASE WHEN item->>'version'~'^[0-9]{1,9}$' THEN src.version=(item->>'version')::int ELSE false END) THEN
    meta:=coalesce(src.data->'mes_transfer','{}')||jsonb_build_object('last_error',issue,'checked_at',now());
    UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('mes_transfer',meta) WHERE id=src.id;
   END IF;
   CONTINUE;
  END IF;
  valid:=valid||jsonb_build_array(jsonb_build_object('id',src.id,'review',d));
  amounts:=amounts||jsonb_build_array((d->>'qty')::bigint);total:=total+(d->>'qty')::bigint;
 END LOOP;
 IF jsonb_array_length(valid)>0 THEN
  IF new_order THEN
   payload:=p->'order'||jsonb_build_object('order_type','CIVIL','part_no',part);
   IF public.dnm_v4_qty(payload->'qty','수주수량',false)<total THEN RAISE EXCEPTION '수주수량은 전환 LOT 합계 %개 이상이어야 합니다.',total;END IF;
   result:=public.dnm_v4101_save_order(jsonb_build_object('data',payload),gen_random_uuid());
   SELECT * INTO ord FROM public.dnm_v4_records WHERE id=(result->>'id')::uuid;
  END IF;
  available:=(ord.data->>'qty')::bigint-dnm_private.v410_allocated(ord.id);
  IF total>available THEN RAISE EXCEPTION '전환 LOT 합계 %개가 수주 미배정 잔량 %개를 초과합니다.',total,available;END IF;
  payload:=jsonb_build_object('order_id',ord.id,'order_version',ord.version,'manager_id',p->>'manager_id','plan_date',p->>'plan_date','steps',p->'steps','quantities',amounts,'total_qty',total,'note',reason);
  created:=public.dnm_v410_split(payload,gen_random_uuid());
  FOR entry IN SELECT value FROM jsonb_array_elements(valid) LOOP
   d:=entry->'review';
   SELECT * INTO src FROM public.dnm_v4_records WHERE id=(entry->>'id')::uuid;
   SELECT * INTO route FROM public.dnm_v4_records WHERE id=(created->'ids'->>idx)::uuid;
   UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('lot',d->>'lot','source_lot',d->>'lot','source_routing_id',src.id,
    'shop_order_no',d->>'shop_order_no','heat_code',d->>'heat_code','input_date',d->>'input_date','part_type',d->>'part_type',
    'import_current_state',d->>'current_state','source_note',d->>'note','source_review_reason',reason,'source_bundle',src.data->>'seed_bundle',
    'document_refs_pending',(d->>'shop_order_no'='' OR d->>'heat_code'=''),'imported_without_history',true)
    WHERE id=route.id RETURNING * INTO route;
   meta:=coalesce(src.data->'mes_transfer','{}');
   meta:=meta||jsonb_build_object('status','CONVERTED','review',d,'order_id',ord.id,'route_id',route.id,'converted_at',now(),'converted_by',uid,'reason',reason,'last_error',NULL,
    'history',coalesce(meta->'history','[]')||jsonb_build_array(jsonb_build_object('order_id',ord.id,'route_id',route.id,'at',now(),'actor',uid,'reason',reason)));
   UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('mes_transfer',meta) WHERE id=src.id;
   linked:=linked||jsonb_build_array(jsonb_build_object('source_id',src.id,'lot',d->>'lot','route_id',route.id,'route_code',route.code));idx:=idx+1;
  END LOOP;
  IF release_now THEN
   -- Only the fresh, same-step civilian clones from this transaction are eligible.
   -- The canonical command validates the shared assignment/manager/parent rules once.
   -- Remaining clones use set-based state changes with the normal audit/touch triggers.
   -- Existing routes are never included and no existing function is replaced.
   SELECT array_agg(value::uuid) INTO new_ids FROM jsonb_array_elements_text(created->'ids');
   IF (SELECT count(*) FROM public.dnm_v4_records WHERE id=ANY(new_ids) AND kind='routing'
     AND parent_id=ord.id AND state='DRAFT' AND data->>'daily'='true')<>cardinality(new_ids) THEN
    RAISE EXCEPTION '전환 초안의 수주·상태를 다시 확인하세요.';
   END IF;
   SELECT * INTO route FROM public.dnm_v4_records WHERE id=new_ids[1];
   PERFORM public.dnm_v4_command('release_routing',jsonb_build_object('id',route.id,'version',route.version),gen_random_uuid());
   UPDATE public.dnm_v4_records SET state='WAIT' WHERE kind='operation' AND parent_id=ANY(new_ids) AND state='DRAFT';
   UPDATE public.dnm_v4_records SET state='RELEASED' WHERE kind='routing' AND id=ANY(new_ids) AND state='DRAFT';
  END IF;
 END IF;
 result:=jsonb_build_object('ok',true,'order_id',ord.id,'created',jsonb_array_length(linked),'lots',linked,'issues',issues,'released',release_now,
  'remaining',CASE WHEN ord.id IS NOT NULL THEN (ord.data->>'qty')::bigint-dnm_private.v410_allocated(ord.id) ELSE NULL END);
 INSERT INTO public.dnm_v4_requests(actor_id,request_key,action,payload_hash,result) VALUES(uid,k,'v4103_convert',h,result);
 RETURN result;
END $$;
-- Correct missing document references on a converted LOT without changing actual production.
CREATE OR REPLACE FUNCTION public.dnm_v4103_route_refs(p jsonb,k uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dnm_v4_records; o public.dnm_v4_records; src public.dnm_v4_records; previous public.dnm_v4_requests;
 so text;heat text;reason text;h text;result jsonb;meta jsonb;
BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION '관리자만 전환 LOT 문서항목을 보완할 수 있습니다.' USING ERRCODE='42501';END IF;
 IF k IS NULL OR jsonb_typeof(p) IS DISTINCT FROM 'object' OR length(p::text)>5000 THEN RAISE EXCEPTION '문서항목 보완 요청을 확인하세요.';END IF;
 so:=public.dnm_v4_required(p->>'shop_order_no','Shop Order No',100);heat:=public.dnm_v4_required(p->>'heat_code','Heat Code',100);
 reason:=public.dnm_v4_required(p->>'reason','보완 사유',1000);
 PERFORM pg_advisory_xact_lock(164040,1);h:=md5('v4103_refs'||p::text);
 SELECT * INTO previous FROM public.dnm_v4_requests WHERE actor_id=auth.uid() AND request_key=k;
 IF FOUND THEN IF previous.payload_hash<>h THEN RAISE EXCEPTION '다른 내용에 사용된 요청번호입니다.';END IF;RETURN previous.result;END IF;
 SELECT * INTO r FROM public.dnm_v4_records WHERE id=(p->>'id')::uuid AND kind='routing' FOR UPDATE;
 IF r.id IS NULL OR r.data->>'daily' IS DISTINCT FROM 'true' OR nullif(r.data->>'source_routing_id','') IS NULL OR r.state IN('CANCELLED','SUPERSEDED') THEN RAISE EXCEPTION '사용 중인 전환 민수 LOT를 선택하세요.';END IF;
 IF r.version IS DISTINCT FROM (p->>'version')::int THEN RAISE EXCEPTION 'LOT 정보가 변경되었습니다. 다시 조회하세요.' USING ERRCODE='40001';END IF;
 SELECT * INTO o FROM public.dnm_v4_records WHERE id=r.parent_id AND kind='order' FOR UPDATE;
 IF o.id IS NULL OR o.state='CANCELLED' OR o.data->>'deleted'='true' THEN RAISE EXCEPTION '삭제된 수주의 문서는 보완할 수 없습니다.';END IF;
 IF nullif(o.data->>'shop_order_no','') IS NOT NULL AND o.data->>'shop_order_no'<>so THEN RAISE EXCEPTION '연결 수주의 S/O와 다릅니다. 수주 정보를 먼저 확인하세요.';END IF;
 IF nullif(o.data->>'shop_order_no','') IS NULL THEN
  PERFORM public.dnm_v4101_save_order(jsonb_build_object('id',o.id,'version',o.version,'data',jsonb_build_object('shop_order_no',so)),gen_random_uuid());
 END IF;
 UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('shop_order_no',so,'heat_code',heat,'document_refs_pending',false,
  'document_ref_history',coalesce(data->'document_ref_history','[]')||jsonb_build_array(jsonb_build_object('at',now(),'by',auth.uid(),'reason',reason,
  'previous_shop_order_no',r.data->>'shop_order_no','previous_heat_code',r.data->>'heat_code','shop_order_no',so,'heat_code',heat)))
  WHERE id=r.id RETURNING * INTO r;
 SELECT * INTO src FROM public.dnm_v4_records WHERE id=(r.data->>'source_routing_id')::uuid AND kind='source_routing' FOR UPDATE;
 IF src.id IS NOT NULL AND src.data->'mes_transfer'->>'route_id'=r.id::text THEN
  meta:=src.data->'mes_transfer';meta:=meta||jsonb_build_object('review',coalesce(meta->'review','{}')||jsonb_build_object('shop_order_no',so,'heat_code',heat));
  UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('mes_transfer',meta) WHERE id=src.id;
 END IF;
 result:=jsonb_build_object('ok',true,'id',r.id,'version',r.version);
 INSERT INTO public.dnm_v4_requests(actor_id,request_key,action,payload_hash,result) VALUES(auth.uid(),k,'v4103_refs',h,result);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION dnm_private.v4103_deleted_order_guard(),dnm_private.v4103_values(public.dnm_v4_records,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.dnm_v4103_source_review(jsonb,uuid),public.dnm_v4103_convert_sources(jsonb,uuid),public.dnm_v4103_route_refs(jsonb,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dnm_v4103_source_review(jsonb,uuid),public.dnm_v4103_convert_sources(jsonb,uuid),public.dnm_v4103_route_refs(jsonb,uuid) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
