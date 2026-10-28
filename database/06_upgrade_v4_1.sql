-- DNM Cloud MES v4.1.0 additive upgrade. Run after 04_upgrade_v4.sql.
-- Keeps v3 login/users/products/partners and every v4 order/routing/worklog.
-- Do not rerun 04 after 06: it would replace the new business functions.
BEGIN;
DO $$ BEGIN IF to_regclass('public.dnm_v4_records') IS NULL THEN RAISE EXCEPTION 'v4.0 확장 SQL(04)을 먼저 적용하세요.';END IF;END $$;
ALTER TABLE public.dnm_v4_records DROP CONSTRAINT IF EXISTS dnm_v4_records_kind_check;
ALTER TABLE public.dnm_v4_records ADD CONSTRAINT dnm_v4_records_kind_check CHECK(kind IN ('order','order_source','equipment','instrument','catalog','employee','assignment','route_template','routing','operation','worklog','purchase','receipt','inventory','settlement','quality','shipment','customer_return','material','urgency','quality_doc','batch','part_detail','settings','material_master','process_master'));
CREATE OR REPLACE FUNCTION public.dnm_v41_validate_steps(steps jsonb) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE st jsonb;BEGIN
 IF jsonb_typeof(steps) IS DISTINCT FROM 'array' OR jsonb_array_length(steps) NOT BETWEEN 1 AND 60 THEN RAISE EXCEPTION '공정 1~60개를 입력하세요.';END IF;
 FOR st IN SELECT value FROM jsonb_array_elements(steps) LOOP
  PERFORM public.dnm_v4_required(st->>'code','공정번호',40);PERFORM public.dnm_v4_required(st->>'name','공정명',200);
  IF coalesce(st->>'kind','WORK') NOT IN('WORK','MATERIAL','INSPECTION','OUTSOURCE','PACK') THEN RAISE EXCEPTION '공정유형 오류';END IF;
  IF coalesce(st->>'inspection_code','') NOT IN('','M','I','V') THEN RAISE EXCEPTION '검사코드 오류';END IF;
  IF coalesce(st->>'kind','WORK')='WORK' AND ((coalesce(st->>'equipment_id','')='')<>(coalesce(st->>'employee_id','')='')) THEN RAISE EXCEPTION '설비·작업자는 함께 선택하거나 모두 비워주세요.';END IF;
 END LOOP;END $$;
CREATE OR REPLACE FUNCTION public.dnm_v41_assignment(process_name text,equipment uuid,employee uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE eq public.dnm_v4_records;em public.dnm_v4_records;BEGIN
 SELECT * INTO eq FROM public.dnm_v4_records WHERE id=equipment AND kind='equipment' AND data->>'active'='true';
 SELECT * INTO em FROM public.dnm_v4_records WHERE id=employee AND kind='employee' AND data->>'active'='true';
 IF eq.id IS NULL OR em.id IS NULL THEN RAISE EXCEPTION '활성 설비·작업자를 선택하세요.';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.dnm_portal_profiles p LEFT JOIN public.dnm_v4_permissions a ON a.profile_id=p.id WHERE p.id=nullif(em.data->>'profile_id','')::uuid AND p.active AND (p.role='admin' OR (p.role='member' AND 'work'=ANY(coalesce(a.capabilities,ARRAY['work']::text[]))))) THEN RAISE EXCEPTION '작업자를 작업실적 권한이 있는 활성 로그인 계정과 연결하세요.';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.dnm_portal_profiles p LEFT JOIN public.dnm_v4_permissions a ON a.profile_id=p.id WHERE p.id=nullif(eq.data->>'manager_id','')::uuid AND p.active AND (p.role='admin' OR (p.role='member' AND 'production'=ANY(a.capabilities)))) THEN RAISE EXCEPTION '설비 담당자에게 생산관리 권한을 지정하세요.';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='assignment' AND data->>'active'='true' AND data->>'equipment_id'=eq.id::text AND data->>'employee_id'=em.id::text AND (data->'processes')?process_name) THEN RAISE EXCEPTION '설비·작업자·가능공정 연결을 먼저 등록하세요.';END IF;
 RETURN jsonb_build_object('equipment_id',eq.id,'equipment_code',eq.code,'employee_id',em.id,'employee_name',em.title,'profile_id',em.data->>'profile_id','manager_id',eq.data->>'manager_id');END $$;
CREATE OR REPLACE FUNCTION public.dnm_v41_sync_routing(route_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dnm_v4_records;n integer;pending integer;next_state text;BEGIN
 SELECT * INTO r FROM public.dnm_v4_records WHERE id=route_id AND kind='routing' AND state IN('RELEASED','DONE') FOR UPDATE;IF NOT FOUND THEN RETURN;END IF;
 SELECT count(*),count(*) FILTER(WHERE state<>'DONE') INTO n,pending FROM public.dnm_v4_records WHERE kind='operation' AND parent_id=r.id;
 next_state:=CASE WHEN n>0 AND pending=0 THEN 'DONE' ELSE 'RELEASED' END;
 IF EXISTS(SELECT 1 FROM public.dnm_v4_records w JOIN public.dnm_v4_records op ON op.id=w.parent_id WHERE op.parent_id=r.id AND w.kind='worklog' AND w.state IN('ACTIVE','PENDING')) THEN next_state:='RELEASED';END IF;
 IF next_state<>r.state THEN UPDATE public.dnm_v4_records SET state=next_state,data=data||jsonb_build_object('completed_at',CASE WHEN next_state='DONE' THEN now() ELSE NULL END,'completed_by',CASE WHEN next_state='DONE' THEN auth.uid() ELSE NULL END) WHERE id=r.id;END IF;
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v4_order_valid(d jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE n bigint;value numeric;k text;BEGIN
 PERFORM public.dnm_v4_required(d->>'production_no','생산오더',100);PERFORM public.dnm_v4_required(d->>'part_no','품번',100);PERFORM public.dnm_v4_required(d->>'customer','고객명',80);
 n:=public.dnm_v4_qty(d->'qty','발주수량',false);
 FOREACH k IN ARRAY ARRAY['due_date','order_date'] LOOP IF coalesce(d->>k,'')<>'' THEN PERFORM (d->>k)::date;END IF;END LOOP;
 IF coalesce(d->>'po_line','') !~ '^[[:alnum:] _/.-]{0,40}$' THEN RAISE EXCEPTION 'PO 행번호 형식 오류';END IF;
 IF coalesce(d->>'priority','NORMAL') NOT IN ('NORMAL','URGENT','CRITICAL') THEN RAISE EXCEPTION '우선순위 오류';END IF;
 IF d->>'received_qty' IS NOT NULL AND d->>'received_qty'<>'' THEN PERFORM public.dnm_v4_qty(d->'received_qty','입고수량');END IF;
 FOREACH k IN ARRAY ARRAY['unit_price','order_amount'] LOOP IF d->>k IS NOT NULL AND d->>k<>'' THEN value:=(d->>k)::numeric;IF value<0 OR value>9999999999999.99 OR value<>round(value,2) THEN RAISE EXCEPTION '발주단가·발주금액 범위/소수점 오류';END IF;END IF;END LOOP;
 RETURN (d-'source')||jsonb_build_object('qty',n,'priority',coalesce(d->>'priority','NORMAL'));
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v4_context() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('version','4.1.0','profile',to_jsonb(p),'capabilities',CASE WHEN p.role='admin' THEN '["master","production","purchase","quality","approve","work"]'::jsonb ELSE to_jsonb(coalesce(a.capabilities,ARRAY['work']::text[])) END,
 'people',coalesce((SELECT jsonb_agg(jsonb_build_object('id',u.id,'name',u.display_name,'role',u.role,'production',(u.role='admin' OR (u.role='member' AND 'production'=ANY(coalesce(z.capabilities,ARRAY[]::text[])))),'approver',(u.role='admin' OR (u.role='member' AND 'approve'=ANY(coalesce(z.capabilities,ARRAY[]::text[])))))) FROM public.dnm_portal_profiles u LEFT JOIN public.dnm_v4_permissions z ON z.profile_id=u.id WHERE u.active),'[]'::jsonb))
 FROM public.dnm_portal_profiles p LEFT JOIN public.dnm_v4_permissions a ON a.profile_id=p.id WHERE p.id=auth.uid() AND p.active;
$$;
CREATE OR REPLACE FUNCTION public.dnm_v4_command(p_action text,p_payload jsonb,p_key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET statement_timeout='25s' AS $$
DECLARE
 uid uuid:=auth.uid();role_name text;old public.dnm_v4_records;r public.dnm_v4_records;parent public.dnm_v4_records;other public.dnm_v4_records;emp public.dnm_v4_records;eq public.dnm_v4_records;
 payload jsonb:=coalesce(p_payload,'{}');d jsonb;item jsonb;v jsonb;arr jsonb;steps jsonb;result jsonb;prev_result public.dnm_v4_requests;
 target_id uuid;pid uuid;k text;c text;t text;s text;reason text;hash text;cnt integer:=0;inserted integer:=0;updated integer:=0;skipped integer:=0;i integer;j integer;idx integer;rev integer;expected integer;
 n bigint;n2 bigint;n3 bigint;total numeric;price numeric;a timestamptz;b timestamptz;mins integer;caps text[];limit_amount numeric;expires date;
BEGIN
 role_name:=public.dnm_portal_role();IF uid IS NULL OR role_name IS NULL THEN RAISE EXCEPTION '로그인 및 계정 활성화가 필요합니다.' USING ERRCODE='42501';END IF;
 IF p_key IS NULL OR length(payload::text)>4000000 THEN RAISE EXCEPTION '요청번호 또는 요청 크기를 확인하세요.';END IF;
 PERFORM pg_advisory_xact_lock(164040,1);
 hash:=md5(p_action||payload::text);SELECT * INTO prev_result FROM public.dnm_v4_requests WHERE actor_id=uid AND request_key=p_key;
 IF FOUND THEN IF prev_result.payload_hash<>hash THEN RAISE EXCEPTION '같은 요청번호에 다른 입력을 사용할 수 없습니다.';END IF;RETURN prev_result.result;END IF;
 target_id:=nullif(payload->>'id','')::uuid;expected:=nullif(payload->>'version','')::integer;
 IF p_action IN('release_routing','assign_operation','start_work','manual_work','finish_work','confirm_work','cancel_work','manager_step','urgency','ack_urgency','purchase_decide','purchase_order','purchase_receive','purchase_return','settle','paid','quality','ship','customer_return','order_close') AND target_id IS NULL THEN RAISE EXCEPTION '대상 ID가 필요합니다.';END IF;
 IF target_id IS NOT NULL THEN SELECT * INTO old FROM public.dnm_v4_records WHERE public.dnm_v4_records.id=target_id FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION '대상 자료가 없습니다.';END IF;IF expected IS DISTINCT FROM old.version THEN RAISE EXCEPTION '자료가 변경되었습니다. 다시 조회하세요.' USING ERRCODE='40001';END IF;END IF;

 IF p_action='permissions' THEN
  IF role_name<>'admin' THEN RAISE EXCEPTION '관리자 권한이 필요합니다.' USING ERRCODE='42501';END IF;
  pid:=(payload->>'profile_id')::uuid;IF NOT EXISTS(SELECT 1 FROM public.dnm_portal_profiles WHERE public.dnm_portal_profiles.id=pid) THEN RAISE EXCEPTION '계정이 없습니다.';END IF;
  SELECT coalesce(array_agg(x),ARRAY[]::text[]) INTO caps FROM jsonb_array_elements_text(coalesce(payload->'capabilities','[]')) x;
  IF NOT caps<@ARRAY['master','production','purchase','quality','approve','work']::text[] THEN RAISE EXCEPTION '권한명 오류';END IF;
  limit_amount:=coalesce((payload->>'delegation_limit')::numeric,0);IF limit_amount<0 THEN RAISE EXCEPTION '전결한도 오류';END IF;expires:=nullif(payload->>'delegation_until','')::date;
  IF limit_amount>0 AND expires IS NULL THEN RAISE EXCEPTION '전결 유효기간을 입력하세요.';END IF;
  INSERT INTO public.dnm_v4_permissions(profile_id,capabilities,delegation_limit,delegation_until) VALUES(pid,caps,limit_amount,expires) ON CONFLICT(profile_id) DO UPDATE SET capabilities=excluded.capabilities,delegation_limit=excluded.delegation_limit,delegation_until=excluded.delegation_until,updated_at=now();
  INSERT INTO public.dnm_portal_audit(actor_id,entity,record_id,action,new_value) VALUES(uid,'dnm_v4_permissions',pid::text,'SET_ACCESS',payload);
  result:=jsonb_build_object('ok',true);
 ELSIF p_action IN ('save_master','import_masters') THEN
  IF p_action='save_master' AND payload->>'kind'='quality_doc' AND public.dnm_v4_can('quality') THEN NULL; ELSE PERFORM public.dnm_v4_need('master'); END IF;
  IF p_action='import_masters' THEN
   IF payload->>'reviewed' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION '원본 검토 확인이 필요합니다.';END IF;
   reason:=public.dnm_v4_required(payload->>'reason','검토 사유',1000);arr:=payload->'rows';
  ELSE arr:=jsonb_build_array(payload);END IF;
  IF jsonb_typeof(arr) IS DISTINCT FROM 'array' OR jsonb_array_length(arr) NOT BETWEEN 1 AND 400 THEN RAISE EXCEPTION '한 번에 1~400행을 처리하세요.';END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(arr) LOOP
   k:=item->>'kind';IF k NOT IN ('equipment','instrument','catalog','employee','assignment','route_template','products','material_master','process_master','quality_doc','settings') THEN RAISE EXCEPTION '기준정보 종류 오류';END IF;
   c:=public.dnm_v4_required(item->>'code','코드',400);t:=public.dnm_v4_required(item->>'title','명칭',300);d:=coalesce(item->'data','{}');
   IF k='settings' AND role_name<>'admin' THEN RAISE EXCEPTION '회사 설정은 관리자만 가능합니다.';END IF;
   IF k='route_template' THEN
    PERFORM public.dnm_v41_validate_steps(d->'steps');
    d:=d||jsonb_build_object('part_no',c);
    IF p_action='save_master' THEN
     d:=d||jsonb_build_object('review_required',false,'active',coalesce((d->>'active')::boolean,true));
     INSERT INTO public.dnm_portal_products(code,name,project,unit) VALUES(c,t,coalesce(d->>'project',''),'EA') ON CONFLICT(code) DO NOTHING;
    END IF;
   END IF;
   IF k='process_master' THEN
    IF coalesce(d->>'kind','WORK') NOT IN ('WORK','MATERIAL','INSPECTION','OUTSOURCE','PACK') THEN RAISE EXCEPTION '공정유형 오류';END IF;
    IF coalesce(d->>'inspection_code','') NOT IN ('','M','I','V') THEN RAISE EXCEPTION '검사코드 오류';END IF;
   END IF;
   IF k='employee' THEN
    IF coalesce(d->>'profile_id','')<>'' AND NOT EXISTS(SELECT 1 FROM public.dnm_portal_profiles WHERE public.dnm_portal_profiles.id=(d->>'profile_id')::uuid AND active) THEN RAISE EXCEPTION '활성 로그인 계정과 연결하세요.';END IF;
    IF coalesce(d->>'profile_id','')<>'' AND EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='employee' AND code<>c AND data->>'profile_id'=d->>'profile_id') THEN RAISE EXCEPTION '이미 다른 작업자에 연결된 계정입니다.';END IF;
   END IF;
   IF k='equipment' AND coalesce(d->>'manager_id','')<>'' AND NOT EXISTS(SELECT 1 FROM public.dnm_portal_profiles WHERE public.dnm_portal_profiles.id=(d->>'manager_id')::uuid AND active AND role IN('admin','member')) THEN RAISE EXCEPTION '활성 생산관리자 계정을 선택하세요.';END IF;
   IF k='assignment' THEN
    IF NOT EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE public.dnm_v4_records.id=(d->>'equipment_id')::uuid AND kind='equipment') OR NOT EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE public.dnm_v4_records.id=(d->>'employee_id')::uuid AND kind='employee') THEN RAISE EXCEPTION '설비·작업자 연결을 확인하세요.';END IF;
   END IF;
   IF k='products' THEN
    INSERT INTO public.dnm_portal_products(code,name,project,unit) VALUES(c,t,coalesce(d->>'project',''),coalesce(d->>'unit','')) ON CONFLICT(code) DO NOTHING;
    GET DIAGNOSTICS cnt=ROW_COUNT;inserted:=inserted+cnt;skipped:=skipped+1-cnt;CONTINUE;
   END IF;
   SELECT * INTO other FROM public.dnm_v4_records WHERE kind=k AND code=c;
   IF FOUND THEN
    IF p_action='import_masters' AND coalesce(payload->>'updateExisting','false')<>'true' THEN skipped:=skipped+1;CONTINUE;END IF;
    IF p_action='import_masters' THEN
     IF (item->>'version')::integer IS DISTINCT FROM other.version THEN RAISE EXCEPTION '기준정보가 변경되었습니다. 다시 미리보기 하세요: %',c USING ERRCODE='40001';END IF;
     -- Imported source information never removes verified access/assignment fields.
     d:=d||jsonb_strip_nulls(jsonb_build_object('active',other.data->'active','profile_id',other.data->'profile_id','manager_id',other.data->'manager_id','verified',other.data->'verified','processes',other.data->'processes','unit',CASE WHEN coalesce(d->>'unit','')='' THEN other.data->'unit' ELSE d->'unit' END));
    ELSE IF (item->>'version')::integer IS DISTINCT FROM other.version THEN RAISE EXCEPTION '기준정보 변경 충돌' USING ERRCODE='40001';END IF;END IF;
    r:=public.dnm_v4_put(k,c,t,coalesce(item->>'state',other.state),other.parent_id,d,other.id,other.version);updated:=updated+1;
   ELSE r:=public.dnm_v4_put(k,c,t,coalesce(item->>'state','OPEN'),NULL,d);inserted:=inserted+1;END IF;
  END LOOP;
  result:=jsonb_build_object('ok',true,'id',r.id,'inserted',inserted,'updated',updated,'skipped',skipped);
 ELSIF p_action IN ('save_order','import_orders') THEN
  PERFORM public.dnm_v4_need('production');
  IF p_action='import_orders' THEN
   IF payload->>'reviewed' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION '원본 대조 확인이 필요합니다.';END IF;
   reason:=public.dnm_v4_required(payload->>'reason','검토 사유',1000);PERFORM public.dnm_v4_required(payload->>'customer','고객명',80);arr:=payload->'rows';
  ELSE arr:=jsonb_build_array(payload->'data');END IF;
  IF jsonb_typeof(arr) IS DISTINCT FROM 'array' OR jsonb_array_length(arr) NOT BETWEEN 1 AND 400 THEN RAISE EXCEPTION '한 번에 1~400행을 처리하세요.';END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(arr) LOOP
   d:=public.dnm_v4_order_valid(CASE WHEN p_action='import_orders' THEN item||jsonb_build_object('customer',payload->>'customer') ELSE item END);c:=d->>'production_no';
   SELECT * INTO other FROM public.dnm_v4_records WHERE kind='order' AND code=c;
   IF FOUND THEN
    IF p_action='import_orders' AND coalesce(payload->>'updateExisting','false')<>'true' THEN skipped:=skipped+1;CONTINUE;END IF;
    IF (CASE WHEN p_action='import_orders' THEN nullif(item->>'expected_version','')::integer ELSE expected END) IS DISTINCT FROM other.version THEN RAISE EXCEPTION '수주 변경 충돌. 다시 미리보기 하세요: %',c USING ERRCODE='40001';END IF;
    IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=other.id AND state IN('RELEASED','DONE')) AND (other.data->>'qty' IS DISTINCT FROM d->>'qty' OR other.data->>'part_no' IS DISTINCT FROM d->>'part_no') THEN RAISE EXCEPTION '배포된 수주의 품번·수량은 바로 변경할 수 없습니다: %',c;END IF;
    r:=public.dnm_v4_put('order',c,coalesce(nullif(d->>'part_name',''),d->>'part_no'),other.state,NULL,other.data||d,other.id,other.version);updated:=updated+1;
   ELSE r:=public.dnm_v4_put('order',c,coalesce(nullif(d->>'part_name',''),d->>'part_no'),'OPEN',NULL,d);inserted:=inserted+1;END IF;
   IF item?'source' THEN
    v:=item->'source';IF jsonb_typeof(v->'columns') IS DISTINCT FROM 'array' OR jsonb_typeof(v->'values') IS DISTINCT FROM 'array' OR jsonb_array_length(v->'columns')<>jsonb_array_length(v->'values') OR jsonb_array_length(v->'columns')>512 THEN RAISE EXCEPTION '원본 열 구조가 올바르지 않습니다.';END IF;
    SELECT * INTO parent FROM public.dnm_v4_records WHERE kind='order_source' AND code=r.id::text;
    other:=public.dnm_v4_put('order_source',r.id::text,c,'OPEN',r.id,v||jsonb_build_object('review_reason',reason),parent.id,parent.version);
   END IF;
  END LOOP;
  result:=jsonb_build_object('ok',true,'id',r.id,'inserted',inserted,'updated',updated,'skipped',skipped);
 ELSIF p_action='save_routing' THEN
  PERFORM public.dnm_v4_need('production');pid:=(payload->>'order_id')::uuid;
  SELECT * INTO parent FROM public.dnm_v4_records WHERE public.dnm_v4_records.id=pid AND kind='order' AND state='OPEN';
  IF NOT FOUND THEN RAISE EXCEPTION '진행 중 수주를 선택하세요.';END IF;
  SELECT * INTO other FROM public.dnm_v4_records WHERE public.dnm_v4_records.id=nullif(payload->>'template_id','')::uuid AND kind='route_template';
  IF other.id IS NULL OR coalesce(other.data->>'part_no',other.code) IS DISTINCT FROM parent.data->>'part_no' OR other.state='INACTIVE' OR other.data->>'active'='false' OR other.data->>'review_required' IS DISTINCT FROM 'false' THEN RAISE EXCEPTION '품번이 일치하는 검토완료 제품 Routing을 먼저 등록하세요.';END IF;
  IF (payload->>'template_version')::integer IS DISTINCT FROM other.version THEN RAISE EXCEPTION '제품 Routing이 변경되었습니다. 다시 불러오세요.' USING ERRCODE='40001';END IF;
  IF (payload->>'order_version')::integer IS DISTINCT FROM parent.version THEN RAISE EXCEPTION '수주가 변경되었습니다. 다시 조회하세요.' USING ERRCODE='40001';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_portal_products WHERE code=parent.data->>'part_no' AND NOT active) THEN RAISE EXCEPTION '사용 중지된 제품입니다. 기준정보를 확인하세요.';END IF;
  arr:=payload->'steps';PERFORM public.dnm_v41_validate_steps(arr);
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records w JOIN public.dnm_v4_records op ON w.parent_id=op.id JOIN public.dnm_v4_records ro ON op.parent_id=ro.id WHERE ro.parent_id=pid AND w.kind='worklog' AND w.state<>'CANCELLED') OR EXISTS(SELECT 1 FROM public.dnm_v4_records ro WHERE ro.kind='routing' AND ro.parent_id=pid AND ro.state='DONE') THEN RAISE EXCEPTION '실적 또는 완료 이력이 있는 경로는 보존해야 합니다. 기존 Routing을 확인하세요.';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records ev JOIN public.dnm_v4_records op ON ev.parent_id=op.id JOIN public.dnm_v4_records ro ON op.parent_id=ro.id WHERE ro.parent_id=pid AND ev.kind='material') THEN RAISE EXCEPTION '관리 공정 처리이력이 있어 경로를 교체할 수 없습니다.';END IF;
  IF NOT EXISTS(SELECT 1 FROM public.dnm_portal_profiles p LEFT JOIN public.dnm_v4_permissions pm ON pm.profile_id=p.id WHERE p.id=nullif(payload->>'manager_id','')::uuid AND p.active AND (p.role='admin' OR (p.role='member' AND 'production'=ANY(pm.capabilities)))) THEN RAISE EXCEPTION '생산관리 권한이 있는 담당 관리자를 선택하세요.';END IF;
  IF role_name<>'admin' AND payload->>'manager_id'<>uid::text THEN RAISE EXCEPTION '본인 담당 Routing만 작성할 수 있습니다.' USING ERRCODE='42501';END IF;
  SELECT coalesce(max((data->>'revision')::integer),0)+1 INTO rev FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=pid;
  d:=jsonb_build_object('order_id',pid,'production_no',parent.code,'part_no',parent.data->>'part_no','qty',parent.data->'qty','lot',coalesce(payload->>'lot',''),'serials',coalesce(payload->>'serials',''),'revision',rev,'manager_id',payload->>'manager_id','note',coalesce(payload->>'note',''),'project',parent.data->>'project','due_date',parent.data->>'due_date','grade_code',parent.data->>'grade_code','customer',parent.data->>'customer','po_no',parent.data->>'po_no','part_revision',coalesce(payload->>'part_revision',''),'input_date',coalesce(payload->>'input_date',''),'issue_date',coalesce(nullif(payload->>'issue_date',''),(now() AT TIME ZONE 'Asia/Seoul')::date::text),'material_spec',coalesce(payload->>'material_spec',''),'material_no',coalesce(payload->>'material_no',''),'insp_lot',coalesce(payload->>'insp_lot',''),'work_type',coalesce(payload->>'work_type','양산'),'template_id',other.id,'template_version',other.version,'revision_note',coalesce(payload->>'revision_note','최초 작성'),'document_revision',coalesce(payload->>'document_revision','Rev.0'),'prepared_by_name',coalesce(payload->>'prepared_by_name',''),'reviewed_by_name',coalesce(payload->>'reviewed_by_name',''),'approved_by_name',coalesce(payload->>'approved_by_name',''),'form_no','F7031-03');
  IF d->>'input_date'<>'' THEN PERFORM (d->>'input_date')::date;END IF;PERFORM (d->>'issue_date')::date;
  r:=public.dnm_v4_put('routing',parent.code||'-R'||rev,parent.title,'DRAFT',pid,d);target_id:=r.id;i:=0;
  FOR item IN SELECT value FROM jsonb_array_elements(arr) LOOP
   i:=i+1;s:=coalesce(item->>'kind','WORK');
   v:=jsonb_build_object('seq',i,'op_code',item->>'code','kind',s,'qty',parent.data->'qty','note',coalesce(item->>'note',''),'inspection_code',coalesce(item->>'inspection_code',''),'equipment_label',coalesce(item->>'equipment_label',''),'order_id',pid,'production_no',parent.code,'part_no',parent.data->>'part_no','due_date',d->>'due_date','manager_id',d->>'manager_id','confirmed_qty',0);
   IF s='WORK' AND coalesce(item->>'equipment_id','')<>'' THEN v:=v||public.dnm_v41_assignment(item->>'name',nullif(item->>'equipment_id','')::uuid,nullif(item->>'employee_id','')::uuid);END IF;
   other:=public.dnm_v4_put('operation',target_id::text||'-'||i,item->>'name','DRAFT',target_id,v);
  END LOOP;result:=jsonb_build_object('ok',true,'id',target_id);
 ELSIF p_action='release_routing' THEN
  PERFORM public.dnm_v4_need('production');IF old.kind<>'routing' OR old.state<>'DRAFT' THEN RAISE EXCEPTION '초안 Routing만 배포할 수 있습니다.';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records op WHERE op.parent_id=old.id AND op.kind='operation' AND op.data->>'kind'='WORK' AND (coalesce(op.data->>'equipment_id','')='' OR coalesce(op.data->>'employee_id','')='')) THEN RAISE EXCEPTION '가공 공정의 설비·작업자를 먼저 배정하세요.';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records w JOIN public.dnm_v4_records op ON w.parent_id=op.id JOIN public.dnm_v4_records ro ON op.parent_id=ro.id WHERE ro.parent_id=old.parent_id AND w.kind='worklog' AND w.state<>'CANCELLED') THEN RAISE EXCEPTION '기존 실적이 있어 경로를 교체할 수 없습니다.';END IF;
  IF role_name<>'admin' AND old.data->>'manager_id'<>uid::text THEN RAISE EXCEPTION '담당 생산관리자만 배포할 수 있습니다.' USING ERRCODE='42501';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records ro WHERE ro.kind='routing' AND ro.parent_id=old.parent_id AND ro.state='DONE') OR EXISTS(SELECT 1 FROM public.dnm_v4_records ev JOIN public.dnm_v4_records op ON ev.parent_id=op.id JOIN public.dnm_v4_records ro ON op.parent_id=ro.id WHERE ro.parent_id=old.parent_id AND ev.kind='material') THEN RAISE EXCEPTION '완료·처리이력이 있어 경로를 교체할 수 없습니다.';END IF;
  FOR item IN SELECT to_jsonb(op) FROM public.dnm_v4_records op WHERE op.parent_id=old.id AND op.kind='operation' AND op.data->>'kind'='WORK' LOOP
   v:=public.dnm_v41_assignment(item->>'title',(item->'data'->>'equipment_id')::uuid,(item->'data'->>'employee_id')::uuid);
   IF v->>'profile_id' IS DISTINCT FROM item->'data'->>'profile_id' OR v->>'manager_id' IS DISTINCT FROM item->'data'->>'manager_id' THEN RAISE EXCEPTION '설비·작업자 로그인/관리자 연결이 바뀌었습니다. 공정 배정을 다시 저장하세요.';END IF;
  END LOOP;

  UPDATE public.dnm_v4_records SET state='SUPERSEDED' WHERE kind='routing' AND parent_id=old.parent_id AND state IN('DRAFT','RELEASED') AND id<>old.id;
  UPDATE public.dnm_v4_records SET state='WAIT' WHERE kind='operation' AND parent_id=old.id;
  r:=public.dnm_v4_put(old.kind,old.code,old.title,'RELEASED',old.parent_id,old.data,old.id,old.version);result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action='assign_operation' THEN
  PERFORM public.dnm_v4_need('production');IF old.kind<>'operation' OR old.data->>'kind'<>'WORK' OR old.state NOT IN('DRAFT','WAIT') THEN RAISE EXCEPTION '대기/초안 작업만 배정 변경할 수 있습니다.';END IF;
  SELECT * INTO parent FROM public.dnm_v4_records WHERE public.dnm_v4_records.id=old.parent_id;
  IF role_name<>'admin' AND parent.data->>'manager_id' IS DISTINCT FROM uid::text AND old.data->>'manager_id' IS DISTINCT FROM uid::text THEN RAISE EXCEPTION '이 Routing의 담당 관리자가 아닙니다.' USING ERRCODE='42501';END IF;
  SELECT * INTO eq FROM public.dnm_v4_records WHERE public.dnm_v4_records.id=(payload->>'equipment_id')::uuid AND kind='equipment' AND data->>'active'='true';
  SELECT * INTO emp FROM public.dnm_v4_records WHERE public.dnm_v4_records.id=(payload->>'employee_id')::uuid AND kind='employee' AND data->>'active'='true';
  IF eq.id IS NULL OR emp.id IS NULL THEN RAISE EXCEPTION '사용 중인 설비와 작업자를 선택하세요.';END IF;
  IF NOT EXISTS(SELECT 1 FROM public.dnm_portal_profiles WHERE public.dnm_portal_profiles.id=nullif(emp.data->>'profile_id','')::uuid AND active AND role IN('admin','member')) THEN RAISE EXCEPTION '작업자를 활성 직원 로그인 계정과 먼저 연결하세요.';END IF;
  IF role_name<>'admin' AND parent.data->>'manager_id' IS DISTINCT FROM uid::text AND eq.data->>'manager_id' IS DISTINCT FROM uid::text THEN RAISE EXCEPTION '다른 관리자 설비로 재배정하려면 Routing 담당자에게 요청하세요.' USING ERRCODE='42501';END IF;
  PERFORM public.dnm_v41_assignment(old.title,eq.id,emp.id);
  IF NOT EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='assignment' AND data->>'equipment_id'=eq.id::text AND data->>'employee_id'=emp.id::text AND data->>'active'='true' AND (data->'processes')?old.title) THEN RAISE EXCEPTION '설비·작업자·가능공정 연결을 먼저 등록하세요. 공정명은 정확히 일치해야 합니다.';END IF;
  r:=public.dnm_v4_put(old.kind,old.code,old.title,old.state,old.parent_id,old.data||jsonb_build_object('equipment_id',eq.id,'equipment_code',eq.code,'employee_id',emp.id,'employee_name',emp.title,'profile_id',emp.data->>'profile_id','manager_id',eq.data->>'manager_id'),old.id,old.version);result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action IN('start_work','manual_work') THEN
  PERFORM public.dnm_v4_need('work');IF old.kind<>'operation' OR old.state<>'WAIT' OR old.data->>'kind'<>'WORK' THEN RAISE EXCEPTION '작업 가능한 가공 공정을 선택하세요.';END IF;
  SELECT * INTO parent FROM public.dnm_v4_records WHERE public.dnm_v4_records.id=old.parent_id;
  IF parent.state<>'RELEASED' THEN RAISE EXCEPTION '배포된 Routing이 아닙니다.';END IF;
  IF old.data->>'profile_id' IS DISTINCT FROM uid::text AND role_name<>'admin' AND NOT (public.dnm_v4_can('production') AND old.data->>'manager_id'=uid::text) THEN RAISE EXCEPTION '본인에게 배정된 작업만 입력할 수 있습니다.' USING ERRCODE='42501';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='operation' AND parent_id=old.parent_id AND (data->>'seq')::integer<(old.data->>'seq')::integer AND state<>'DONE') THEN RAISE EXCEPTION '선행 공정이 완료되지 않았습니다.';END IF;
  SELECT * INTO emp FROM public.dnm_v4_records WHERE public.dnm_v4_records.id=(old.data->>'employee_id')::uuid AND kind='employee' AND data->>'active'='true';
  SELECT * INTO eq FROM public.dnm_v4_records WHERE public.dnm_v4_records.id=(old.data->>'equipment_id')::uuid AND kind='equipment' AND data->>'active'='true';
  IF emp.id IS NULL OR eq.id IS NULL OR emp.data->>'profile_id' IS DISTINCT FROM old.data->>'profile_id' THEN RAISE EXCEPTION '설비·작업자 활성 상태와 현재 로그인 연결을 다시 확인하세요.';END IF;
  PERFORM public.dnm_v41_assignment(old.title,eq.id,emp.id);
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='worklog' AND parent_id=old.id AND state='PENDING') THEN RAISE EXCEPTION '수량 확인대기 실적을 먼저 확정하세요.';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='worklog' AND state='ACTIVE' AND (data->>'employee_id'=old.data->>'employee_id' OR data->>'equipment_id'=old.data->>'equipment_id')) THEN RAISE EXCEPTION '작업자 또는 설비에 진행 중 작업이 있습니다. 먼저 완료하세요.';END IF;
  a:=CASE WHEN p_action='manual_work' THEN (payload->>'start_at')::timestamptz ELSE now() END;
  b:=CASE WHEN p_action='manual_work' THEN (payload->>'end_at')::timestamptz ELSE NULL END;
  IF a>now()+interval '2 minutes' OR b>now()+interval '2 minutes' THEN RAISE EXCEPTION '미래 실적을 등록할 수 없습니다.';END IF;
  IF p_action='manual_work' THEN
   reason:=public.dnm_v4_required(payload->>'reason','수기 등록 사유',1000);mins:=public.dnm_v4_minutes(a,b);n:=public.dnm_v4_qty(payload->'total','총수량');n2:=public.dnm_v4_qty(payload->'defect','불량');IF n2>n THEN RAISE EXCEPTION '불량수량 초과';END IF;
   IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='worklog' AND state<>'CANCELLED' AND (data->>'employee_id'=old.data->>'employee_id' OR data->>'equipment_id'=old.data->>'equipment_id') AND (data->>'start_at')::timestamptz<b AND coalesce((data->>'end_at')::timestamptz,now())>a) THEN RAISE EXCEPTION '작업자 또는 설비의 실적 시간이 중복됩니다.';END IF;
  ELSE mins:=0;n:=NULL;n2:=NULL;reason:='';END IF;
  SELECT coalesce(sum((data->>'total')::numeric),0) INTO total FROM public.dnm_v4_records WHERE kind='worklog' AND parent_id=old.id AND state='CONFIRMED';IF total+coalesce(n,0)>(old.data->>'qty')::numeric THEN RAISE EXCEPTION '공정 지시수량을 초과합니다.';END IF;
  d:=old.data||jsonb_build_object('start_at',a,'end_at',b,'minutes',mins,'total',n,'defect',n2,'good',n-n2,'reason',reason,'entered_by',uid,'note',coalesce(payload->>'note',''),'input_mode',coalesce(payload->>'input_mode','touch'),'voice_original',left(coalesce(payload->>'voice_original',''),2000));
  r:=public.dnm_v4_put('worklog','WL-'||p_key::text,old.title,CASE WHEN b IS NULL THEN 'ACTIVE' ELSE 'CONFIRMED' END,old.id,d);
  UPDATE public.dnm_v4_records SET state=CASE WHEN b IS NULL THEN 'ACTIVE' WHEN total+n=(data->>'qty')::numeric THEN 'DONE' ELSE 'WAIT' END,data=data||jsonb_build_object('confirmed_qty',total+coalesce(n,0)) WHERE public.dnm_v4_records.id=old.id;
  result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action IN('finish_work','confirm_work','cancel_work') THEN
  PERFORM public.dnm_v4_need('work');IF old.kind<>'worklog' THEN RAISE EXCEPTION '작업일보를 선택하세요.';END IF;
  IF old.data->>'profile_id' IS DISTINCT FROM uid::text AND role_name<>'admin' AND NOT (public.dnm_v4_can('production') AND old.data->>'manager_id'=uid::text) THEN RAISE EXCEPTION '본인 실적만 처리할 수 있습니다.' USING ERRCODE='42501';END IF;
  SELECT * INTO parent FROM public.dnm_v4_records WHERE public.dnm_v4_records.id=old.parent_id;
  IF p_action='cancel_work' THEN
   PERFORM public.dnm_v4_need('production');reason:=public.dnm_v4_required(payload->>'reason','취소 사유',1000);
   IF old.state NOT IN('ACTIVE','PENDING','CONFIRMED') THEN RAISE EXCEPTION '이미 취소되었거나 취소할 수 없는 실적입니다.';END IF;
   IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE parent_id=(parent.data->>'order_id')::uuid AND kind IN('quality','shipment','customer_return')) THEN RAISE EXCEPTION '검사·출하 이력이 있어 실적 취소가 제한됩니다. 품질담당자 검토가 필요합니다.';END IF;
   IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='operation' AND parent_id=parent.parent_id AND (data->>'seq')::integer>(parent.data->>'seq')::integer AND state NOT IN('WAIT','DRAFT')) THEN RAISE EXCEPTION '후속 공정이 진행되어 실적 취소가 제한됩니다.';END IF;
   d:=old.data||jsonb_build_object('cancel_reason',reason);s:='CANCELLED';
  ELSE
   IF (p_action='finish_work' AND old.state<>'ACTIVE') OR (p_action='confirm_work' AND old.state<>'PENDING') THEN RAISE EXCEPTION '처리할 수 없는 실적 상태입니다.';END IF;
   a:=(old.data->>'start_at')::timestamptz;b:=CASE WHEN p_action='finish_work' THEN now() ELSE (old.data->>'end_at')::timestamptz END;mins:=public.dnm_v4_minutes(a,b);
   IF payload->>'pending'='true' AND p_action='finish_work' THEN n:=NULL;n2:=NULL;s:='PENDING';
   ELSE n:=public.dnm_v4_qty(payload->'total','총수량');n2:=public.dnm_v4_qty(payload->'defect','불량수량');IF n2>n THEN RAISE EXCEPTION '불량수량 초과';END IF;
    SELECT coalesce(sum((data->>'total')::numeric),0) INTO total FROM public.dnm_v4_records WHERE kind='worklog' AND parent_id=parent.id AND state='CONFIRMED' AND public.dnm_v4_records.id<>old.id;
    IF total+n>(parent.data->>'qty')::numeric THEN RAISE EXCEPTION '공정 지시수량을 초과합니다.';END IF;IF payload->>'complete_operation'='true' AND total+n<>(parent.data->>'qty')::numeric THEN RAISE EXCEPTION '공정 완료는 누적 처리수량이 지시수량과 같아야 합니다. 일부 작업은 종료로 등록하세요.';END IF;s:='CONFIRMED';END IF;
   d:=old.data||jsonb_build_object('end_at',b,'minutes',mins,'total',n,'defect',n2,'good',n-n2,'defect_note',coalesce(payload->>'defect_note',''),'note',coalesce(payload->>'note',old.data->>'note',''),'input_mode',coalesce(payload->>'input_mode',old.data->>'input_mode','touch'),'voice_original',left(coalesce(payload->>'voice_original',old.data->>'voice_original',''),2000));
  END IF;
  r:=public.dnm_v4_put(old.kind,old.code,old.title,s,old.parent_id,d,old.id,old.version);
  SELECT coalesce(sum((data->>'total')::numeric),0) INTO total FROM public.dnm_v4_records WHERE kind='worklog' AND parent_id=parent.id AND state='CONFIRMED';
  UPDATE public.dnm_v4_records SET state=CASE WHEN EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='worklog' AND parent_id=parent.id AND state='ACTIVE') THEN 'ACTIVE' WHEN EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='worklog' AND parent_id=parent.id AND state='PENDING') THEN 'PENDING' WHEN total=(parent.data->>'qty')::numeric THEN 'DONE' ELSE 'WAIT' END,data=data||jsonb_build_object('confirmed_qty',total) WHERE public.dnm_v4_records.id=parent.id;
  result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action='manager_step' THEN
  PERFORM public.dnm_v4_need('production');IF old.kind<>'operation' OR old.data->>'kind'='WORK' OR old.state NOT IN('WAIT','HOLD') THEN RAISE EXCEPTION '관리자 처리 대상 공정이 아닙니다.';END IF;
  SELECT * INTO parent FROM public.dnm_v4_records WHERE public.dnm_v4_records.id=old.parent_id;IF parent.state<>'RELEASED' THEN RAISE EXCEPTION '배포된 경로가 아닙니다.';END IF;
  IF role_name<>'admin' AND old.data->>'manager_id'<>uid::text THEN RAISE EXCEPTION '담당 관리자만 처리할 수 있습니다.';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='operation' AND parent_id=old.parent_id AND (data->>'seq')::integer<(old.data->>'seq')::integer AND state<>'DONE') THEN RAISE EXCEPTION '선행 공정 완료를 확인하세요.';END IF;
  reason:=public.dnm_v4_required(payload->>'note','처리 내용',2000);n:=public.dnm_v4_qty(payload->'qty','처리수량',false);IF n<>(old.data->>'qty')::bigint THEN RAISE EXCEPTION '이 단계 완료는 지시수량 전체 확인 후 처리하세요.';END IF;
  s:=coalesce(payload->>'state','DONE');IF s NOT IN('DONE','HOLD') THEN RAISE EXCEPTION '공정 처리상태 오류';END IF;
  r:=public.dnm_v4_put('material','EV-'||p_key::text,old.title,'CONFIRMED',old.id,jsonb_build_object('kind',old.data->>'kind','date',now(),'processor',uid,'qty',n,'note',reason,'state',s));
  UPDATE public.dnm_v4_records SET state=s,data=data||jsonb_build_object('confirmed_qty',CASE WHEN s='DONE' THEN n ELSE 0 END) WHERE public.dnm_v4_records.id=old.id;result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action='order_close' THEN
  PERFORM public.dnm_v4_need('production');IF old.kind<>'order' OR old.state<>'OPEN' THEN RAISE EXCEPTION '진행 중 수주만 마감할 수 있습니다.';END IF;
  reason:=public.dnm_v4_required(payload->>'reason','마감 확인 사유',1000);
  SELECT coalesce(sum((data->>'qty')::numeric),0) INTO total FROM public.dnm_v4_records WHERE kind='shipment' AND parent_id=old.id;
  SELECT coalesce(sum((data->>'qty')::bigint),0) INTO n FROM public.dnm_v4_records WHERE kind='customer_return' AND parent_id=old.id;
  IF total-n<(old.data->>'qty')::numeric THEN RAISE EXCEPTION '고객 주문수량의 출하와 반품 검토를 먼저 완료하세요.';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='worklog' AND data->>'order_id'=old.id::text AND state IN('ACTIVE','PENDING')) THEN RAISE EXCEPTION '진행 중/수량 미확정 실적이 있습니다.';END IF;
  r:=public.dnm_v4_put(old.kind,old.code,old.title,'CLOSED',NULL,old.data||jsonb_build_object('closed_at',now(),'closed_by',uid,'close_reason',reason),old.id,old.version);result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action='urgency' THEN
  PERFORM public.dnm_v4_need('production');IF old.kind<>'order' THEN RAISE EXCEPTION '수주를 선택하세요.';END IF;reason:=public.dnm_v4_required(payload->>'reason','긴급/납기 변경 사유',1000);s:=payload->>'priority';IF s NOT IN('NORMAL','URGENT','CRITICAL') THEN RAISE EXCEPTION '우선순위 오류';END IF;
  IF coalesce(payload->>'due_date','')<>'' THEN PERFORM (payload->>'due_date')::date;END IF;
  r:=public.dnm_v4_put('urgency','URG-'||p_key::text,old.title,'REQUESTED',old.id,jsonb_build_object('priority',s,'reason',reason,'due_date',payload->>'due_date','previous_due',old.data->>'due_date','approved_by',uid));
  UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('priority',s,'due_date',coalesce(nullif(payload->>'due_date',''),data->>'due_date')) WHERE public.dnm_v4_records.id=old.id;UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('due_date',coalesce(nullif(payload->>'due_date',''),old.data->>'due_date'),'priority',s) WHERE (kind='routing' AND parent_id=old.id AND state IN('DRAFT','RELEASED')) OR (kind='operation' AND data->>'order_id'=old.id::text AND state NOT IN('DONE','CANCELLED'));result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action='ack_urgency' THEN
  PERFORM public.dnm_v4_need('work');IF old.kind<>'urgency' THEN RAISE EXCEPTION '긴급지시 선택 오류';END IF;
  IF NOT public.dnm_v4_can('production') AND NOT EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='operation' AND data->>'order_id'=old.parent_id::text AND data->>'profile_id'=uid::text) THEN RAISE EXCEPTION '본인 배정작업의 긴급지시만 확인할 수 있습니다.' USING ERRCODE='42501';END IF;
  r:=public.dnm_v4_put(old.kind,old.code,old.title,'ACKNOWLEDGED',old.parent_id,old.data||jsonb_build_object('ack_by',uid,'ack_at',now()),old.id,old.version);result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action='purchase_submit' THEN
  IF role_name<>'member' AND role_name<>'admin' THEN RAISE EXCEPTION '구매요청 작성 권한이 없습니다.' USING ERRCODE='42501';END IF;
  d:=public.dnm_v4_purchase_valid(payload->'data');c:='PR-'||to_char(now(),'YYYYMMDD')||'-'||left(p_key::text,8);r:=public.dnm_v4_put('purchase',c,d->>'supplier','SUBMITTED',NULL,d);result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action='purchase_decide' THEN
  PERFORM public.dnm_v4_need('approve');IF old.kind<>'purchase' OR old.state<>'SUBMITTED' THEN RAISE EXCEPTION '결재 중인 구매요청만 처리할 수 있습니다.';END IF;
  d:=old.data;idx:=(d->>'current_step')::integer;steps:=d->'approvals';item:=steps->idx;
  IF item->>'user_id'<>uid::text OR old.created_by=uid THEN RAISE EXCEPTION '현재 순번의 결재자가 아니거나 자기 결재입니다.' USING ERRCODE='42501';END IF;
  reason:=public.dnm_v4_required(payload->>'reason','결재 의견',1000);s:=payload->>'decision';IF s NOT IN('APPROVE','REJECT','FINAL') THEN RAISE EXCEPTION '결재 구분 오류';END IF;
  IF s='FINAL' THEN
   SELECT delegation_limit,delegation_until INTO limit_amount,expires FROM public.dnm_v4_permissions WHERE profile_id=uid;
   IF coalesce(limit_amount,0)<(d->>'total')::numeric OR expires IS NULL OR expires<(now() AT TIME ZONE 'Asia/Seoul')::date THEN RAISE EXCEPTION '유효한 전결권·금액한도가 없습니다.' USING ERRCODE='42501';END IF;
   FOR i IN idx+1..jsonb_array_length(steps)-1 LOOP IF steps->i->>'required'='true' THEN RAISE EXCEPTION '후속 필수결재자는 생략할 수 없습니다.';END IF;END LOOP;
  END IF;
  steps:=jsonb_set(steps,ARRAY[idx::text],item||jsonb_build_object('state',CASE WHEN s='REJECT' THEN 'REJECTED' ELSE 'APPROVED' END,'opinion',reason,'at',now(),'delegated_final',s='FINAL'));
  IF s='FINAL' THEN FOR i IN idx+1..jsonb_array_length(steps)-1 LOOP steps:=jsonb_set(steps,ARRAY[i::text],steps->i||jsonb_build_object('state','SKIPPED','reason','권한자 전결','at',now()));END LOOP;END IF;
  t:=CASE WHEN s='REJECT' THEN 'REJECTED' WHEN s='FINAL' OR idx=jsonb_array_length(steps)-1 THEN 'APPROVED' ELSE 'SUBMITTED' END;
  r:=public.dnm_v4_put(old.kind,old.code,old.title,t,NULL,d||jsonb_build_object('approvals',steps,'current_step',idx+1),old.id,old.version);result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action='purchase_order' THEN
  PERFORM public.dnm_v4_need('purchase');IF old.kind<>'purchase' OR old.state<>'APPROVED' THEN RAISE EXCEPTION '승인된 요청만 발주할 수 있습니다.';END IF;
  c:=public.dnm_v4_required(payload->>'po_no','발주번호',100);r:=public.dnm_v4_put(old.kind,old.code,old.title,'ORDERED',NULL,old.data||jsonb_build_object('po_no',c,'ordered_at',now(),'ordered_by',uid),old.id,old.version);result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action='purchase_receive' THEN
  PERFORM public.dnm_v4_need('purchase');IF old.kind<>'purchase' OR old.state NOT IN('ORDERED','PARTIAL') THEN RAISE EXCEPTION '발주/부분입고 상태만 입고할 수 있습니다.';END IF;
  idx:=(payload->>'line')::integer;item:=old.data->'lines'->idx;IF item IS NULL OR idx<0 THEN RAISE EXCEPTION '발주 품목을 선택하세요.';END IF;
  n:=public.dnm_v4_qty(payload->'accepted','합격수량');n2:=public.dnm_v4_qty(payload->'rejected','불합격수량');IF n+n2=0 THEN RAISE EXCEPTION '입고수량은 1개 이상입니다.';END IF;
  SELECT coalesce(sum((data->>'accepted')::numeric),0) INTO total FROM public.dnm_v4_records WHERE kind='receipt' AND parent_id=old.id AND (data->>'line')::integer=idx;
  IF total+n>(item->>'qty')::numeric THEN RAISE EXCEPTION '누적 합격입고가 발주수량을 초과합니다.';END IF;
  r:=public.dnm_v4_put('receipt','GR-'||p_key::text,item->>'item','CONFIRMED',old.id,jsonb_build_object('line',idx,'accepted',n,'rejected',n2,'item',item->>'item','supplier',old.data->>'supplier','unit',item->>'unit','note',coalesce(payload->>'note',''),'received_at',now()));
  s:='RECEIVED';FOR i IN 0..jsonb_array_length(old.data->'lines')-1 LOOP SELECT coalesce(sum((data->>'accepted')::numeric),0) INTO total FROM public.dnm_v4_records WHERE kind='receipt' AND parent_id=old.id AND (data->>'line')::integer=i;IF total<(old.data->'lines'->i->>'qty')::numeric THEN s:='PARTIAL';END IF;END LOOP;
  UPDATE public.dnm_v4_records SET state=s WHERE public.dnm_v4_records.id=old.id;result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action='purchase_return' THEN
  PERFORM public.dnm_v4_need('purchase');IF old.kind<>'receipt' OR old.state<>'CONFIRMED' OR (old.data->>'accepted')::numeric<=0 THEN RAISE EXCEPTION '합격입고 기록을 선택하세요.';END IF;
  SELECT * INTO parent FROM public.dnm_v4_records WHERE public.dnm_v4_records.id=old.parent_id;IF parent.state IN('MATCHED','PAID') THEN RAISE EXCEPTION '정산 후 반품은 회계담당자 검토가 필요합니다.';END IF;
  n:=public.dnm_v4_qty(payload->'qty','반품수량',false);reason:=public.dnm_v4_required(payload->>'reason','반품 사유',1000);
  SELECT coalesce(sum(-(data->>'accepted')::numeric),0) INTO total FROM public.dnm_v4_records WHERE kind='receipt' AND data->>'original_receipt'=old.id::text;
  IF total+n>(old.data->>'accepted')::numeric THEN RAISE EXCEPTION '반품가능수량 초과';END IF;
  r:=public.dnm_v4_put('receipt','RT-'||p_key::text,old.title,'RETURNED',old.parent_id,old.data||jsonb_build_object('accepted',-n,'rejected',0,'original_receipt',old.id,'note',reason,'received_at',now()));
  UPDATE public.dnm_v4_records SET state='PARTIAL' WHERE public.dnm_v4_records.id=old.parent_id;result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action='settle' THEN
  PERFORM public.dnm_v4_need('purchase');IF old.kind<>'purchase' OR old.state<>'RECEIVED' THEN RAISE EXCEPTION '입고 완료 후 정산 대사를 진행하세요.';END IF;
  total:=(payload->>'invoice_amount')::numeric;IF total IS DISTINCT FROM (old.data->>'total')::numeric THEN RAISE EXCEPTION '증빙금액과 승인금액이 다릅니다. 원인을 먼저 확인하세요.';END IF;
  c:=public.dnm_v4_required(payload->>'invoice_no','증빙번호',100);r:=public.dnm_v4_put('settlement','ST-'||p_key::text,old.title,'MATCHED',old.id,jsonb_build_object('invoice_no',c,'amount',total,'matched_by',uid,'note',coalesce(payload->>'note','')));
  UPDATE public.dnm_v4_records SET state='MATCHED' WHERE public.dnm_v4_records.id=old.id;result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action='paid' THEN
  PERFORM public.dnm_v4_need('purchase');IF old.kind<>'settlement' OR old.state<>'MATCHED' THEN RAISE EXCEPTION '대사완료 정산을 선택하세요.';END IF;
  reason:=public.dnm_v4_required(payload->>'reference','지급 증빙 참조',200);r:=public.dnm_v4_put(old.kind,old.code,old.title,'PAID',old.parent_id,old.data||jsonb_build_object('payment_reference',reason,'paid_at',now()),old.id,old.version);
  UPDATE public.dnm_v4_records SET state='PAID' WHERE public.dnm_v4_records.id=old.parent_id;result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action IN('quality','ship','customer_return') THEN
  PERFORM public.dnm_v4_need('quality');IF old.kind<>'order' THEN RAISE EXCEPTION '수주를 선택하세요.';END IF;
  IF p_action='quality' THEN
   s:=coalesce(payload->>'stage','FINAL');IF s NOT IN('INPROCESS','FINAL') THEN RAISE EXCEPTION '검사단계 오류';END IF;
   n:=public.dnm_v4_qty(payload->'total','검사수량',false);n2:=public.dnm_v4_qty(payload->'defect','불합격수량');IF n2>n THEN RAISE EXCEPTION '불량수량 초과';END IF;
   IF s='FINAL' THEN
    IF NOT EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=old.id AND state IN('RELEASED','DONE')) OR EXISTS(SELECT 1 FROM public.dnm_v4_records op JOIN public.dnm_v4_records ro ON ro.id=op.parent_id WHERE ro.parent_id=old.id AND ro.state IN('RELEASED','DONE') AND op.kind='operation' AND op.state<>'DONE') THEN RAISE EXCEPTION '배포 Routing의 모든 공정 완료 후 최종검사 확정이 가능합니다.';END IF;
    SELECT coalesce(sum((data->>'total')::numeric),0) INTO total FROM public.dnm_v4_records WHERE kind='quality' AND parent_id=old.id AND state='CONFIRMED' AND data->>'stage'='FINAL';IF total+n>(old.data->>'qty')::numeric THEN RAISE EXCEPTION '최종검사 누적수량 초과';END IF;
   END IF;
   d:=jsonb_build_object('stage',s,'total',n,'defect',n2,'good',n-n2,'serials',coalesce(payload->>'serials',''),'report_no',coalesce(payload->>'report_no',''),'note',coalesce(payload->>'note',''),'inspected_by',uid);k:='quality';
  ELSIF p_action='ship' THEN
   n:=public.dnm_v4_qty(payload->'qty','출하수량',false);
   SELECT coalesce(sum((data->>'good')::numeric),0) INTO total FROM public.dnm_v4_records WHERE kind='quality' AND parent_id=old.id AND state='CONFIRMED' AND data->>'stage'='FINAL';
   SELECT coalesce(sum((data->>'qty')::bigint),0) INTO n2 FROM public.dnm_v4_records WHERE kind='shipment' AND parent_id=old.id;
   IF n+n2>total THEN RAISE EXCEPTION '최종 합격수량을 초과하여 출하할 수 없습니다.';END IF;
   d:=jsonb_build_object('qty',n,'delivery_no',public.dnm_v4_required(payload->>'delivery_no','납품번호',100),'serials',coalesce(payload->>'serials',''),'note',coalesce(payload->>'note',''));k:='shipment';
  ELSE
   n:=public.dnm_v4_qty(payload->'qty','고객 반품수량',false);SELECT coalesce(sum((data->>'qty')::bigint),0) INTO n2 FROM public.dnm_v4_records WHERE kind='shipment' AND parent_id=old.id;SELECT coalesce(sum((data->>'qty')::bigint),0) INTO n3 FROM public.dnm_v4_records WHERE kind='customer_return' AND parent_id=old.id;
   IF n+n3>n2 THEN RAISE EXCEPTION '누적 반품수량이 출하수량을 초과합니다.';END IF;
   d:=jsonb_build_object('qty',n,'reason',public.dnm_v4_required(payload->>'reason','고객 반품 사유',1000),'ncr_no',coalesce(payload->>'ncr_no',''));k:='customer_return';
  END IF;
  r:=public.dnm_v4_put(k,upper(k)||'-'||p_key::text,old.title,'CONFIRMED',old.id,d);result:=jsonb_build_object('ok',true,'id',r.id);
 ELSE RAISE EXCEPTION '지원하지 않는 업무 요청입니다: %',p_action;END IF;

 IF p_action IN('start_work','manual_work','manager_step') THEN PERFORM public.dnm_v41_sync_routing(old.parent_id);
 ELSIF p_action IN('finish_work','confirm_work','cancel_work') THEN PERFORM public.dnm_v41_sync_routing(parent.parent_id);END IF;
 INSERT INTO public.dnm_v4_requests(actor_id,request_key,action,payload_hash,result) VALUES(uid,p_key,p_action,hash,result);
 RETURN result;
END $$;

-- Master record mutations remain mediated by the authenticated entrypoint.
REVOKE ALL ON FUNCTION public.dnm_v41_validate_steps(jsonb),public.dnm_v41_assignment(text,uuid,uuid),public.dnm_v41_sync_routing(uuid),public.dnm_v4_order_valid(jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.dnm_v4_command(text,jsonb,uuid),public.dnm_v4_context() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v4_command(text,jsonb,uuid),public.dnm_v4_context() TO authenticated;
-- Existing released routes with all operations done can be recognized as completed without altering their worklogs.
DO $$ DECLARE r record;BEGIN FOR r IN SELECT id FROM public.dnm_v4_records WHERE kind='routing' AND state='RELEASED' LOOP PERFORM public.dnm_v41_sync_routing(r.id);END LOOP;END $$;

-- Align direct legacy master writes with v4 master capability (read policies remain unchanged).
ALTER POLICY dnm_product_add ON public.dnm_portal_products WITH CHECK ((SELECT public.dnm_v4_can('master')));
ALTER POLICY dnm_product_edit ON public.dnm_portal_products USING ((SELECT public.dnm_v4_can('master'))) WITH CHECK ((SELECT public.dnm_v4_can('master')));
ALTER POLICY dnm_partner_add ON public.dnm_portal_partners WITH CHECK ((SELECT public.dnm_v4_can('master')));
ALTER POLICY dnm_partner_edit ON public.dnm_portal_partners USING ((SELECT public.dnm_v4_can('master'))) WITH CHECK ((SELECT public.dnm_v4_can('master')));
NOTIFY pgrst,'reload schema';
COMMIT;
