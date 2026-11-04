-- DNM MES 4.9.4 | Existing 4.9.3 installations. No business records are rewritten.
BEGIN;
SELECT pg_advisory_xact_lock(164040,1);
DO $$ BEGIN
 IF to_regprocedure('public.dnm_v493_field_start(uuid,integer,uuid,uuid)') IS NULL THEN
  RAISE EXCEPTION '4.9.3 업데이트 SQL(24)을 먼저 적용하세요.';END IF;
END $$;

-- Only a policy stored on an operation of a civilian daily sheet can relax the sequence.
CREATE OR REPLACE FUNCTION dnm_private.sequence_blocked(ro public.dnm_v4_records,op public.dnm_v4_records) RETURNS boolean
LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT NOT (coalesce(ro.data->'daily'='true'::jsonb,false) AND coalesce(op.data->'independent'='true'::jsonb,false))
 AND EXISTS(SELECT FROM public.dnm_v4_records p WHERE p.kind='operation' AND p.parent_id=ro.id
 AND (p.data->>'seq')::integer<(op.data->>'seq')::integer AND p.state<>'DONE')
$$;
-- A strict manual entry also respects the actual recorded finish time of previous operations.
CREATE OR REPLACE FUNCTION dnm_private.manual_before_previous(ro public.dnm_v4_records,op public.dnm_v4_records,started timestamptz) RETURNS boolean
LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT NOT (coalesce(ro.data->'daily'='true'::jsonb,false) AND coalesce(op.data->'independent'='true'::jsonb,false))
 AND EXISTS(SELECT FROM public.dnm_v4_records p JOIN public.dnm_v4_records h ON h.parent_id=p.id
 WHERE p.parent_id=ro.id AND p.kind='operation' AND (p.data->>'seq')::int<(op.data->>'seq')::int AND
 ((h.kind='worklog' AND h.state='CONFIRMED' AND (h.data->>'end_at')::timestamptz>started)
 OR (h.kind='material' AND h.data->>'state'='DONE' AND h.created_at>started)))
$$;
CREATE OR REPLACE FUNCTION pg_temp.patch494(fn regprocedure,before_text text,after_text text,expected int DEFAULT 1) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE src text:=pg_get_functiondef(fn);
BEGIN
 IF (length(src)-length(replace(src,after_text,'')))/length(after_text)=expected THEN RETURN;END IF;
 IF (length(src)-length(replace(src,before_text,'')))/length(before_text)<>expected THEN
  RAISE EXCEPTION '설치된 4.9.3 함수(%)가 예상 버전과 다릅니다. 업데이트를 중단합니다.',fn;END IF;
 EXECUTE replace(src,before_text,after_text);
END $$;

SELECT pg_temp.patch494('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)',
 $old$v:=v||plan;$old$,$new$IF item->'independent'='true'::jsonb THEN
    IF plan->>'daily' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION '방산 시트는 공정 순서를 준수해야 합니다.';END IF;
    v:=v||'{"independent":true}'::jsonb;
   END IF;
   v:=v||plan;$new$);
SELECT pg_temp.patch494('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)',
 $old$IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='operation' AND parent_id=old.parent_id AND (data->>'seq')::integer<(old.data->>'seq')::integer AND state<>'DONE') THEN RAISE EXCEPTION '선행 공정$old$,
 $new$IF dnm_private.sequence_blocked(parent,old) THEN RAISE EXCEPTION '선행 공정$new$,2);
SELECT pg_temp.patch494('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)',
 $old$IF p_action='manual_work' THEN
   reason:=$old$,$new$IF p_action='manual_work' THEN
   IF dnm_private.manual_before_previous(parent,old,a) THEN RAISE EXCEPTION '순서 준수 공정은 앞 공정의 실제 완료 시각 이후로 입력하세요.';END IF;
   reason:=$new$);
SELECT pg_temp.patch494('public.dnm_v493_field_choices()',
 $old$NOT EXISTS(SELECT FROM public.dnm_v4_records prior WHERE prior.kind='operation' AND prior.parent_id=r.id AND (prior.data->>'seq')::int<(op.data->>'seq')::int AND prior.state<>'DONE')$old$,
 $new$NOT dnm_private.sequence_blocked(r,op)$new$);
SELECT pg_temp.patch494('public.dnm_v493_field_choices()',$old$'remaining',(op.data->>'qty')$old$,$new$'independent',op.data->'independent','remaining',(op.data->>'qty')$new$);
-- The same eligibility is used by the workshop UI, including when a worker cannot see a predecessor.
CREATE OR REPLACE FUNCTION public.dnm_v494_blocked(p_ids uuid[]) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('ok',true,'ids',coalesce(jsonb_agg(op.id),'[]'::jsonb)) FROM public.dnm_v4_records op
 JOIN public.dnm_v4_records ro ON ro.id=op.parent_id AND ro.kind='routing' AND ro.state='RELEASED'
 WHERE op.id=ANY(p_ids) AND op.kind='operation'
 AND public.dnm_v4_readable(op.kind,op.data,op.created_by,op.id) AND dnm_private.sequence_blocked(ro,op)
$$;
CREATE OR REPLACE FUNCTION public.dnm_v494_daily_save(p jsonb,k uuid) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$SELECT public.dnm_v493_daily_save(p,k)$$;
CREATE OR REPLACE FUNCTION public.dnm_v494_set_sequence(p_id uuid,p_version integer,p_independent boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE op public.dnm_v4_records; ro public.dnm_v4_records;
BEGIN
 PERFORM dnm_private.need('routing','update');PERFORM pg_advisory_xact_lock(164040,1);
 SELECT * INTO op FROM public.dnm_v4_records WHERE id=p_id AND kind='operation' FOR UPDATE;
 SELECT * INTO ro FROM public.dnm_v4_records WHERE id=op.parent_id AND kind='routing';
 IF ro.data->>'daily' IS DISTINCT FROM 'true' OR ro.state NOT IN('DRAFT','RELEASED') OR
  (public.dnm_portal_role()<>'admin' AND ro.data->>'manager_id' IS DISTINCT FROM auth.uid()::text) THEN
  RAISE EXCEPTION '담당자가 진행 중인 민수 시트에서 설정할 수 있습니다.';END IF;
 IF op.version=p_version+1 AND op.data->'independent'=to_jsonb(p_independent) AND op.data->>'sequence_set_by'=auth.uid()::text AND op.data->>'sequence_from_version'=p_version::text THEN
  RETURN '{"ok":true}';END IF;
 IF p_independent IS NULL OR op.version IS DISTINCT FROM p_version OR op.state NOT IN('DRAFT','WAIT') OR
  EXISTS(SELECT FROM public.dnm_v4_records WHERE parent_id=op.id) OR
  EXISTS(SELECT FROM public.dnm_v4_records WHERE kind='quality' AND data->>'operation_id'=op.id::text) THEN
  RAISE EXCEPTION '시트를 다시 조회하세요. 이미 작업·검사 기록이 있는 공정은 바꿀 수 없습니다.';END IF;
 UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('independent',p_independent,'sequence_set_by',auth.uid(),'sequence_from_version',p_version,'sequence_set_at',now()) WHERE id=op.id;
 RETURN '{"ok":true}';
END $$;
-- Field-selected work records keep the same equipment/worker validation for live and retrospective entries.
SELECT pg_temp.patch494('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)',
 $old$OR old.state<>'WAIT' OR p_action<>'start_work') THEN RAISE EXCEPTION '민수 현장 작업 시작에서 실제 설비를 선택하세요.';$old$,
 $new$OR old.state<>'WAIT') THEN RAISE EXCEPTION '민수 현장 작업 시작 또는 수기 작업일보에서 실제 설비를 선택하세요.';$new$);
CREATE OR REPLACE FUNCTION dnm_private.v494_field_record(p_id uuid,p_version integer,p_equipment uuid,k uuid,p_log jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE op public.dnm_v4_records; r public.dnm_v4_records; e public.dnm_v4_records; prev public.dnm_v4_requests; h text;
 result jsonb; payload jsonb; action_name text:='start_work'; request_name text:='field_start';
BEGIN
 PERFORM pg_advisory_xact_lock(164040,1);e:=dnm_private.field_worker();
 IF k IS NULL OR p_id IS NULL OR p_version IS NULL OR p_equipment IS NULL THEN RAISE EXCEPTION '일일 공정과 실제 설비를 선택하세요.';END IF;
 IF p_log IS NULL THEN
  h:=md5(jsonb_build_array(request_name,p_id,p_version,p_equipment)::text);
  payload:=jsonb_build_object('work_date',(now() AT TIME ZONE 'Asia/Seoul')::date);
 ELSE
  action_name:='manual_work';request_name:='field_manual';
  IF jsonb_typeof(p_log)<>'object' OR length(p_log::text)>5000 OR nullif(p_log->>'start_at','') IS NULL OR nullif(p_log->>'end_at','') IS NULL THEN RAISE EXCEPTION '실제 작업 시작·종료 시각을 입력하세요.';END IF;
  payload:=jsonb_build_object('start_at',p_log->>'start_at','end_at',p_log->>'end_at','work_date',p_log->>'work_date','total',p_log->'total','defect',p_log->'defect','reason',p_log->>'reason','note',p_log->>'note','input_mode','manual');
  h:=md5(jsonb_build_array(request_name,p_id,p_version,p_equipment,payload)::text);
 END IF;
 SELECT * INTO prev FROM public.dnm_v4_requests WHERE actor_id=auth.uid() AND request_key=k;
 IF FOUND THEN IF prev.payload_hash<>h THEN RAISE EXCEPTION '요청번호가 이미 사용되었습니다.';END IF;RETURN prev.result;END IF;
 SELECT * INTO op FROM public.dnm_v4_records WHERE id=p_id AND kind='operation' FOR UPDATE;
 SELECT * INTO r FROM public.dnm_v4_records WHERE id=op.parent_id AND kind='routing';
 IF r.data->>'daily' IS DISTINCT FROM 'true' OR r.data->>'field_direct' IS DISTINCT FROM 'true' OR r.state<>'RELEASED' OR
  op.data->>'kind' IS DISTINCT FROM 'WORK' OR op.state<>'WAIT' OR op.version IS DISTINCT FROM p_version THEN RAISE EXCEPTION '시작할 수 있는 민수 공정을 다시 선택하세요.';END IF;
 UPDATE public.dnm_v4_records SET data=data||public.dnm_v45_team(op.title,p_equipment,jsonb_build_array(e.id),(r.data->>'manager_id')::uuid)
 WHERE id=op.id RETURNING * INTO op;
 result:=public.dnm_v4_command(action_name,payload||jsonb_build_object('id',op.id,'version',op.version,'employee_id',e.id,'field_equipment',p_equipment),k);
 UPDATE public.dnm_v4_requests SET action=request_name,payload_hash=h WHERE actor_id=auth.uid() AND request_key=k;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v493_field_start(p_id uuid,p_version integer,p_equipment uuid,k uuid) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$SELECT dnm_private.v494_field_record(p_id,p_version,p_equipment,k,NULL)$$;
CREATE OR REPLACE FUNCTION public.dnm_v494_field_manual(p_id uuid,p_version integer,p_equipment uuid,k uuid,p_log jsonb) RETURNS jsonb
LANGUAGE sql STRICT SECURITY DEFINER SET search_path='' AS $$SELECT dnm_private.v494_field_record(p_id,p_version,p_equipment,k,p_log)$$;
REVOKE ALL ON FUNCTION dnm_private.v494_field_record(uuid,int,uuid,uuid,jsonb),dnm_private.sequence_blocked(public.dnm_v4_records,public.dnm_v4_records),dnm_private.manual_before_previous(public.dnm_v4_records,public.dnm_v4_records,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.dnm_v494_daily_save(jsonb,uuid),public.dnm_v494_blocked(uuid[]),public.dnm_v494_set_sequence(uuid,int,boolean),public.dnm_v494_field_manual(uuid,int,uuid,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dnm_v494_daily_save(jsonb,uuid),public.dnm_v494_blocked(uuid[]),public.dnm_v494_set_sequence(uuid,int,boolean),public.dnm_v494_field_manual(uuid,int,uuid,uuid,jsonb) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
