-- DNM Cloud MES v4.6.0 · optional quotation, 1:1 purchase order, supplier payment ledger.
-- Run ONCE after 14_upgrade_v4_5.sql. No DELETE, TRUNCATE, account reset, or data migration.
-- Existing purchase/receipt/settlement rows are preserved. New payment rows reuse kind='settlement',
-- so v4.4 business-data backup/restore automatically includes them.
BEGIN;
DO $$ BEGIN
 IF to_regprocedure('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)') IS NULL THEN RAISE EXCEPTION 'v4.5 DB가 필요합니다. 기존 14_upgrade_v4_5.sql 적용 여부를 확인하세요.';END IF;
 IF to_regprocedure('public.dnm_v45_team(text,uuid,jsonb,uuid)') IS NULL THEN RAISE EXCEPTION 'v4.5 작업배정 확장을 먼저 확인하세요.';END IF;
 IF to_regprocedure('public.dnm_v44_backup_api(text,jsonb)') IS NULL THEN RAISE EXCEPTION 'v4.4 업무자료 백업 확장을 먼저 확인하세요.';END IF;
END $$;

CREATE OR REPLACE FUNCTION dnm_private.dnm_v46_purchase_impl(p_action text,p_payload jsonb,p_key uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET statement_timeout='25s' AS $$
DECLARE
 uid uuid:=auth.uid();role_name text:=public.dnm_portal_role();payload jsonb:=coalesce(p_payload,'{}');
 old public.dnm_v4_records;po public.dnm_v4_records;r public.dnm_v4_records;prev public.dnm_v4_requests;
 changed jsonb;result jsonb;hash text;target_id uuid;pid uuid;version integer;due date;issued date;
 amount numeric;used numeric;supplier text;reference text;reason text;day date;c text;
BEGIN
 IF uid IS NULL OR role_name IS NULL OR p_key IS NULL OR length(payload::text)>10000 THEN RAISE EXCEPTION '로그인 또는 요청정보를 확인하세요.' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(164040,1);
 hash:=md5(p_action||payload::text);
 SELECT * INTO prev FROM public.dnm_v4_requests WHERE actor_id=uid AND request_key=p_key;
 IF FOUND THEN
  IF prev.payload_hash<>hash THEN RAISE EXCEPTION '같은 요청번호에 다른 내용을 사용할 수 없습니다.';END IF;
  RETURN prev.result;
 END IF;
 target_id:=nullif(payload->>'id','')::uuid;version:=nullif(payload->>'version','')::integer;
 IF p_action IN('purchase_quote','purchase_order','purchase_payment_edit') THEN
  IF target_id IS NULL OR version IS NULL THEN RAISE EXCEPTION '문서 ID와 버전이 필요합니다.';END IF;
  SELECT * INTO old FROM public.dnm_v4_records WHERE public.dnm_v4_records.id=target_id FOR UPDATE;
  IF old.id IS NULL OR old.version<>version THEN RAISE EXCEPTION '대상 문서가 변경되었습니다. 다시 조회하세요.' USING ERRCODE='40001';END IF;
 END IF;
 IF p_action='purchase_quote' THEN
  -- Preserve the legacy purchase capability requirement as well as v4.2 module ACL.
  PERFORM public.dnm_v4_need('purchase');
  IF old.kind<>'purchase' OR old.state<>'APPROVED' THEN RAISE EXCEPTION '결재승인된 구매의뢰만 견적의뢰서를 발행합니다.';END IF;
  issued:=coalesce(nullif(payload->>'issued_date','')::date,(now() AT TIME ZONE 'Asia/Seoul')::date);
  due:=nullif(payload->>'response_due','')::date;
  IF issued<'2000-01-01' OR issued>'2100-12-31' OR (due IS NOT NULL AND (due<issued OR due>'2100-12-31')) THEN RAISE EXCEPTION '견적 의뢰일·회신 희망일을 확인하세요.';END IF;
  changed:=old.data||jsonb_build_object('quote_request',jsonb_build_object(
   'quote_no',coalesce(old.data->'quote_request'->>'quote_no','RQ-'||old.code),
   'issued_date',issued,'response_due',due,'note',left(coalesce(payload->>'note',''),2000),
   'requested_by',uid,'saved_at',now()));
  r:=public.dnm_v4_put('purchase',old.code,old.title,old.state,old.parent_id,changed,old.id,old.version);
  result:=jsonb_build_object('ok',true,'id',r.id,'quote_no',changed->'quote_request'->>'quote_no');
 ELSIF p_action='purchase_order' THEN
  PERFORM public.dnm_v4_need('purchase');
  IF old.kind<>'purchase' OR old.state<>'APPROVED' THEN RAISE EXCEPTION '결재승인된 구매의뢰만 발주할 수 있습니다. 한 의뢰당 발주 1건만 허용합니다.';END IF;
  c:=public.dnm_v4_required(payload->>'po_no','발주번호',100);
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records a WHERE a.kind='purchase' AND a.id<>old.id AND lower(a.data->>'po_no')=lower(c)) THEN RAISE EXCEPTION '이미 사용 중인 발주번호입니다.';END IF;
  issued:=coalesce(nullif(payload->>'po_date','')::date,(now() AT TIME ZONE 'Asia/Seoul')::date);
  due:=nullif(payload->>'po_delivery_date','')::date;
  IF issued<'2000-01-01' OR issued>'2100-12-31' OR (due IS NOT NULL AND (due<'2000-01-01' OR due>'2100-12-31')) THEN RAISE EXCEPTION '발주일·납기를 확인하세요.';END IF;
  changed:=old.data||jsonb_build_object('po_no',c,'po_date',issued,'po_delivery_date',due,
   'po_note',left(coalesce(payload->>'po_note',''),2000),'ordered_at',now(),'ordered_by',uid);
  r:=public.dnm_v4_put('purchase',old.code,old.title,'ORDERED',old.parent_id,changed,old.id,old.version);
  result:=jsonb_build_object('ok',true,'id',r.id,'po_no',c);
 ELSIF p_action IN('purchase_payment_add','purchase_payment_edit') THEN
  PERFORM public.dnm_v4_need('purchase');
  IF p_action='purchase_payment_edit' AND (old.kind<>'settlement' OR old.data->>'entry_type'<>'payment' OR old.state<>'PAID') THEN RAISE EXCEPTION '수정할 수 있는 지급기록을 선택하세요.';END IF;
  IF p_action='purchase_payment_edit' THEN reason:=public.dnm_v4_required(payload->>'reason','수정 사유',500);END IF;
  supplier:=public.dnm_v4_required(payload->>'supplier','지급처',200);
  IF coalesce(payload->>'amount','') !~ '^[0-9]{1,13}(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION '지급금액은 0원 초과, 소수점 2자리까지 입력하세요.';END IF;
  amount:=(payload->>'amount')::numeric;
  IF amount<=0 OR amount>9999999999999 THEN RAISE EXCEPTION '지급금액 범위를 확인하세요.';END IF;
  day:=nullif(payload->>'payment_date','')::date;
  IF day IS NULL OR day<'2000-01-01' OR day>'2100-12-31' THEN RAISE EXCEPTION '지급일을 확인하세요.';END IF;
  pid:=nullif(payload->>'purchase_id','')::uuid;
  IF pid IS NOT NULL THEN
   SELECT * INTO po FROM public.dnm_v4_records WHERE public.dnm_v4_records.id=pid AND kind='purchase' FOR UPDATE;
   IF po.id IS NULL OR po.state NOT IN('ORDERED','PARTIAL','RECEIVED','MATCHED') THEN RAISE EXCEPTION '발주된 유효한 발주서를 선택하세요.';END IF;
   IF btrim(po.data->>'supplier')<>supplier THEN RAISE EXCEPTION '거래처와 연결 발주서의 공급업체가 다릅니다.';END IF;
   IF NOT public.dnm_v4_readable(po.kind,po.data,po.created_by,po.id) THEN RAISE EXCEPTION '해당 발주서 조회권한이 없습니다.' USING ERRCODE='42501';END IF;
   SELECT coalesce(sum((x.data->>'amount')::numeric),0) INTO used FROM public.dnm_v4_records x
    WHERE x.kind='settlement' AND x.data->>'entry_type'='payment' AND x.parent_id=pid AND (target_id IS NULL OR x.id<>target_id);
   IF used+amount>(po.data->>'total')::numeric THEN RAISE EXCEPTION '해당 발주서의 누적 지급금액이 승인금액을 초과합니다.';END IF;
  END IF;
  reference:=left(coalesce(payload->>'reference',''),200);
  changed:=jsonb_build_object('entry_type','payment','supplier',supplier,'payment_date',day,'amount',amount,
   'reference',reference,'note',left(coalesce(payload->>'note',''),2000),'purchase_id',pid,
   'updated_by',uid,'recorded_at',CASE WHEN p_action='purchase_payment_edit' THEN coalesce(old.data->>'recorded_at',now()::text) ELSE now()::text END);
  IF p_action='purchase_payment_edit' THEN
   changed:=changed||jsonb_build_object('last_change_reason',reason,'last_changed_at',now());
   r:=public.dnm_v4_put('settlement',old.code,supplier,'PAID',old.parent_id,changed,old.id,old.version);
   -- Parent link cannot be changed through dnm_v4_put; explicitly align optional association.
   IF old.parent_id IS DISTINCT FROM pid THEN UPDATE public.dnm_v4_records SET parent_id=pid WHERE public.dnm_v4_records.id=r.id;END IF;
  ELSE
   r:=public.dnm_v4_put('settlement','PM-'||p_key::text,supplier,'PAID',pid,changed);
  END IF;
  result:=jsonb_build_object('ok',true,'id',r.id,'record_type','supplier_payment');
 ELSE RAISE EXCEPTION '지원하지 않는 구매업무입니다: %',p_action;END IF;
 INSERT INTO public.dnm_v4_requests(actor_id,request_key,action,payload_hash,result) VALUES(uid,p_key,p_action,hash,result);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION dnm_private.dnm_v46_purchase_impl(text,jsonb,uuid) FROM PUBLIC,anon,authenticated;

-- Wrap v4.5 central RPC: preserve every existing menu ACL/scope rule, and add 4 new purchase actions.
CREATE OR REPLACE FUNCTION public.dnm_v4_command(p_action text,p_payload jsonb,p_key uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE m text;a text;item jsonb;k text;target public.dnm_v4_records;arr jsonb;BEGIN
 IF public.dnm_portal_role() IS NULL THEN RAISE EXCEPTION '활성 로그인 계정이 필요합니다.' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(164040,1);
 IF p_action='permissions' THEN RAISE EXCEPTION '사용자별 메뉴·조회·등록·수정 권한 화면을 사용하세요.';END IF;
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
    IF p_action='import_masters' AND a='update' AND p_payload->>'updateExisting' IS DISTINCT FROM 'true' THEN PERFORM dnm_private.need(m,'read');
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
   WHEN p_action IN('purchase_order','purchase_quote','purchase_receive','purchase_return') THEN 'receipts'
   WHEN p_action IN('settle','paid','purchase_payment_add','purchase_payment_edit') THEN 'settlement'
   WHEN p_action IN('quality','ship','customer_return') THEN 'quality' ELSE '' END;
  a:=CASE WHEN p_action IN('save_routing','start_work','manual_work','purchase_submit','purchase_receive','purchase_return','settle','purchase_payment_add','quality','ship','customer_return') THEN 'create'
   WHEN p_action='purchase_decide' THEN 'read' ELSE 'update' END;
  IF m='' THEN RAISE EXCEPTION '지원하지 않는 업무 요청';END IF;PERFORM dnm_private.need(m,a);
  IF p_action='save_routing' THEN
   PERFORM dnm_private.need('orders','read');IF nullif(p_payload->>'template_id','') IS NOT NULL THEN PERFORM dnm_private.need('templates','read');END IF;
   SELECT * INTO target FROM public.dnm_v4_records WHERE id=nullif(p_payload->>'order_id','')::uuid AND kind='order';
   IF target.id IS NULL OR NOT public.dnm_v4_readable(target.kind,target.data,target.created_by,target.id) THEN RAISE EXCEPTION '조회 가능한 수주만 Routing 작성 가능' USING ERRCODE='42501';END IF;
  END IF;
 END IF;
 IF nullif(p_payload->>'id','') IS NOT NULL THEN
  SELECT * INTO target FROM public.dnm_v4_records WHERE id=(p_payload->>'id')::uuid;
  IF FOUND AND public.dnm_portal_role()<>'admin' AND public.dnm_v42_scope(m)='own' AND NOT dnm_private.own_record(target.kind,target.data,target.created_by,target.id) THEN RAISE EXCEPTION '본인 또는 담당 자료만 처리할 수 있습니다.' USING ERRCODE='42501';END IF;
 END IF;
 IF p_action IN('purchase_quote','purchase_order','purchase_payment_add','purchase_payment_edit') THEN
  RETURN dnm_private.dnm_v46_purchase_impl(p_action,p_payload,p_key);
 END IF;
 RETURN dnm_private.dnm_v41_command_impl(p_action,p_payload,p_key);
END $$;
REVOKE ALL ON FUNCTION public.dnm_v4_command(text,jsonb,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v4_command(text,jsonb,uuid) TO authenticated;
COMMENT ON FUNCTION public.dnm_v4_command(text,jsonb,uuid) IS 'DNM v4.6 purchase workflow / v4.5 MES permissions-preserving dispatcher';
COMMIT;
