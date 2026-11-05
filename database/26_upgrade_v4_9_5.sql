-- DNM MES v4.9.5 | purchase order revisions and receiving remarks
BEGIN;
SELECT pg_advisory_xact_lock(164040,1);
DO $$ BEGIN
 IF to_regprocedure('public.dnm_v494_set_sequence(uuid,integer,boolean)') IS NULL THEN
  RAISE EXCEPTION '4.9.4 업데이트 SQL(25)을 먼저 적용하세요.'; END IF;
END $$;

CREATE OR REPLACE FUNCTION dnm_private.po_remark(d jsonb,idx integer,remark text)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
BEGIN
 IF remark IS NULL OR length(remark)>500 OR idx IS NULL OR idx<0 OR idx>=jsonb_array_length(d->'lines') THEN
  RAISE EXCEPTION '품목과 비고(최대 500자)를 확인하세요.'; END IF;
 RETURN jsonb_build_object('po_line_notes',coalesce(d->'po_line_notes','{}')||jsonb_build_object(idx::text,btrim(remark)));
END $$;

-- Preserve line indexes. Existing receipt and return records refer to those indexes.
CREATE OR REPLACE FUNCTION dnm_private.po_quantities(d jsonb,limits jsonb,quantities jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE line jsonb; lines jsonb:='[]'; n bigint; i int:=0;
BEGIN
 IF jsonb_typeof(quantities) IS DISTINCT FROM 'array' OR jsonb_array_length(quantities)<>jsonb_array_length(d->'lines')
 OR jsonb_array_length(quantities)<>jsonb_array_length(limits) THEN RAISE EXCEPTION '모든 품목의 발주수량을 입력하세요.'; END IF;
 FOR line IN SELECT value FROM jsonb_array_elements(d->'lines') LOOP
  n:=public.dnm_v4_qty(quantities->i,'발주수량');
  IF n>(limits->i->>'qty')::bigint THEN RAISE EXCEPTION '%번 품목은 승인 수량을 초과합니다.',i+1; END IF;
  lines:=lines||jsonb_build_array(line||jsonb_build_object('qty',n)); i:=i+1;
 END LOOP;
 RETURN lines;
END $$;

CREATE OR REPLACE FUNCTION dnm_private.po_original(d jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT coalesce(d->'request_terms',jsonb_build_object('supplier',d->'supplier','lines',d->'lines','subtotal',d->'subtotal','tax',d->'tax','total',d->'total'))
$$;

CREATE OR REPLACE FUNCTION dnm_private.po_issue_terms(d jsonb,p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE original jsonb:=dnm_private.po_original(d); basis jsonb:=d; result jsonb;
BEGIN
 IF EXISTS(SELECT FROM public.dnm_v4_records pr CROSS JOIN LATERAL jsonb_array_elements(pr.data->'po_history') h
 WHERE pr.kind='purchase' AND lower(h->>'number')=lower(btrim(p->>'po_no'))) THEN
  RAISE EXCEPTION '이전에 발행한 발주번호입니다. 새 번호를 입력하세요.'; END IF;
 IF p ? 'quantities' THEN
  basis:=jsonb_set(d,'{lines}',dnm_private.po_quantities(d,original->'lines',p->'quantities'));
 END IF;
 IF NOT EXISTS(SELECT FROM jsonb_array_elements(basis->'lines') l WHERE (l->>'qty')::bigint>0) THEN
  RAISE EXCEPTION '한 품목 이상에 발주수량을 입력하세요.'; END IF;
 result:=dnm_private.order_terms(basis,p);
 RETURN result||jsonb_build_object('request_terms',original,'po_edition',coalesce((d->>'po_edition')::int,0)+1,
 'po_issue_type',CASE WHEN d ? 'po_history' THEN 'reissue' ELSE 'initial' END);
END $$;

CREATE OR REPLACE FUNCTION pg_temp.patch495(f regprocedure,before_text text,after_text text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE src text:=pg_get_functiondef(f);
BEGIN
 IF strpos(src,after_text)>0 THEN RETURN; END IF;
 IF (length(src)-length(replace(src,before_text,'')))/length(before_text)<>1 THEN RAISE EXCEPTION '기존 구매 함수의 버전을 확인하세요. 적용을 중단합니다.'; END IF;
 EXECUTE replace(src,before_text,after_text);
END $$;
SELECT pg_temp.patch495('dnm_private.dnm_v46_purchase_impl(text,jsonb,uuid)',
 'dnm_private.order_terms(old.data,payload)','dnm_private.po_issue_terms(old.data,payload)');
SELECT pg_temp.patch495('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)',
 $o$SET state=s,data=data||jsonb_build_object('received_total',dnm_private.received_total(old))$o$,
 $n$SET state=s,data=data||jsonb_build_object('received_total',dnm_private.received_total(old))||
    CASE WHEN payload ? 'line_remark' THEN dnm_private.po_remark(old.data,idx,payload->>'line_remark') ELSE '{}'::jsonb END$n$);
SELECT pg_temp.patch495('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)',
 $o$IF total+n>(item->>'qty')::numeric THEN RAISE EXCEPTION '누적 합격입고$o$,
 $n$IF total>=(item->>'qty')::numeric THEN RAISE EXCEPTION '이 품목의 발주 잔량이 없습니다.'; END IF;
  IF total+n>(item->>'qty')::numeric THEN RAISE EXCEPTION '누적 합격입고$n$);
-- Versioned entry points avoid silently dropping the new fields if only the web application is deployed.
CREATE OR REPLACE FUNCTION public.dnm_v495_receive(p jsonb,k uuid) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 SELECT public.dnm_v4_command('purchase_receive',p,k)
$$;
CREATE OR REPLACE FUNCTION public.dnm_v495_issue(p jsonb,k uuid) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 SELECT public.dnm_v4_command('purchase_order',p,k)
$$;

CREATE OR REPLACE FUNCTION public.dnm_v495_change_po(act text,p jsonb,k uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); po public.dnm_v4_records; prev public.dnm_v4_requests; h text; result jsonb;
 original jsonb; entry jsonb; lines jsonb; subtotal numeric:=0; tax numeric; line_amount numeric; changed jsonb; state_after text; reason text;
 i int; accepted numeric; complete boolean:=true; any_receipt boolean; edition int;
BEGIN
 PERFORM dnm_private.need('receipts','update'); PERFORM public.dnm_v4_need('purchase');
 IF uid IS NULL OR k IS NULL OR act IS NULL OR act NOT IN('note','revise','cancel') OR p IS NULL OR length(p::text)>16000 THEN
  RAISE EXCEPTION '발주 변경 요청을 확인하세요.'; END IF;
 PERFORM pg_advisory_xact_lock(164040,1); h:=md5('po495'||act||p::text);
 SELECT * INTO prev FROM public.dnm_v4_requests WHERE actor_id=uid AND request_key=k;
 IF FOUND THEN IF prev.payload_hash<>h THEN RAISE EXCEPTION '다른 내용에 사용된 요청번호입니다.'; END IF; RETURN prev.result; END IF;
 SELECT * INTO po FROM public.dnm_v4_records WHERE id=(p->>'id')::uuid AND kind='purchase' FOR UPDATE;
 IF po.id IS NULL OR NOT public.dnm_v4_readable(po.kind,po.data,po.created_by,po.id) OR
 (public.dnm_portal_role()<>'admin' AND public.dnm_v42_scope('receipts')='own' AND NOT dnm_private.own_record(po.kind,po.data,po.created_by,po.id))
 THEN RAISE EXCEPTION '이 발주서의 변경 권한이 없습니다.' USING ERRCODE='42501'; END IF;
 IF po.version IS DISTINCT FROM (p->>'version')::int THEN RAISE EXCEPTION '다른 작업으로 발주서가 변경되었습니다. 상세를 다시 열어 확인하세요.' USING ERRCODE='40001'; END IF;
 IF nullif(po.data->>'po_no','') IS NULL OR po.state NOT IN('ORDERED','PARTIAL','RECEIVED','MATCHED','PAID') THEN RAISE EXCEPTION '발행된 발주서를 선택하세요.'; END IF;
 state_after:=po.state;
 IF act='note' THEN
  changed:=po.data||dnm_private.po_remark(po.data,(p->>'line')::int,p->>'line_remark');
 ELSE
  IF po.state IN('MATCHED','PAID') OR EXISTS(SELECT FROM public.dnm_v4_records WHERE parent_id=po.id AND kind='settlement' AND data->>'entry_type' IS DISTINCT FROM 'payment') THEN
   RAISE EXCEPTION '증빙 대사·정산이 끝난 발주서는 변경할 수 없습니다.'; END IF;
  reason:=public.dnm_v4_required(p->>'reason','변경 사유',500);
  edition:=coalesce((po.data->>'po_edition')::int,1); original:=dnm_private.po_original(po.data);
  SELECT EXISTS(SELECT FROM public.dnm_v4_records WHERE parent_id=po.id AND kind='receipt') INTO any_receipt;
  entry:=jsonb_build_object('number',po.data->>'po_no','edition',edition,'kind',act,'supplier',po.data->>'supplier',
    'issued',po.data->'po_date','due',po.data->'po_delivery_date','terms',po.data->'po_note','total',po.data->'total',
    'lines',po.data->'lines','remarks',po.data->'po_line_notes','reason',reason,'at',now(),'by',uid,
    'by_name',(SELECT display_name FROM public.dnm_portal_profiles WHERE id=uid));
  changed:=po.data||jsonb_build_object('request_terms',original,'po_history',coalesce(po.data->'po_history','[]')||jsonb_build_array(entry));
  IF act='cancel' THEN
   IF any_receipt OR EXISTS(SELECT FROM public.dnm_v4_records WHERE parent_id=po.id AND kind='settlement') THEN
    RAISE EXCEPTION '입고·반품·지급 이력이 있습니다. 수정 발주서에서 잔량을 변경하세요.'; END IF;
   changed:=(changed-ARRAY['po_no','po_date','po_delivery_date','po_note','po_issue_type','ordered_at','ordered_by','received_total','po_line_notes','po_change_reason'])||original||jsonb_build_object('po_edition',edition);
   state_after:='APPROVED';
  ELSE
   lines:=dnm_private.po_quantities(po.data,original->'lines',p->'quantities');
   IF lines=po.data->'lines' THEN RAISE EXCEPTION '변경할 발주수량을 입력하세요.'; END IF;
   FOR i IN 0..jsonb_array_length(lines)-1 LOOP
    SELECT coalesce(sum((data->>'accepted')::numeric),0) INTO accepted FROM public.dnm_v4_records
     WHERE kind='receipt' AND parent_id=po.id AND (data->>'line')::int=i;
    IF (lines->i->>'qty')::numeric<accepted THEN RAISE EXCEPTION '%번 품목의 누적 합격입고 %개 미만으로 줄일 수 없습니다.',i+1,accepted; END IF;
    line_amount:=round((lines->i->>'qty')::numeric*(lines->i->>'unit_price')::numeric,2);
    lines:=jsonb_set(lines,ARRAY[i::text,'amount'],to_jsonb(line_amount)); subtotal:=subtotal+line_amount;
    complete:=complete AND (lines->i->>'qty')::numeric=accepted;
   END LOOP;
   IF complete AND NOT any_receipt THEN RAISE EXCEPTION '전량 취소는 발주 취소를 선택하세요.'; END IF;
   tax:=round(subtotal*coalesce((po.data->>'tax_rate')::numeric,0),2);
   changed:=changed||jsonb_build_object('lines',lines,'subtotal',subtotal,'tax',tax,'total',subtotal+tax,
    'received_total',dnm_private.received_total(po),'po_edition',edition+1,'po_issue_type','revise','po_change_reason',reason,
     'po_date',(now() AT TIME ZONE 'Asia/Seoul')::date,'ordered_by',uid,'ordered_at',now());
   state_after:=CASE WHEN complete THEN 'RECEIVED' WHEN any_receipt THEN 'PARTIAL' ELSE 'ORDERED' END;
  END IF;
 END IF;
 SELECT * INTO po FROM public.dnm_v4_put('purchase',po.code,coalesce(changed->>'supplier',po.title),state_after,po.parent_id,changed,po.id,po.version);
 result:=jsonb_build_object('ok',true,'id',po.id,'version',po.version,'state',po.state);
 INSERT INTO public.dnm_v4_requests(actor_id,request_key,action,payload_hash,result) VALUES(uid,k,'po_'||act,h,result);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION dnm_private.po_remark(jsonb,int,text),dnm_private.po_quantities(jsonb,jsonb,jsonb),dnm_private.po_original(jsonb),dnm_private.po_issue_terms(jsonb,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.dnm_v495_receive(jsonb,uuid),public.dnm_v495_issue(jsonb,uuid),public.dnm_v495_change_po(text,jsonb,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dnm_v495_receive(jsonb,uuid),public.dnm_v495_issue(jsonb,uuid),public.dnm_v495_change_po(text,jsonb,uuid) TO authenticated;
-- Receipts of multiple operators can contribute to the same PO line. Return only the
-- aggregates of an authorized PO, even when its handler has own-scope receipt access.
CREATE OR REPLACE FUNCTION public.dnm_v495_po_status(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE po public.dnm_v4_records; totals jsonb;
BEGIN
 PERFORM dnm_private.need('receipts','read');
 SELECT * INTO po FROM public.dnm_v4_records WHERE id=p_id AND kind='purchase';
 IF po.id IS NULL OR NOT public.dnm_v4_readable(po.kind,po.data,po.created_by,po.id) THEN
  RAISE EXCEPTION '해당 발주서의 조회 권한이 없습니다.' USING ERRCODE='42501'; END IF;
 IF public.dnm_portal_role()<>'admin' AND public.dnm_v42_scope('receipts')='own'
 AND NOT dnm_private.own_record(po.kind,po.data,po.created_by,po.id) THEN
  RETURN '{"ok":true,"visible":false}'; END IF;
 SELECT coalesce(jsonb_object_agg(idx,jsonb_build_array(accepted,rejected)),'{}') INTO totals FROM (
  SELECT data->>'line' idx,sum((data->>'accepted')::numeric) accepted,sum((data->>'rejected')::numeric) rejected
  FROM public.dnm_v4_records WHERE parent_id=po.id AND kind='receipt' GROUP BY data->>'line'
 ) g;
 RETURN jsonb_build_object('ok',true,'visible',true,'version',po.version,'totals',totals,'has_receipts',totals<>'{}'::jsonb,
  'has_settlement',EXISTS(SELECT FROM public.dnm_v4_records WHERE parent_id=po.id AND kind='settlement'));
END $$;
REVOKE ALL ON FUNCTION public.dnm_v495_po_status(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dnm_v495_po_status(uuid) TO authenticated;

NOTIFY pgrst,'reload schema';
COMMIT;
