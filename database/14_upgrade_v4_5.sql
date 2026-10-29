-- DNM MES v4.5 - independent work-order assignments, parallel workers, per-day work, urgent pause/resume, bulk use-state.
-- Apply once AFTER database/12_upgrade_v4_4.sql. Keep all existing records; no DELETE/TRUNCATE.
BEGIN;
DO $$ BEGIN
 IF to_regprocedure('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)') IS NULL THEN RAISE EXCEPTION '기존 v4.2 명령함수 없음. v4.4 DB 설치상태부터 확인하세요.';END IF;
 IF to_regprocedure('public.dnm_v44_backup_api(text,jsonb)') IS NULL THEN RAISE EXCEPTION 'v4.4 백업 기능을 먼저 적용하세요.';END IF;
END $$;

CREATE OR REPLACE FUNCTION public.dnm_v41_validate_steps(steps jsonb) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE st jsonb;BEGIN
 IF jsonb_typeof(steps) IS DISTINCT FROM 'array' OR jsonb_array_length(steps) NOT BETWEEN 1 AND 60 THEN RAISE EXCEPTION '공정 1~60개를 입력하세요.';END IF;
 FOR st IN SELECT value FROM jsonb_array_elements(steps) LOOP
  PERFORM public.dnm_v4_required(st->>'code','공정번호',40);PERFORM public.dnm_v4_required(st->>'name','공정명',200);
  IF coalesce(st->>'kind','WORK') NOT IN('WORK','MATERIAL','INSPECTION','OUTSOURCE','PACK') THEN RAISE EXCEPTION '공정유형 오류';END IF;
  IF coalesce(st->>'inspection_code','') NOT IN('','M','I','V') THEN RAISE EXCEPTION '검사코드 오류';END IF;
  IF st ? 'employee_ids' AND (jsonb_typeof(st->'employee_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(st->'employee_ids')>20) THEN RAISE EXCEPTION '공정별 작업자는 20명 이내로 선택하세요.';END IF;
 END LOOP;
END $$;

-- Work-order-specific independent assignment; historical equipment/worker mappings are recommendations only.
CREATE OR REPLACE FUNCTION public.dnm_v45_team(process_name text,equipment uuid,employees jsonb,route_manager uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE eq public.dnm_v4_records;em public.dnm_v4_records; eid text; eids jsonb:='[]'::jsonb;pids jsonb:='[]'::jsonb;names text[]:=ARRAY[]::text[];first_id uuid;first_pid uuid;idx integer:=0;BEGIN
 IF jsonb_typeof(employees) IS DISTINCT FROM 'array' OR jsonb_array_length(employees) NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION '작업자 1~20명을 선택하세요.';END IF;
 SELECT * INTO eq FROM public.dnm_v4_records WHERE id=equipment AND kind='equipment' AND data->>'active'='true';
 IF eq.id IS NULL THEN RAISE EXCEPTION '사용 중인 설비를 선택하세요.';END IF;
 FOR eid IN SELECT value#>>'{}' FROM jsonb_array_elements(employees) LOOP
  SELECT * INTO em FROM public.dnm_v4_records WHERE id=eid::uuid AND kind='employee' AND data->>'active'='true';
  IF em.id IS NULL THEN RAISE EXCEPTION '선택한 작업자가 사용중지되었거나 없습니다.';END IF;
  IF eids ? em.id::text THEN RAISE EXCEPTION '같은 작업자를 한 공정에 중복 선택할 수 없습니다.';END IF;
  IF nullif(em.data->>'profile_id','') IS NULL OR NOT EXISTS(SELECT 1 FROM public.dnm_portal_profiles WHERE id=(em.data->>'profile_id')::uuid AND active)
    OR NOT dnm_private.acl_for((em.data->>'profile_id')::uuid,'worklogs','create') THEN RAISE EXCEPTION '%: 작업자 계정 또는 작업실적 권한을 확인하세요.',em.title;END IF;
  idx:=idx+1;IF idx=1 THEN first_id:=em.id;first_pid:=(em.data->>'profile_id')::uuid;END IF;
  eids:=eids||jsonb_build_array(em.id::text);pids:=pids||jsonb_build_array(em.data->>'profile_id');names:=array_append(names,em.title);
 END LOOP;
 RETURN jsonb_build_object('equipment_id',eq.id,'equipment_code',eq.code,'employee_id',first_id,'employee_ids',eids,'employee_name',array_to_string(names,', '),'profile_id',first_pid,'profile_ids',pids,'manager_id',route_manager);
END $$;
REVOKE ALL ON FUNCTION public.dnm_v45_team(text,uuid,jsonb,uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION dnm_private.dnm_v41_command_impl(p_action text,p_payload jsonb,p_key uuid) RETURNS jsonb
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
 IF p_action IN('release_routing','assign_operation','start_work','manual_work','pause_work','finish_work','confirm_work','cancel_work','manager_step','urgency','ack_urgency','purchase_decide','purchase_order','purchase_receive','purchase_return','settle','paid','quality','ship','customer_return','order_close') AND target_id IS NULL THEN RAISE EXCEPTION '대상 ID가 필요합니다.';END IF;
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
  -- 신규 품번은 템플릿 없이 수주에서 곧바로 Routing을 작성할 수 있습니다.
 -- 양산은 동일 품번의 검토완료 템플릿 또는 배포·종료된 과거 Routing만 참고 가능합니다.
 IF nullif(payload->>'template_id','') IS NOT NULL THEN
  SELECT * INTO other FROM public.dnm_v4_records WHERE id=(payload->>'template_id')::uuid AND kind='route_template';
  IF other.id IS NULL OR coalesce(other.data->>'part_no',other.code) IS DISTINCT FROM parent.data->>'part_no'
   OR other.state='INACTIVE' OR other.data->>'active'='false' OR other.data->>'review_required' IS DISTINCT FROM 'false'
  THEN RAISE EXCEPTION '고객 품번과 일치하는 사용 중인 공정템플릿만 선택하세요.';END IF;
  IF (payload->>'template_version')::integer IS DISTINCT FROM other.version THEN RAISE EXCEPTION '제품 공정이 변경되었습니다. 다시 조회하세요.' USING ERRCODE='40001';END IF;
 ELSE
  other:=NULL;
 END IF;
 IF nullif(payload->>'source_routing_id','') IS NOT NULL THEN
  SELECT * INTO eq FROM public.dnm_v4_records WHERE id=(payload->>'source_routing_id')::uuid AND kind='routing' AND state IN('RELEASED','DONE') AND data->>'part_no'=parent.data->>'part_no';
  IF eq.id IS NULL THEN RAISE EXCEPTION '같은 품번의 확정된 과거 Routing만 참고할 수 있습니다.';END IF;
 END IF;
 IF (payload->>'order_version')::integer IS DISTINCT FROM parent.version THEN RAISE EXCEPTION '수주가 변경되었습니다. 다시 조회하세요.' USING ERRCODE='40001';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_portal_products WHERE code=parent.data->>'part_no' AND NOT active) THEN RAISE EXCEPTION '사용 중지된 제품입니다. 기준정보를 확인하세요.';END IF;
  arr:=payload->'steps';PERFORM public.dnm_v41_validate_steps(arr);
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records w JOIN public.dnm_v4_records op ON w.parent_id=op.id JOIN public.dnm_v4_records ro ON op.parent_id=ro.id WHERE ro.parent_id=pid AND w.kind='worklog' AND w.state<>'CANCELLED') OR EXISTS(SELECT 1 FROM public.dnm_v4_records ro WHERE ro.kind='routing' AND ro.parent_id=pid AND ro.state='DONE') THEN RAISE EXCEPTION '실적 또는 완료 이력이 있는 경로는 보존해야 합니다. 기존 Routing을 확인하세요.';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records ev JOIN public.dnm_v4_records op ON ev.parent_id=op.id JOIN public.dnm_v4_records ro ON op.parent_id=ro.id WHERE ro.parent_id=pid AND ev.kind='material') THEN RAISE EXCEPTION '관리 공정 처리이력이 있어 경로를 교체할 수 없습니다.';END IF;
  IF NOT EXISTS(SELECT 1 FROM public.dnm_portal_profiles p LEFT JOIN public.dnm_v4_permissions pm ON pm.profile_id=p.id WHERE p.id=nullif(payload->>'manager_id','')::uuid AND p.active AND (p.role='admin' OR (p.role='member' AND 'production'=ANY(pm.capabilities)))) THEN RAISE EXCEPTION '생산관리 권한이 있는 담당 관리자를 선택하세요.';END IF;
  IF role_name<>'admin' AND payload->>'manager_id'<>uid::text THEN RAISE EXCEPTION '본인 담당 Routing만 작성할 수 있습니다.' USING ERRCODE='42501';END IF;
  SELECT coalesce(max((data->>'revision')::integer),0)+1 INTO rev FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=pid;
  d:=jsonb_build_object('order_id',pid,'production_no',parent.code,'part_no',parent.data->>'part_no','qty',parent.data->'qty','lot',coalesce(payload->>'lot',''),'serials',coalesce(payload->>'serials',''),'revision',rev,'manager_id',payload->>'manager_id','note',coalesce(payload->>'note',''),'project',parent.data->>'project','due_date',parent.data->>'due_date','grade_code',parent.data->>'grade_code','customer',parent.data->>'customer','po_no',parent.data->>'po_no','part_revision',coalesce(payload->>'part_revision',''),'input_date',coalesce(payload->>'input_date',''),'issue_date',coalesce(nullif(payload->>'issue_date',''),(now() AT TIME ZONE 'Asia/Seoul')::date::text),'material_spec',coalesce(payload->>'material_spec',''),'material_no',coalesce(payload->>'material_no',''),'insp_lot',coalesce(payload->>'insp_lot',''),'work_type',coalesce(payload->>'work_type','양산'),'template_id',CASE WHEN other.id IS NOT NULL THEN other.id ELSE NULL END,'template_version',CASE WHEN other.id IS NOT NULL THEN other.version ELSE NULL END,'source_routing_id',nullif(payload->>'source_routing_id',''),'source_mode',coalesce(payload->>'source_mode','blank'),'revision_note',coalesce(payload->>'revision_note','최초 작성'),'document_revision',coalesce(payload->>'document_revision','Rev.0'),'prepared_by_name',coalesce(payload->>'prepared_by_name',''),'reviewed_by_name',coalesce(payload->>'reviewed_by_name',''),'approved_by_name',coalesce(payload->>'approved_by_name',''),'form_no','F7031-03');
  IF d->>'input_date'<>'' THEN PERFORM (d->>'input_date')::date;END IF;PERFORM (d->>'issue_date')::date;
  r:=public.dnm_v4_put('routing',parent.code||'-R'||rev,parent.title,'DRAFT',pid,d);target_id:=r.id;i:=0;
  FOR item IN SELECT value FROM jsonb_array_elements(arr) LOOP
   i:=i+1;s:=coalesce(item->>'kind','WORK');
   v:=jsonb_build_object('seq',i,'op_code',item->>'code','kind',s,'qty',parent.data->'qty','note',coalesce(item->>'note',''),'inspection_code',coalesce(item->>'inspection_code',''),'equipment_label',coalesce(item->>'equipment_label',''),'order_id',pid,'production_no',parent.code,'part_no',parent.data->>'part_no','due_date',d->>'due_date','manager_id',d->>'manager_id','confirmed_qty',0,'equipment_id',coalesce(item->>'equipment_id',''),'employee_ids',coalesce(item->'employee_ids','[]'::jsonb));
   IF s='WORK' AND coalesce(item->>'equipment_id','')<>'' AND jsonb_typeof(item->'employee_ids')='array' THEN v:=v||jsonb_build_object('employee_ids',item->'employee_ids','employee_id',item->'employee_id');END IF;
   other:=public.dnm_v4_put('operation',target_id::text||'-'||i,item->>'name','DRAFT',target_id,v);
  END LOOP;result:=jsonb_build_object('ok',true,'id',target_id);
 ELSIF p_action='release_routing' THEN
  PERFORM public.dnm_v4_need('production');IF old.kind<>'routing' OR old.state<>'DRAFT' THEN RAISE EXCEPTION '초안 Routing만 배포할 수 있습니다.';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records op WHERE op.parent_id=old.id AND op.kind='operation' AND op.data->>'kind'='WORK' AND (coalesce(op.data->>'equipment_id','')='' OR jsonb_array_length(CASE WHEN jsonb_typeof(op.data->'employee_ids')='array' THEN op.data->'employee_ids' ELSE CASE WHEN coalesce(op.data->>'employee_id','')<>'' THEN jsonb_build_array(op.data->>'employee_id') ELSE '[]'::jsonb END END)=0)) THEN RAISE EXCEPTION '가공 공정의 설비와 작업자를 지정하세요.';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records w JOIN public.dnm_v4_records op ON w.parent_id=op.id JOIN public.dnm_v4_records ro ON op.parent_id=ro.id WHERE ro.parent_id=old.parent_id AND w.kind='worklog' AND w.state<>'CANCELLED') THEN RAISE EXCEPTION '기존 실적이 있어 경로를 교체할 수 없습니다.';END IF;
  IF role_name<>'admin' AND old.data->>'manager_id'<>uid::text THEN RAISE EXCEPTION '담당 생산관리자만 배포할 수 있습니다.' USING ERRCODE='42501';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records ro WHERE ro.kind='routing' AND ro.parent_id=old.parent_id AND ro.state='DONE') OR EXISTS(SELECT 1 FROM public.dnm_v4_records ev JOIN public.dnm_v4_records op ON ev.parent_id=op.id JOIN public.dnm_v4_records ro ON op.parent_id=ro.id WHERE ro.parent_id=old.parent_id AND ev.kind='material') THEN RAISE EXCEPTION '완료·처리이력이 있어 경로를 교체할 수 없습니다.';END IF;
  FOR item IN SELECT to_jsonb(op) FROM public.dnm_v4_records op WHERE op.parent_id=old.id AND op.kind='operation' AND op.data->>'kind'='WORK' LOOP
   v:=public.dnm_v45_team(item->>'title',(item->'data'->>'equipment_id')::uuid,CASE WHEN jsonb_typeof(item->'data'->'employee_ids')='array' AND jsonb_array_length(item->'data'->'employee_ids')>0 THEN item->'data'->'employee_ids' ELSE jsonb_build_array(item->'data'->>'employee_id') END,(old.data->>'manager_id')::uuid);
   UPDATE public.dnm_v4_records SET data=data||v WHERE id=(item->>'id')::uuid;
  END LOOP;

  UPDATE public.dnm_v4_records SET state='SUPERSEDED' WHERE kind='routing' AND parent_id=old.parent_id AND state IN('DRAFT','RELEASED') AND id<>old.id;
  UPDATE public.dnm_v4_records SET state='WAIT' WHERE kind='operation' AND parent_id=old.id;
  r:=public.dnm_v4_put(old.kind,old.code,old.title,'RELEASED',old.parent_id,old.data,old.id,old.version);result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action='assign_operation' THEN
  PERFORM public.dnm_v4_need('production');IF old.kind<>'operation' OR old.data->>'kind'<>'WORK' OR old.state NOT IN('DRAFT','WAIT') THEN RAISE EXCEPTION '대기/초안 작업만 배정 변경할 수 있습니다.';END IF;
  SELECT * INTO parent FROM public.dnm_v4_records WHERE id=old.parent_id;
  IF role_name<>'admin' AND parent.data->>'manager_id' IS DISTINCT FROM uid::text THEN RAISE EXCEPTION 'Routing 담당 관리자만 배정 변경할 수 있습니다.' USING ERRCODE='42501';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='worklog' AND parent_id=old.id AND state IN('ACTIVE','PENDING')) THEN RAISE EXCEPTION '진행 중 실적부터 처리한 후 배정을 변경하세요.';END IF;
  arr:=coalesce(payload->'employee_ids',CASE WHEN nullif(payload->>'employee_id','') IS NOT NULL THEN jsonb_build_array(payload->>'employee_id') ELSE '[]'::jsonb END);
  v:=public.dnm_v45_team(old.title,(payload->>'equipment_id')::uuid,arr,(parent.data->>'manager_id')::uuid);
  r:=public.dnm_v4_put(old.kind,old.code,old.title,old.state,old.parent_id,old.data||v,old.id,old.version);result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action IN('start_work','manual_work') THEN
  PERFORM public.dnm_v4_need('work');IF old.kind<>'operation' OR old.state NOT IN('WAIT','ACTIVE') OR old.data->>'kind'<>'WORK' THEN RAISE EXCEPTION '작업 가능한 가공 공정을 선택하세요.';END IF;
  SELECT * INTO parent FROM public.dnm_v4_records WHERE id=old.parent_id;
  IF parent.state<>'RELEASED' THEN RAISE EXCEPTION '배포된 Routing이 아닙니다.';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='operation' AND parent_id=old.parent_id AND (data->>'seq')::integer<(old.data->>'seq')::integer AND state<>'DONE') THEN RAISE EXCEPTION '선행 공정이 완료되지 않았습니다.';END IF;
  -- Selected employee is the current authenticated worker by default; production managers must explicitly select employee when acting for them.
  SELECT * INTO emp FROM public.dnm_v4_records WHERE kind='employee' AND data->>'active'='true' AND
     id=coalesce(nullif(payload->>'employee_id','')::uuid,(SELECT id FROM public.dnm_v4_records WHERE kind='employee' AND data->>'profile_id'=uid::text AND (coalesce(old.data->'employee_ids','[]'::jsonb) ? id::text) LIMIT 1));
  IF emp.id IS NULL THEN RAISE EXCEPTION '본인에게 배정된 작업자 또는 작업자 로그인을 확인하세요.';END IF;
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(old.data->'employee_ids',jsonb_build_array(old.data->>'employee_id'))) x WHERE x=emp.id::text) THEN RAISE EXCEPTION '배정되지 않은 작업자입니다.' USING ERRCODE='42501';END IF;
  IF emp.data->>'profile_id' IS DISTINCT FROM uid::text AND role_name<>'admin' AND NOT (public.dnm_v4_can('production') AND old.data->>'manager_id'=uid::text) THEN RAISE EXCEPTION '본인 배정작업만 시작할 수 있습니다.' USING ERRCODE='42501';END IF;
  SELECT * INTO eq FROM public.dnm_v4_records WHERE id=(old.data->>'equipment_id')::uuid AND kind='equipment' AND data->>'active'='true';IF eq.id IS NULL THEN RAISE EXCEPTION '사용 중인 설비를 선택하세요.';END IF;
  IF NOT EXISTS(SELECT 1 FROM public.dnm_portal_profiles WHERE id=nullif(emp.data->>'profile_id','')::uuid AND active) THEN RAISE EXCEPTION '작업자 로그인 계정이 비활성입니다.';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='worklog' AND parent_id=old.id AND state='PENDING') THEN RAISE EXCEPTION '수량 확인대기 실적부터 처리하세요.';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='worklog' AND parent_id=old.id AND state='ACTIVE' AND data->>'employee_id'=emp.id::text) THEN RAISE EXCEPTION '같은 작업자가 이미 이 공정을 시작했습니다.';END IF;
  -- An employee may have different simultaneous assignments; each start/stop is logged independently.
  a:=CASE WHEN p_action='manual_work' THEN (payload->>'start_at')::timestamptz ELSE now() END;
  b:=CASE WHEN p_action='manual_work' THEN (payload->>'end_at')::timestamptz ELSE NULL END;
  IF a>now()+interval '2 minutes' OR b>now()+interval '2 minutes' THEN RAISE EXCEPTION '미래 실적을 등록할 수 없습니다.';END IF;
  s:=coalesce(nullif(payload->>'work_date',''),(a AT TIME ZONE 'Asia/Seoul')::date::text);
  PERFORM s::date;IF s::date> (now() AT TIME ZONE 'Asia/Seoul')::date OR s::date < (now() AT TIME ZONE 'Asia/Seoul')::date-31 THEN RAISE EXCEPTION '작업일자는 오늘 또는 최근 31일 이내에서 선택하세요.';END IF;
  IF p_action='manual_work' THEN
   reason:=public.dnm_v4_required(payload->>'reason','수기 등록 사유',1000);mins:=public.dnm_v4_minutes(a,b);n:=public.dnm_v4_qty(payload->'total','총수량');n2:=public.dnm_v4_qty(payload->'defect','불량');IF n2>n THEN RAISE EXCEPTION '불량수량 초과';END IF;
   IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='worklog' AND parent_id=old.id AND data->>'employee_id'=emp.id::text AND state NOT IN('CANCELLED','PAUSED') AND (data->>'start_at')::timestamptz<b AND coalesce(nullif(data->>'end_at','')::timestamptz,now())>a) THEN RAISE EXCEPTION '같은 공정·작업자의 실적시간이 중복됩니다.';END IF;
  ELSE mins:=0;n:=NULL;n2:=NULL;reason:='';END IF;
  SELECT coalesce(sum((data->>'total')::numeric),0) INTO total FROM public.dnm_v4_records WHERE kind='worklog' AND parent_id=old.id AND state='CONFIRMED';IF total+coalesce(n,0)>(old.data->>'qty')::numeric THEN RAISE EXCEPTION '공정 지시수량을 초과합니다.';END IF;
  d:=old.data||jsonb_build_object('start_at',a,'end_at',b,'work_date',s,'minutes',mins,'total',n,'defect',n2,'good',n-n2,'reason',reason,'entered_by',uid,'employee_id',emp.id,'employee_name',emp.title,'profile_id',emp.data->>'profile_id','note',coalesce(payload->>'note',''),'input_mode',coalesce(payload->>'input_mode','touch'),'voice_original',left(coalesce(payload->>'voice_original',''),2000));
  r:=public.dnm_v4_put('worklog','WL-'||p_key::text,old.title,CASE WHEN b IS NULL THEN 'ACTIVE' ELSE 'CONFIRMED' END,old.id,d);
  UPDATE public.dnm_v4_records SET state=CASE WHEN b IS NULL THEN 'ACTIVE' WHEN total+n=(data->>'qty')::numeric THEN 'DONE' ELSE 'WAIT' END,data=data||jsonb_build_object('confirmed_qty',total+coalesce(n,0)) WHERE id=old.id;
  result:=jsonb_build_object('ok',true,'id',r.id);
 ELSIF p_action='pause_work' THEN
  PERFORM public.dnm_v4_need('work');IF old.kind<>'worklog' OR old.state<>'ACTIVE' THEN RAISE EXCEPTION '진행 중인 작업을 선택하세요.';END IF;
  IF old.data->>'profile_id' IS DISTINCT FROM uid::text AND role_name<>'admin' AND NOT (public.dnm_v4_can('production') AND old.data->>'manager_id'=uid::text) THEN RAISE EXCEPTION '본인 또는 담당 작업만 중지할 수 있습니다.' USING ERRCODE='42501';END IF;
  reason:=public.dnm_v4_required(payload->>'reason','일시중지 사유',500);
  a:=(old.data->>'start_at')::timestamptz;b:=now();mins:=public.dnm_v4_minutes(a,b);
  s:=coalesce(nullif(payload->>'work_date',''),old.data->>'work_date',(a AT TIME ZONE 'Asia/Seoul')::date::text);PERFORM s::date;
  d:=old.data||jsonb_build_object('end_at',b,'work_date',s,'minutes',mins,'pause_reason',reason,'paused_by',uid,'paused_at',now());
  r:=public.dnm_v4_put('worklog',old.code,old.title,'PAUSED',old.parent_id,d,old.id,old.version);
  SELECT * INTO parent FROM public.dnm_v4_records WHERE id=old.parent_id AND kind='operation';
  UPDATE public.dnm_v4_records SET state=CASE WHEN EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='worklog' AND parent_id=parent.id AND state='ACTIVE') THEN 'ACTIVE' WHEN EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='worklog' AND parent_id=parent.id AND state='PENDING') THEN 'PENDING' ELSE 'WAIT' END WHERE id=parent.id;
  result:=jsonb_build_object('ok',true,'id',r.id,'resumable',true);
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
   d:=old.data||jsonb_build_object('end_at',b,'work_date',coalesce(nullif(payload->>'work_date',''),old.data->>'work_date'),'minutes',mins,'total',n,'defect',n2,'good',n-n2,'defect_note',coalesce(payload->>'defect_note',''),'note',coalesce(payload->>'note',old.data->>'note',''),'input_mode',coalesce(payload->>'input_mode',old.data->>'input_mode','touch'),'voice_original',left(coalesce(payload->>'voice_original',old.data->>'voice_original',''),2000));
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
CREATE OR REPLACE FUNCTION public.dnm_v4_command(p_action text,p_payload jsonb,p_key uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE m text;a text;item jsonb;k text;target public.dnm_v4_records;arr jsonb;BEGIN
 IF public.dnm_portal_role() IS NULL THEN RAISE EXCEPTION '활성 로그인 계정이 필요합니다.' USING ERRCODE='42501';END IF;
 -- Same lock as the underlying command: permissions cannot change mid-validation.
 PERFORM pg_advisory_xact_lock(164040,1);
 IF p_action='permissions' THEN RAISE EXCEPTION 'v4.2 사용자별 메뉴·조회·등록·수정 권한 화면을 사용하세요.';END IF;
 IF p_action IN('save_master','import_masters') THEN
  arr:=CASE WHEN p_action='save_master' THEN jsonb_build_array(p_payload) ELSE p_payload->'rows' END;
  IF jsonb_typeof(arr) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION '기준정보 형식 오류';END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(arr) LOOP
   k:=item->>'kind';m:=dnm_private.kind_module(k);a:='create';
   IF k='settings' THEN
    IF public.dnm_portal_role()<>'admin' THEN RAISE EXCEPTION '관리자만 회사설정 변경 가능' USING ERRCODE='42501';END IF;
   ELSE
    IF m='' THEN RAISE EXCEPTION '권한 대상 기준정보 오류';END IF;
    SELECT * INTO target FROM public.dnm_v4_records WHERE kind=k AND code=item->>'code';
    IF FOUND OR (k='products' AND EXISTS(SELECT 1 FROM public.dnm_portal_products WHERE code=item->>'code')) THEN a:='update';END IF;
    IF p_action='import_masters' AND a='update' AND p_payload->>'updateExisting' IS DISTINCT FROM 'true' THEN
     PERFORM dnm_private.need(m,'read');
    ELSE
     PERFORM dnm_private.need(m,a);
     IF target.id IS NOT NULL AND public.dnm_v42_scope(m)='own' AND NOT dnm_private.own_record(target.kind,target.data,target.created_by,target.id) THEN RAISE EXCEPTION '담당 자료만 변경할 수 있습니다.' USING ERRCODE='42501';END IF;
     IF k='products' AND a='update' AND public.dnm_v42_scope(m)='own' AND NOT EXISTS(SELECT 1 FROM public.dnm_portal_products WHERE code=item->>'code' AND created_by=auth.uid()) THEN RAISE EXCEPTION '본인 제품만 변경 가능' USING ERRCODE='42501';END IF;
    END IF;
   END IF;
  END LOOP;
 ELSIF p_action IN('save_order','import_orders') THEN
  m:='orders';arr:=CASE WHEN p_action='save_order' THEN jsonb_build_array(p_payload->'data') ELSE p_payload->'rows' END;
  IF jsonb_typeof(arr) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION '수주 자료 형식 오류';END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(arr) LOOP
   SELECT * INTO target FROM public.dnm_v4_records WHERE kind='order' AND code=item->>'production_no';
   IF FOUND THEN
    IF p_action='import_orders' AND p_payload->>'updateExisting' IS DISTINCT FROM 'true' THEN PERFORM dnm_private.need(m,'read');
    ELSE
     PERFORM dnm_private.need(m,'update');
     IF public.dnm_v42_scope(m)='own' AND NOT dnm_private.own_record(target.kind,target.data,target.created_by,target.id) THEN RAISE EXCEPTION '담당 수주만 변경 가능' USING ERRCODE='42501';END IF;
    END IF;
   ELSE PERFORM dnm_private.need(m,'create');END IF;
  END LOOP;
 ELSE
  m:=CASE WHEN p_action IN('save_routing','release_routing','assign_operation','manager_step') THEN 'routing'
   WHEN p_action IN('start_work','manual_work','pause_work','finish_work','confirm_work','cancel_work','ack_urgency') THEN 'worklogs'
   WHEN p_action IN('urgency','order_close') THEN 'orders'
   WHEN p_action IN('purchase_submit','purchase_decide') THEN 'purchase'
   WHEN p_action IN('purchase_order','purchase_receive','purchase_return') THEN 'receipts'
   WHEN p_action IN('settle','paid') THEN 'settlement'
   WHEN p_action IN('quality','ship','customer_return') THEN 'quality' ELSE '' END;
  a:=CASE WHEN p_action IN('save_routing','start_work','manual_work','purchase_submit','purchase_receive','purchase_return','settle','quality','ship','customer_return') THEN 'create' WHEN p_action='purchase_decide' THEN 'read' ELSE 'update' END;
  IF m='' THEN RAISE EXCEPTION '지원하지 않는 업무 요청';END IF;PERFORM dnm_private.need(m,a);
  IF p_action='save_routing' THEN
   PERFORM dnm_private.need('orders','read');IF nullif(p_payload->>'template_id','') IS NOT NULL THEN PERFORM dnm_private.need('templates','read');END IF;
   SELECT * INTO target FROM public.dnm_v4_records WHERE id=nullif(p_payload->>'order_id','')::uuid AND kind='order';
   IF target.id IS NULL OR NOT public.dnm_v4_readable(target.kind,target.data,target.created_by,target.id) THEN RAISE EXCEPTION '조회 가능한 수주만 Routing 작성 가능' USING ERRCODE='42501';END IF;
  END IF;
 END IF;
 -- View permissions alone never authorize writes. Own-scope mutations are checked server-side.
 IF nullif(p_payload->>'id','') IS NOT NULL THEN
  SELECT * INTO target FROM public.dnm_v4_records WHERE id=(p_payload->>'id')::uuid;
  IF FOUND AND public.dnm_portal_role()<>'admin' AND public.dnm_v42_scope(m)='own' AND NOT dnm_private.own_record(target.kind,target.data,target.created_by,target.id) THEN RAISE EXCEPTION '본인 또는 담당 자료만 처리할 수 있습니다.' USING ERRCODE='42501';END IF;
 END IF;
 RETURN dnm_private.dnm_v41_command_impl(p_action,p_payload,p_key);
END $$;
CREATE OR REPLACE FUNCTION dnm_private.own_record(k text,d jsonb,owner uuid,rid uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(CASE WHEN k='employee' THEN d->>'profile_id'=auth.uid()::text WHEN k IN('worklog','operation') THEN d->>'profile_id'=auth.uid()::text OR d->>'manager_id'=auth.uid()::text OR coalesce(d->'profile_ids','[]'::jsonb) ? auth.uid()::text
 WHEN k='routing' THEN d->>'manager_id'=auth.uid()::text OR EXISTS(SELECT 1 FROM public.dnm_v4_records o WHERE o.kind='operation' AND o.parent_id=rid AND (o.data->>'profile_id'=auth.uid()::text OR coalesce(o.data->'profile_ids','[]'::jsonb) ? auth.uid()::text))
 WHEN k='equipment' THEN d->>'manager_id'=auth.uid()::text OR EXISTS(SELECT 1 FROM public.dnm_v4_records o WHERE o.kind='operation' AND o.data->>'equipment_id'=rid::text AND (o.data->>'profile_id'=auth.uid()::text OR coalesce(o.data->'profile_ids','[]'::jsonb) ? auth.uid()::text))
 WHEN k='purchase' THEN owner=auth.uid() OR EXISTS(SELECT 1 FROM jsonb_array_elements(coalesce(d->'approvals','[]'::jsonb)) a WHERE a->>'user_id'=auth.uid()::text)
 ELSE owner=auth.uid() END,false);
$$;

CREATE OR REPLACE FUNCTION public.dnm_v45_bulk_state(p_kind text,p_rows jsonb,p_active boolean,p_reason text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET statement_timeout='25s' AS $$
DECLARE e jsonb;r public.dnm_v4_records;d jsonb;n integer:=0;missing integer:=0;BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION '관리자만 사용 상태를 변경할 수 있습니다.' USING ERRCODE='42501';END IF;
 IF p_kind NOT IN('equipment','employee','material_master','catalog') THEN RAISE EXCEPTION '일괄 사용대상은 설비·작업자·자재·공구만 가능합니다.';END IF;
 PERFORM public.dnm_v4_required(p_reason,'사용상태 변경 사유',300);
 IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION '한 번에 1~200건을 선택하세요.';END IF;
 PERFORM pg_advisory_xact_lock(164040,1);
 FOR e IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
  SELECT * INTO r FROM public.dnm_v4_records WHERE id=(e->>'id')::uuid FOR UPDATE;
  IF r.id IS NULL OR r.kind<>p_kind OR r.version IS DISTINCT FROM (e->>'version')::integer THEN RAISE EXCEPTION '선택 자료 또는 버전이 변경되었습니다. 다시 조회하세요.' USING ERRCODE='40001';END IF;
  d:=r.data||jsonb_build_object('active',p_active,'reviewed_by',auth.uid(),'reviewed_at',now(),'review_reason',p_reason);
  IF p_active THEN
   IF r.kind IN('material_master','catalog') AND coalesce(r.data->>'unit','')='' THEN
    missing:=missing+1;d:=d||jsonb_build_object('unit_pending',true,'verified',false,'review_required',true);
   ELSE d:=d||jsonb_build_object('verified',true,'review_required',false,'unit_pending',false);END IF;
  END IF;
  PERFORM public.dnm_v4_put(r.kind,r.code,r.title,CASE WHEN p_active THEN 'OPEN' ELSE 'INACTIVE' END,r.parent_id,d,r.id,r.version);
  n:=n+1;
 END LOOP;
 INSERT INTO public.dnm_portal_audit(actor_id,entity,record_id,action,new_value) VALUES(auth.uid(),'dnm_v45_master',p_kind,CASE WHEN p_active THEN 'BULK_USE' ELSE 'BULK_STOP' END,jsonb_build_object('count',n,'missing_unit',missing,'reason',p_reason));
 RETURN jsonb_build_object('ok',true,'updated',n,'unit_pending',missing);
END $$;
REVOKE ALL ON FUNCTION public.dnm_v45_bulk_state(text,jsonb,boolean,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v45_bulk_state(text,jsonb,boolean,text) TO authenticated;

-- Preserve privileges and security boundaries from v4.4.
REVOKE ALL ON FUNCTION dnm_private.dnm_v41_command_impl(text,jsonb,uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.dnm_v4_command(text,jsonb,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v4_command(text,jsonb,uuid) TO authenticated;
COMMIT;
