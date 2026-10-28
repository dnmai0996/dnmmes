-- DISPOSABLE CI DATABASE ONLY. Never execute on an operating company project.
SELECT public.test_assert(has_function_privilege('authenticated','public.dnm_v44_backup_api(text,jsonb)','EXECUTE'),'signed-in backup entrypoint');
SELECT public.test_assert(NOT has_function_privilege('anon','public.dnm_v44_backup_api(text,jsonb)','EXECUTE'),'anonymous backup denied');
SELECT public.test_assert(NOT has_function_privilege('authenticated','public.dnm_v44_restore_apply(uuid,uuid,uuid,text,text)','EXECUTE'),'client cannot commit restore');
SELECT public.test_assert(has_function_privilege('service_role','public.dnm_v44_restore_apply(uuid,uuid,uuid,text,text)','EXECUTE'),'only backend may commit restore');
SELECT public.test_assert(NOT has_schema_privilege('authenticated','dnm_private','USAGE'),'snapshot catalog and security tables private');
BEGIN;
-- Injectable failure is test-only; used to prove partial delete/insert rollback.
CREATE FUNCTION public.v44_test_inject_failure() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN
 IF dnm_private.v44_restoring() AND current_setting('dnm.test_restore_failure',true)='on' THEN RAISE EXCEPTION 'INJECTED_RESTORE_FAILURE';END IF; RETURN NEW;
END $$;
CREATE TRIGGER z_v44_test_failure BEFORE INSERT ON public.dnm_v4_records FOR EACH ROW EXECUTE FUNCTION public.v44_test_inject_failure();
DO $$
DECLARE a uuid:='11111111-1111-4111-8111-111111111111';w uuid:='33333333-3333-4333-8333-333333333333';
 b uuid:=gen_random_uuid();stage uuid:=gen_random_uuid();safe uuid;expjob uuid:=gen_random_uuid();
 sess uuid:=gen_random_uuid();j jsonb;m jsonb;x jsonb;r record;c record;
 original_count bigint;original_title text;baseline_version integer;original_updated timestamptz;original_security jsonb;before_fail_count bigint;cycles int:=0;
 target uuid:=gen_random_uuid();afterrow uuid:=gen_random_uuid();
BEGIN
 PERFORM set_config('request.jwt.claim.sub',a::text,true);
 INSERT INTO auth.sessions(id,user_id,created_at) VALUES(sess,a,clock_timestamp()-interval '1 hour');
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'session_id',sess)::text,true);
 PERFORM public.test_assert(public.dnm_v4_context()->>'backup_management'='4.4.0','context marker');
 INSERT INTO public.dnm_v4_records(id,kind,code,title,state,data,created_by) VALUES(target,'material','BK44-TARGET','백업시점 이름','ACTIVE','{"unit":"EA","active":true}',a);
 INSERT INTO public.dnm_v4_records(kind,code,title,state,data,created_by) SELECT 'material','BK44-PAGE-'||n,'분할시험 '||n,'ACTIVE','{"unit":"EA"}',a FROM generate_series(1,125)n;
 SELECT count(*) INTO original_count FROM public.dnm_v4_records;
 SELECT title,version,updated_at INTO original_title,baseline_version,original_updated FROM public.dnm_v4_records WHERE id=target;
 SELECT to_jsonb(p) INTO original_security FROM public.dnm_portal_profiles p WHERE id=a;
 j:=public.dnm_v44_backup_api('begin',jsonb_build_object('id',b));
 PERFORM public.test_assert(j->>'status'='building','backup starts gated');
 PERFORM public.test_error(format('UPDATE public.dnm_v4_records SET title=''should block'' WHERE id=%L',target),'백업 준비 중');
 PERFORM public.test_error(format('INSERT INTO public.dnm_portal_notes(title,body,owner_id) VALUES(''blocked'',''blocked'',%L)',a),'백업 준비 중');
 WHILE j->>'status'='building' LOOP
  j:=public.dnm_v44_backup_api('step',jsonb_build_object('id',b));cycles:=cycles+1;
  IF cycles>1000 THEN RAISE EXCEPTION 'capture loop';END IF;
 END LOOP;
 m:=j->'manifest';
 PERFORM public.test_assert(j->>'status'='ready' AND jsonb_array_length(m->'collections')=9,'all nine tables captured');
 PERFORM public.test_assert(cycles>9,'large records split over several pages');
 x:=public.dnm_v44_backup_api('read',jsonb_build_object('id',b,'collection','records'));
 PERFORM public.test_assert(jsonb_array_length(x->'rows')<=50,'download bounded page');
 PERFORM public.test_assert(jsonb_typeof(x->'rows'->0->'row_json')='string','numeric precision preserved as row text');
 PERFORM public.test_assert(NOT (public.dnm_v44_backup_api('status','{}')->>'busy')::boolean,'capture releases gate');
 UPDATE public.dnm_v4_records SET title='백업 이후 수정' WHERE id=target;
 INSERT INTO public.dnm_v4_records(id,kind,code,title,state,data,created_by) VALUES(afterrow,'material','BK44-AFTER','잘못된 추가자료','ACTIVE','{}',a);
 PERFORM set_config('request.jwt.claim.sub',w::text,true);
 PERFORM public.test_error('SELECT public.dnm_v44_backup_api(''history'',''{}'')','관리자');
 PERFORM set_config('request.jwt.claim.sub',a::text,true);
 PERFORM public.test_error(format('SELECT public.dnm_v44_backup_api(''stage_begin'',%L::jsonb)',jsonb_build_object('id',stage,'manifest',jsonb_set(m,'{schema_version}','"tampered"'))::text),'같은 회사');
 j:=public.dnm_v44_backup_api('stage_begin',jsonb_build_object('id',stage,'manifest',m));
 -- Stage in pages through the same public function used by the browser.
 FOR c IN SELECT * FROM dnm_private.v44_collections() LOOP
  FOR r IN SELECT (rn-1)/50 AS page,jsonb_agg(jsonb_build_object('key',row_key,'row_json',row_data::text,'sha256',row_hash) ORDER BY row_key) AS rows FROM
   (SELECT row_key,row_data,row_hash,row_number() OVER(ORDER BY row_key)rn FROM dnm_private.v44_items WHERE job_id=b AND collection=c.name)t GROUP BY (rn-1)/50 ORDER BY (rn-1)/50 LOOP
   PERFORM public.dnm_v44_backup_api('stage_rows',jsonb_build_object('id',stage,'collection',c.name,'rows',r.rows));
  END LOOP;
 END LOOP;
 j:=public.dnm_v44_backup_api('stage_verify',jsonb_build_object('id',stage));
 PERFORM public.test_assert(j->>'status'='validated','file digest verified');
 PERFORM public.test_error(format('SELECT public.dnm_v44_restore_apply(%L,%L,%L,''시험 복원'',''백업시점복원'')',a,stage,gen_random_uuid()),'안전백업');
 safe:=gen_random_uuid();j:=public.dnm_v44_backup_api('begin',jsonb_build_object('id',safe,'purpose','safety','safety_for',stage));
 WHILE j->>'status'='building' LOOP j:=public.dnm_v44_backup_api('step',jsonb_build_object('id',safe));END LOOP;
 PERFORM public.test_error(format('SELECT public.dnm_v44_restore_apply(%L,%L,%L,''시험 복원'',''백업시점복원'')',a,stage,safe),'안전백업');
 PERFORM public.dnm_v44_backup_api('ack_file',jsonb_build_object('id',safe,'sha256',repeat('a',64)));
 UPDATE public.dnm_v4_records SET title='안전백업 이후 수정' WHERE id=target;
 PERFORM public.test_error(format('SELECT public.dnm_v44_restore_apply(%L,%L,%L,''시험 복원'',''백업시점복원'')',a,stage,safe),'안전백업 후 자료');
 safe:=gen_random_uuid();j:=public.dnm_v44_backup_api('begin',jsonb_build_object('id',safe,'purpose','safety','safety_for',stage));
 WHILE j->>'status'='building' LOOP j:=public.dnm_v44_backup_api('step',jsonb_build_object('id',safe));END LOOP;
 PERFORM public.dnm_v44_backup_api('ack_file',jsonb_build_object('id',safe,'sha256',repeat('b',64)));
 SELECT count(*) INTO before_fail_count FROM public.dnm_v4_records;
 PERFORM set_config('dnm.test_restore_failure','on',true);
 PERFORM public.test_error(format('SELECT public.dnm_v44_restore_apply(%L,%L,%L,''시험 복원'',''백업시점복원'')',a,stage,safe),'INJECTED_RESTORE_FAILURE');
 PERFORM public.test_assert((SELECT count(*)=before_fail_count FROM public.dnm_v4_records),'failed restore leaves all business rows intact');
 PERFORM public.test_assert((SELECT title='안전백업 이후 수정' FROM public.dnm_v4_records WHERE id=target),'failed restore leaves exact current value');
 PERFORM public.test_assert((SELECT status='validated' FROM dnm_private.v44_jobs WHERE id=stage),'failed restore transaction rolls status back');
 PERFORM set_config('dnm.test_restore_failure','off',true);
 j:=public.dnm_v44_restore_apply(a,stage,safe,'시험 입력자료 되돌리기','백업시점복원');
 PERFORM public.test_assert((j->>'applied')::boolean,'restore committed');
 PERFORM public.test_assert((SELECT count(*)=original_count FROM public.dnm_v4_records),'full business record count at snapshot');
 PERFORM public.test_assert(NOT EXISTS(SELECT FROM public.dnm_v4_records WHERE id=afterrow),'post-snapshot extra business row removed');
 PERFORM public.test_assert((SELECT title=original_title AND version=baseline_version AND updated_at=original_updated FROM public.dnm_v4_records WHERE id=target),'values/version/timestamps restored');
 PERFORM public.test_assert((SELECT email=original_security->>'email' AND role=original_security->>'role' AND active=(original_security->>'active')::boolean FROM public.dnm_portal_profiles WHERE id=a),'current administrator security unchanged');
 PERFORM public.test_assert(EXISTS(SELECT FROM public.dnm_portal_audit WHERE record_id=afterrow::text),'post-snapshot audit retained');
 PERFORM public.test_assert(EXISTS(SELECT FROM dnm_private.v44_events WHERE action='restore_applied' AND job_id=stage),'append-only restore event');
 PERFORM public.test_assert(NOT public.dnm_v43_session_ok(),'old session rejected after restore');
 j:=public.dnm_v44_restore_apply(a,stage,safe,'시험 입력자료 되돌리기','백업시점복원');
 PERFORM public.test_assert((j->>'already_applied')::boolean,'same commit safely idempotent');
 sess:=gen_random_uuid();INSERT INTO auth.sessions(id,user_id,created_at) VALUES(sess,a,clock_timestamp()+interval '1 second');
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'session_id',sess)::text,true);
 PERFORM public.test_assert(public.dnm_v43_session_ok(),'fresh session allowed');
 -- Lease loss cannot result in a valid inconsistent backup.
 j:=public.dnm_v44_backup_api('begin',jsonb_build_object('id',expjob));
 UPDATE dnm_private.v44_gate SET expires_at=clock_timestamp()-interval '1 second' WHERE id;
 UPDATE public.dnm_v4_records SET title='expired lease write allowed' WHERE id=target;
 PERFORM public.test_error(format('SELECT public.dnm_v44_backup_api(''step'',%L::jsonb)',jsonb_build_object('id',expjob)::text),'연결이 오래');
 PERFORM public.dnm_v44_backup_api('cancel',jsonb_build_object('id',expjob));
END $$;
ROLLBACK;
SELECT 'v4.4 synthetic integration completed' AS result;
