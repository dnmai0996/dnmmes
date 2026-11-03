-- DNM MES 4.9.2 / 기존 4.9.1 운영 DB용
BEGIN;
SELECT pg_advisory_xact_lock(164040,1);
DO $$ BEGIN
 IF to_regprocedure('public.dnm_v49_purchase_catalog()') IS NULL THEN
  RAISE EXCEPTION '4.9 작업자·구매 SQL을 먼저 확인하세요.';
 END IF;
END $$;

CREATE OR REPLACE FUNCTION dnm_private.buyer_user() RETURNS uuid
LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT (data->>'user_id')::uuid FROM public.dnm_v4_records WHERE kind='settings' AND code='PURCHASE_REVIEWER'
$$;
CREATE OR REPLACE FUNCTION dnm_private.buyer_valid(u uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.dnm_portal_profiles WHERE id=u AND active AND role IN('member','admin'))
 AND dnm_private.acl_for(u,'purchase','read')
 AND NOT EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='employee' AND data->>'profile_id'=u::text AND data->>'active' IS DISTINCT FROM 'true')
$$;
CREATE OR REPLACE FUNCTION public.dnm_v492_buyer() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=dnm_private.buyer_user();
BEGIN
 PERFORM dnm_private.need('purchase','read');
 RETURN jsonb_build_object('ok',true,'user_id',u,'name',(SELECT display_name FROM public.dnm_portal_profiles WHERE id=u),'active',dnm_private.buyer_valid(u));
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v492_set_buyer(p_user uuid,p_previous uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dnm_v4_records; nm text;
BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION '관리자만 지정할 수 있습니다.';END IF;
 PERFORM pg_advisory_xact_lock(164040,1);
 IF NOT dnm_private.buyer_valid(p_user) THEN RAISE EXCEPTION '사용 중이며 구매 조회 권한이 있는 일반사용자 또는 관리자를 선택하세요.';END IF;
 SELECT * INTO r FROM public.dnm_v4_records WHERE kind='settings' AND code='PURCHASE_REVIEWER';
 IF (r.data->>'user_id')::uuid IS NOT DISTINCT FROM p_user THEN RETURN '{"ok":true}';END IF;
 IF (r.data->>'user_id')::uuid IS DISTINCT FROM p_previous THEN RAISE EXCEPTION '담당자가 변경되었습니다. 다시 조회하세요.';END IF;
 SELECT display_name INTO nm FROM public.dnm_portal_profiles WHERE id=p_user;
 IF EXISTS(SELECT FROM public.dnm_v4_records WHERE kind='purchase' AND state IN ('SUBMITTED','APPROVED')
 AND data ? 'buyer_review' AND data->'buyer_review'->>'at' IS NULL AND data->'approvals' @> jsonb_build_array(jsonb_build_object('user_id',p_user))) THEN
 RAISE EXCEPTION '새 담당자가 아직 확인하지 않은 의뢰의 결재선에 있습니다. 다른 담당자를 선택하세요.';END IF;
 PERFORM public.dnm_v4_put('settings','PURCHASE_REVIEWER','구매담당자','OPEN',NULL,jsonb_build_object('user_id',p_user),r.id,r.version);
 UPDATE public.dnm_v4_records SET data=jsonb_set(data,'{buyer_review}',jsonb_build_object('user_id',p_user,'name',nm))
 WHERE kind='purchase' AND state IN ('SUBMITTED','APPROVED') AND data ? 'buyer_review' AND data->'buyer_review'->>'at' IS NULL;
 RETURN '{"ok":true}';
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v492_review(p_id uuid,p_version int) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dnm_v4_records;
BEGIN
 PERFORM dnm_private.need('purchase','read');
 PERFORM pg_advisory_xact_lock(164040,1);
 SELECT * INTO r FROM public.dnm_v4_records WHERE id=p_id AND kind='purchase' FOR UPDATE;
 IF r.id IS NULL OR (r.data->'buyer_review'->>'user_id')::uuid IS DISTINCT FROM auth.uid() OR NOT dnm_private.buyer_valid(auth.uid()) THEN RAISE EXCEPTION '지정된 구매담당자만 확인할 수 있습니다.';END IF;
 IF r.data->'buyer_review'->>'at' IS NOT NULL THEN RETURN '{"ok":true}';END IF;
 IF r.version<>p_version OR p_version IS NULL OR r.state NOT IN ('SUBMITTED','APPROVED') THEN RAISE EXCEPTION '구매의뢰를 다시 조회하세요.';END IF;
 UPDATE public.dnm_v4_records SET data=jsonb_set(data,'{buyer_review,at}',to_jsonb(now())) WHERE id=p_id;
 RETURN '{"ok":true}';
END $$;

CREATE OR REPLACE FUNCTION dnm_private.reviewed_request(d jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path='' AS $$
DECLARE u uuid:=dnm_private.buyer_user(); validated jsonb; clean jsonb;
BEGIN
 IF NOT dnm_private.buyer_valid(u) THEN RAISE EXCEPTION '관리자가 사용자별 권한·전결에서 구매담당자를 지정해야 합니다.';END IF;
 IF EXISTS(SELECT FROM jsonb_array_elements(d->'approvals') a WHERE (a->>'user_id')::uuid=u) THEN RAISE EXCEPTION '구매담당자는 별도 확인란에 자동 지정됩니다. 결재선에서 제외하세요.';END IF;
 clean:=jsonb_build_object('supplier',coalesce(nullif(btrim(d->>'supplier'),''),'미정'),'lines',d->'lines','approvals',d->'approvals','note',d->>'note','due_date',d->>'due_date','tax_rate',d->'tax_rate');
 validated:=public.dnm_v4_purchase_valid(clean);
 RETURN validated||jsonb_build_object('buyer_review',jsonb_build_object('user_id',u,'name',(SELECT display_name FROM public.dnm_portal_profiles WHERE id=u)));
END $$;
CREATE OR REPLACE FUNCTION dnm_private.price(v text) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
BEGIN
 IF v IS NULL OR v !~ '^[0-9]{1,11}(\.[0-9]{1,2})?$' OR v::numeric>10000000000 THEN RAISE EXCEPTION '단가는 0~100억원, 소수 두 자리까지 입력하세요.';END IF;
 RETURN v::numeric;
END $$;
CREATE OR REPLACE FUNCTION dnm_private.order_terms(d jsonb,p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE supplier text; lines jsonb:='[]'; line jsonb; cost numeric; amount numeric; sub numeric:=0; tax numeric; i int:=0;
BEGIN
 IF d ? 'buyer_review' AND d->'buyer_review'->>'at' IS NULL THEN RAISE EXCEPTION '발주 전에 구매담당자 확인이 필요합니다.';END IF;
 supplier:=public.dnm_v4_required(p->>'order_supplier','발주 구매처',200);
 IF supplier='미정' THEN RAISE EXCEPTION '실제 발주 구매처를 입력하세요.';END IF;
 IF jsonb_typeof(p->'prices') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'prices')<>jsonb_array_length(d->'lines') THEN RAISE EXCEPTION '발주 품목별 단가를 입력하세요. 화면을 새로고침하세요.';END IF;
 FOR line IN SELECT value FROM jsonb_array_elements(d->'lines') LOOP
  cost:=dnm_private.price(p->'prices'->>i); amount:=cost*(line->>'qty')::numeric; sub:=sub+amount;
  lines:=lines||jsonb_build_array(line||jsonb_build_object('unit_price',cost,'amount',amount)); i:=i+1;
 END LOOP;
 tax:=round(sub*coalesce((d->>'tax_rate')::numeric,0),2);
 RETURN jsonb_build_object('request_terms',jsonb_build_object('supplier',d->'supplier','lines',d->'lines','subtotal',d->'subtotal','tax',d->'tax','total',d->'total'),
 'supplier',supplier,'lines',lines,'subtotal',sub,'tax',tax,'total',sub+tax,'received_total',0);
END $$;
CREATE OR REPLACE FUNCTION dnm_private.received_total(po public.dnm_v4_records) RETURNS numeric
LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT round(coalesce(sum((r.data->>'accepted')::numeric*coalesce((r.data->>'unit_price')::numeric,
 (po.data->'lines'->((r.data->>'line')::int)->>'unit_price')::numeric)),0)*(1+coalesce((po.data->>'tax_rate')::numeric,0)),2)
 FROM public.dnm_v4_records r WHERE r.kind='receipt' AND r.parent_id=po.id
$$;
-- Patch only named branches in the installed command implementations. A different baseline aborts the transaction.
CREATE OR REPLACE FUNCTION pg_temp.dnm_patch(sig regprocedure,old_text text,new_text text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE src text:=pg_get_functiondef(sig);
BEGIN
 IF strpos(src,new_text)>0 THEN RETURN;END IF;
 IF sig IS NULL OR (length(src)-length(replace(src,old_text,'')))/length(old_text)<>1 THEN RAISE EXCEPTION '기존 DB 함수 버전이 일치하지 않습니다: %',sig;END IF;
 EXECUTE replace(src,old_text,new_text);
END $$;
SELECT pg_temp.dnm_patch('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)'::regprocedure,$old$d:=public.dnm_v4_purchase_valid(payload->'data')$old$,$new$d:=dnm_private.reviewed_request(payload->'data')$new$);
SELECT pg_temp.dnm_patch('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)'::regprocedure,$old$'supplier',old.data->>'supplier','unit',item->>'unit'$old$,$new$'supplier',old.data->>'supplier','unit_price',dnm_private.price(coalesce(payload->>'unit_price',item->>'unit_price')),'unit',item->>'unit'$new$);
SELECT pg_temp.dnm_patch('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)'::regprocedure,$old$SET state=s WHERE public.dnm_v4_records.id=old.id;result$old$,$new$SET state=s,data=data||jsonb_build_object('received_total',dnm_private.received_total(old)) WHERE public.dnm_v4_records.id=old.id;result$new$);
SELECT pg_temp.dnm_patch('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)'::regprocedure,$old$SET state='PARTIAL' WHERE public.dnm_v4_records.id=old.parent_id$old$,$new$SET state='PARTIAL',data=data||jsonb_build_object('received_total',dnm_private.received_total(parent)) WHERE public.dnm_v4_records.id=old.parent_id$new$);
SELECT pg_temp.dnm_patch('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)'::regprocedure,$old$IF total IS DISTINCT FROM (old.data->>'total')::numeric THEN RAISE EXCEPTION '증빙금액과 승인금액이 다릅니다. 원인을 먼저 확인하세요.'$old$,$new$IF total IS DISTINCT FROM dnm_private.received_total(old) THEN RAISE EXCEPTION '증빙금액과 반품 차감 후 실제 입고금액(VAT 포함)이 다릅니다.'$new$);
SELECT pg_temp.dnm_patch('dnm_private.dnm_v46_purchase_impl(text,jsonb,uuid)'::regprocedure,$old$changed:=old.data||jsonb_build_object('po_no',c$old$,$new$changed:=old.data||dnm_private.order_terms(old.data,payload)||jsonb_build_object('po_no',c$new$);
SELECT pg_temp.dnm_patch('dnm_private.dnm_v46_purchase_impl(text,jsonb,uuid)'::regprocedure,$old$'purchase',old.code,old.title,'ORDERED'$old$,$new$'purchase',old.code,changed->>'supplier','ORDERED'$new$);
SELECT pg_temp.dnm_patch('dnm_private.dnm_v46_purchase_impl(text,jsonb,uuid)'::regprocedure,$old$IF used+amount>(po.data->>'total')::numeric THEN RAISE EXCEPTION '해당 발주서의 누적 지급금액이 승인금액을 초과합니다.'$old$,$new$IF used+amount>coalesce((po.data->>'received_total')::numeric,(po.data->>'total')::numeric) THEN RAISE EXCEPTION '누적 지급금액이 정산 가능 금액을 초과합니다.'$new$);
SELECT pg_temp.dnm_patch('dnm_private.own_record(text,jsonb,uuid,uuid)'::regprocedure,$old$WHEN k='purchase' THEN owner=auth.uid()$old$,$new$WHEN k='purchase' THEN d->'buyer_review'->>'user_id'=auth.uid()::text OR owner=auth.uid()$new$);
SELECT pg_temp.dnm_patch('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)'::regprocedure,$old$'seq',i,'op_code',item->>'code'$old$,$new$'seq',i,'process_master_code',item->>'process_master_code','op_code',item->>'code'$new$);

-- A stale open editor must not reintroduce a corrected master key.
CREATE OR REPLACE FUNCTION dnm_private.check_process_steps(steps jsonb) RETURNS void
LANGUAGE plpgsql STABLE SET search_path='' AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(steps) st
 WHERE nullif(st->>'process_master_code','') IS NOT NULL AND NOT EXISTS(SELECT FROM public.dnm_v4_records m
 WHERE m.kind='process_master' AND m.code=st->>'process_master_code')) THEN
 RAISE EXCEPTION '현재 기준정보에 없는 공정코드입니다. 다시 조회하여 기준 공정코드를 선택하세요.';END IF;
END $$;
REVOKE ALL ON FUNCTION dnm_private.check_process_steps(jsonb) FROM PUBLIC,anon,authenticated;
SELECT pg_temp.dnm_patch('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)'::regprocedure,
 $old$arr:=payload->'steps';PERFORM public.dnm_v41_validate_steps(arr);$old$,
 $new$arr:=payload->'steps';PERFORM public.dnm_v41_validate_steps(arr);PERFORM dnm_private.check_process_steps(arr);$new$);
SELECT pg_temp.dnm_patch('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)'::regprocedure,
 $old$PERFORM public.dnm_v41_validate_steps(d->'steps');$old$,
 $new$PERFORM public.dnm_v41_validate_steps(d->'steps');IF p_action='save_master' THEN PERFORM dnm_private.check_process_steps(d->'steps');END IF;$new$);
-- Process master keys and Routing step sequence numbers are independent.
CREATE OR REPLACE FUNCTION dnm_private.process_step_match(step jsonb,m public.dnm_v4_records) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT CASE WHEN nullif(step->>'process_master_code','') IS NOT NULL THEN step->>'process_master_code'=m.code
 ELSE step->>'name'=m.title AND coalesce(step->>'kind','WORK')=coalesce(m.data->>'kind','WORK')
 AND coalesce(step->>'inspection_code','')=coalesce(m.data->>'inspection_code','') END
$$;
CREATE OR REPLACE FUNCTION public.dnm_v492_process(p_id uuid,p_version int,p_code text,p_token text DEFAULT NULL,p_delete boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE m public.dnm_v4_records; r public.dnm_v4_records; nextcode text; updated jsonb; steps jsonb; st jsonb;
 counts jsonb:='{}'; ids uuid[]:='{}'; bodies jsonb[]:='{}'; fingerprint text:=''; token text; i int; duplicate_name boolean;
BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION '관리자만 공정코드를 변경할 수 있습니다.';END IF;
 PERFORM pg_advisory_xact_lock(164040,1);
 SELECT * INTO m FROM public.dnm_v4_records WHERE id=p_id AND kind='process_master' FOR UPDATE;
 IF m.id IS NULL OR p_version IS DISTINCT FROM m.version THEN RAISE EXCEPTION '공정 목록을 새로 조회하세요.';END IF;
 nextcode:=CASE WHEN p_delete THEN m.code ELSE public.dnm_v4_required(p_code,'새 공정코드',100) END;
 IF NOT p_delete AND EXISTS(SELECT FROM public.dnm_v4_records WHERE kind='process_master' AND lower(code)=lower(nextcode) AND (id<>p_id OR code=nextcode)) THEN RAISE EXCEPTION '현재 코드와 다르고 중복되지 않는 공정코드를 입력하세요.';END IF;
 SELECT EXISTS(SELECT FROM public.dnm_v4_records WHERE kind=m.kind AND id<>m.id AND title=m.title
 AND coalesce(data->>'kind','WORK')=coalesce(m.data->>'kind','WORK') AND coalesce(data->>'inspection_code','')=coalesce(m.data->>'inspection_code','')) INTO duplicate_name;
 FOR r IN SELECT * FROM public.dnm_v4_records WHERE kind IN('operation','route_candidate','route_template','routing','worklog','material','quality','assignment') ORDER BY id LOOP
  updated:=r.data;
  IF r.kind='worklog' AND nullif(r.data->>'process_master_code','') IS NULL AND EXISTS(
   SELECT FROM public.dnm_v4_records o WHERE o.id=r.parent_id AND o.kind='operation' AND o.data->>'process_master_code'=m.code
  ) THEN updated:=updated||jsonb_build_object('process_master_code',nextcode);
  ELSIF r.data->>'process_master_code'=m.code THEN updated:=jsonb_set(updated,'{process_master_code}',to_jsonb(nextcode));
  ELSIF r.kind IN('operation','worklog') AND nullif(r.data->>'process_master_code','') IS NULL AND dnm_private.process_step_match(r.data||jsonb_build_object('name',r.title),m) THEN
   IF duplicate_name THEN RAISE EXCEPTION '동일 명칭·유형·검사코드가 겹쳐 기존 Routing을 식별할 수 없습니다: %',r.code;END IF;
   updated:=updated||jsonb_build_object('process_master_code',nextcode);
  END IF;
  IF jsonb_typeof(updated->'steps')='array' THEN
   steps:='[]';
   FOR st IN SELECT value FROM jsonb_array_elements(updated->'steps') LOOP
    IF dnm_private.process_step_match(st,m) THEN
     IF duplicate_name AND nullif(st->>'process_master_code','') IS NULL THEN RAISE EXCEPTION '기존 공정안의 코드 연결을 확인하세요: %',r.code;END IF;
     st:=st||jsonb_build_object('process_master_code',nextcode);
     IF p_delete THEN RAISE EXCEPTION '사용 중인 공정안이 있어 삭제할 수 없습니다: %',r.code;END IF;
    END IF;
    steps:=steps||jsonb_build_array(st);
   END LOOP;
   updated:=jsonb_set(updated,'{steps}',steps);
  END IF;
  IF p_delete AND (updated IS DISTINCT FROM r.data OR r.data->>'process_master_code'=m.code OR (r.kind='assignment' AND (r.data->'processes') ? m.title)) THEN RAISE EXCEPTION '사용 중인 공정은 삭제할 수 없습니다: %',r.code;END IF;
  IF updated IS DISTINCT FROM r.data THEN
   ids:=array_append(ids,r.id); bodies:=array_append(bodies,updated);
   counts:=counts||jsonb_build_object(r.kind,coalesce((counts->>r.kind)::int,0)+1);
   fingerprint:=fingerprint||r.id::text||':'||r.version||';';
  END IF;
 END LOOP;
 token:=md5(m.id::text||':'||m.version||':'||nextcode||':'||p_delete::text||':'||fingerprint);
 IF p_token IS NULL THEN RETURN jsonb_build_object('ok',true,'counts',counts,'token',token);END IF;
 IF token<>p_token THEN RAISE EXCEPTION '미리보기 이후 연결 자료가 바뀌었습니다. 다시 확인하세요.';END IF;
 IF p_delete THEN
  INSERT INTO public.dnm_portal_audit(actor_id,entity,record_id,action,old_value) VALUES(auth.uid(),'dnm_v4_records',m.id::text,'DELETE',to_jsonb(m));
  DELETE FROM public.dnm_v4_records WHERE id=m.id;
 ELSE
  UPDATE public.dnm_v4_records SET code=nextcode WHERE id=m.id;
  FOR i IN 1..cardinality(ids) LOOP UPDATE public.dnm_v4_records SET data=bodies[i] WHERE id=ids[i];END LOOP;
 END IF;
 RETURN jsonb_build_object('ok',true,'counts',counts);
END $$;
REVOKE ALL ON FUNCTION dnm_private.buyer_user(),dnm_private.buyer_valid(uuid),dnm_private.reviewed_request(jsonb),dnm_private.price(text),dnm_private.order_terms(jsonb,jsonb),dnm_private.received_total(public.dnm_v4_records),dnm_private.process_step_match(jsonb,public.dnm_v4_records) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.dnm_v492_process(uuid,int,text,text,boolean),public.dnm_v492_review(uuid,int),public.dnm_v492_set_buyer(uuid,uuid),public.dnm_v492_buyer() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dnm_v492_process(uuid,int,text,text,boolean),public.dnm_v492_review(uuid,int),public.dnm_v492_set_buyer(uuid,uuid),public.dnm_v492_buyer() TO authenticated;
-- Convert only an untouched legacy first step, after explicit administrator confirmation.
CREATE OR REPLACE FUNCTION public.dnm_v492_convert_review(p_id uuid,p_version int) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dnm_v4_records; u uuid; approvals jsonb;
BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION '관리자 전용입니다.';END IF;
 PERFORM pg_advisory_xact_lock(164040,1); u:=dnm_private.buyer_user();
 SELECT * INTO r FROM public.dnm_v4_records WHERE id=p_id AND kind='purchase' FOR UPDATE;
 IF r.id IS NULL OR r.version IS DISTINCT FROM p_version OR r.state<>'SUBMITTED' OR r.data ? 'buyer_review' OR
 r.data->>'current_step' IS DISTINCT FROM '0' OR NOT dnm_private.buyer_valid(u) OR
 (r.data->'approvals'->0->>'user_id')::uuid IS DISTINCT FROM u OR jsonb_array_length(r.data->'approvals')<2 OR
 EXISTS(SELECT FROM jsonb_array_elements(r.data->'approvals') a WHERE a->>'state' IS DISTINCT FROM 'WAIT') THEN
 RAISE EXCEPTION '미처리 첫 결재자가 구매담당자이고 후속 결재자가 있는 기존 의뢰만 전환할 수 있습니다.';END IF;
 SELECT jsonb_agg(a||jsonb_build_object('seq',i-2) ORDER BY i) INTO approvals FROM jsonb_array_elements(r.data->'approvals') WITH ORDINALITY t(a,i) WHERE i>1;
 UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('approvals',approvals,'buyer_review',jsonb_build_object('user_id',u,'name',(SELECT display_name FROM public.dnm_portal_profiles WHERE id=u))) WHERE id=r.id;
 RETURN '{"ok":true}';
END $$;
REVOKE ALL ON FUNCTION public.dnm_v492_convert_review(uuid,int) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dnm_v492_convert_review(uuid,int) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
