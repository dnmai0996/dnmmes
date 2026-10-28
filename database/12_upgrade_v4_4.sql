-- DNM MES 4.4.0: consistent, paged business backups and guarded point restore.
-- Apply once AFTER 10_upgrade_v4_3.sql. Additive migration: does not restore/delete live data.
-- Scope: ALL DNM business tables. Auth credentials/security controls and external files are NOT rolled back.
BEGIN;
DO $$ BEGIN
 IF to_regprocedure('public.dnm_v43_accounts()') IS NULL THEN RAISE EXCEPTION '먼저 사용자 관리 업데이트(10)를 적용하세요.';END IF;
END $$;
CREATE TABLE IF NOT EXISTS dnm_private.v44_gate (
 id boolean PRIMARY KEY DEFAULT true CHECK(id),instance_id uuid NOT NULL DEFAULT gen_random_uuid(),
 revision bigint NOT NULL DEFAULT 0,job_id uuid,expires_at timestamptz,session_cutoff timestamptz,
 restore_xid bigint
);
INSERT INTO dnm_private.v44_gate(id) VALUES(true) ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS dnm_private.v44_jobs (
 id uuid PRIMARY KEY,actor_id uuid NOT NULL,job_type text NOT NULL CHECK(job_type IN('backup','restore')),
 purpose text NOT NULL DEFAULT 'normal',source_id uuid,safety_for uuid,
 status text NOT NULL CHECK(status IN('building','ready','staging','validated','applying','applied','cancelled','failed')),
 snapshot_at timestamptz NOT NULL DEFAULT clock_timestamp(),revision bigint NOT NULL DEFAULT 0,
 progress jsonb NOT NULL DEFAULT '{}'::jsonb,manifest jsonb,ack_at timestamptz,file_hash text,
 applied_at timestamptz,reason text NOT NULL DEFAULT '',created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS dnm_private.v44_items (
 job_id uuid NOT NULL REFERENCES dnm_private.v44_jobs(id) ON DELETE CASCADE,
 collection text NOT NULL,row_key text COLLATE "C" NOT NULL,row_data jsonb NOT NULL,row_hash text NOT NULL,
 PRIMARY KEY(job_id,collection,row_key)
);
CREATE TABLE IF NOT EXISTS dnm_private.v44_events (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,actor_id uuid,action text NOT NULL,
 job_id uuid,source_id uuid,safety_id uuid,details jsonb NOT NULL DEFAULT '{}',created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
REVOKE ALL ON ALL TABLES IN SCHEMA dnm_private FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION dnm_private.v44_collections() RETURNS TABLE(name text,rel text,key_sql text,pk text[],restore_mode text)
LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 VALUES
 ('profiles','dnm_portal_profiles','id::text',ARRAY['id'],'security_preserved'),
 ('products','dnm_portal_products','id::text',ARRAY['id'],'replace'),
 ('partners','dnm_portal_partners','id::text',ARRAY['id'],'replace'),
 ('notes','dnm_portal_notes','id::text',ARRAY['id'],'replace'),
 ('records','dnm_v4_records','id::text',ARRAY['id'],'replace'),
 ('permissions','dnm_v4_permissions','profile_id::text',ARRAY['profile_id'],'replace'),
 ('module_access','dnm_v42_module_access',$q$profile_id::text||'|'||module$q$,ARRAY['profile_id','module'],'replace'),
 ('requests','dnm_v4_requests',$q$actor_id::text||'|'||request_key::text$q$,ARRAY['actor_id','request_key'],'replace'),
 ('audit','dnm_portal_audit',$q$lpad(id::text,20,'0')$q$,ARRAY['id'],'append_only');
$$;
CREATE OR REPLACE FUNCTION dnm_private.v44_hash(v text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT encode(sha256(convert_to(v,'UTF8')),'hex');
$$;
CREATE OR REPLACE FUNCTION dnm_private.v44_restoring() RETURNS boolean LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce((SELECT restore_xid=txid_current() FROM dnm_private.v44_gate WHERE id),false);
$$;
CREATE OR REPLACE FUNCTION dnm_private.v44_writable() RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path='' AS $$
DECLARE g dnm_private.v44_gate;BEGIN
 IF dnm_private.v44_restoring() THEN RETURN;END IF;
 PERFORM pg_advisory_xact_lock_shared(164044,1);
 SELECT * INTO g FROM dnm_private.v44_gate WHERE id;
 IF g.job_id IS NOT NULL AND g.expires_at>clock_timestamp() THEN
  RAISE EXCEPTION '백업 준비 중에는 등록·수정을 잠시 멈춥니다. 잠시 후 다시 저장하세요.' USING ERRCODE='P0001';
 END IF;
END $$;
CREATE OR REPLACE FUNCTION dnm_private.v44_write_guard() RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF dnm_private.v44_restoring() THEN RETURN NULL;END IF;
 PERFORM dnm_private.v44_writable();
 UPDATE dnm_private.v44_gate SET revision=revision+1 WHERE id;
 RETURN NULL;
END $$;
-- A statement-level guard covers direct REST writes, old RPCs and account-management writes.
DO $$ DECLARE c record;r text;BEGIN
 FOR c IN SELECT * FROM dnm_private.v44_collections() LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS dnm_v44_write_guard ON public.%I',c.rel);
  EXECUTE format('CREATE TRIGGER dnm_v44_write_guard BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION dnm_private.v44_write_guard()',c.rel);
  EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON public.%I ((%s) COLLATE "C")','v44_bk_'||c.name,c.rel,c.key_sql);
 END LOOP;
 FOREACH r IN ARRAY ARRAY['login_controls','login_jobs','login_tickets'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS dnm_v44_write_guard ON dnm_private.%I',r);
  EXECUTE format('CREATE TRIGGER dnm_v44_write_guard BEFORE INSERT OR UPDATE OR DELETE ON dnm_private.%I FOR EACH STATEMENT EXECUTE FUNCTION dnm_private.v44_write_guard()',r);
 END LOOP;
END $$;
-- Preserve exact business timestamps/versions while an authorized restore transaction is active.
CREATE OR REPLACE FUNCTION public.dnm_portal_touch() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF NOT dnm_private.v44_restoring() THEN NEW.updated_at:=now();NEW.version:=OLD.version+1;END IF;RETURN NEW;END $$;
CREATE OR REPLACE FUNCTION public.dnm_portal_record_change() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF dnm_private.v44_restoring() THEN RETURN NEW;END IF;
 INSERT INTO public.dnm_portal_audit(actor_id,entity,record_id,action,old_value,new_value)
 VALUES(auth.uid(),TG_TABLE_NAME,NEW.id::text,TG_OP,CASE WHEN TG_OP='UPDATE' THEN to_jsonb(OLD) ELSE NULL END,to_jsonb(NEW));RETURN NEW;
END $$;
-- Only defer named DNM references. No general trigger/RLS disabling.
DO $$ DECLARE r record;BEGIN
 FOR r IN SELECT conname,conrelid::regclass AS tbl FROM pg_constraint WHERE contype='f'
 AND (conrelid='public.dnm_v4_records'::regclass OR conrelid='dnm_private.login_controls'::regclass OR conrelid='dnm_private.login_jobs'::regclass)
 AND confrelid='public.dnm_v4_records'::regclass LOOP
  EXECUTE format('ALTER TABLE %s ALTER CONSTRAINT %I DEFERRABLE INITIALLY DEFERRED',r.tbl,r.conname);
 END LOOP;
END $$;
ALTER TABLE dnm_private.login_jobs ALTER COLUMN employee_id DROP NOT NULL;
-- New logins required after a successful restore, including legacy unmanaged accounts.
DO $$ BEGIN
 IF to_regprocedure('dnm_private.v43_session_before_v44()') IS NULL THEN
  ALTER FUNCTION public.dnm_v43_session_ok() RENAME TO v43_session_before_v44;
  ALTER FUNCTION public.v43_session_before_v44() SET SCHEMA dnm_private;
 END IF;
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v43_session_ok() RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE cutoff timestamptz;sid text;BEGIN
 IF NOT dnm_private.v43_session_before_v44() THEN RETURN false;END IF;
 SELECT session_cutoff INTO cutoff FROM dnm_private.v44_gate WHERE id;
 IF cutoff IS NULL THEN RETURN true;END IF;
 sid:=auth.jwt()->>'session_id';IF sid IS NULL OR sid!~*'^[a-f0-9-]{36}$' THEN RETURN false;END IF;
 RETURN EXISTS(SELECT 1 FROM auth.sessions WHERE id=sid::uuid AND user_id=auth.uid() AND created_at>=cutoff);
END $$;
DO $$ DECLARE c record;BEGIN
 FOR c IN SELECT * FROM dnm_private.v44_collections() LOOP
  EXECUTE format('DROP POLICY IF EXISTS dnm_v43_session_gate ON public.%I',c.rel);
  EXECUTE format('CREATE POLICY dnm_v43_session_gate ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING (public.dnm_v43_session_ok()) WITH CHECK (public.dnm_v43_session_ok())',c.rel);
 END LOOP;
END $$;
DO $$ BEGIN
 IF to_regprocedure('dnm_private.v43_service_before_v44(text,jsonb)') IS NULL THEN
  ALTER FUNCTION public.dnm_v43_service(text,jsonb) RENAME TO v43_service_before_v44;
  ALTER FUNCTION public.v43_service_before_v44(text,jsonb) SET SCHEMA dnm_private;
 END IF;
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v43_service(p_action text,p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF p_action NOT IN('health','rate','probe','clear_rate') THEN PERFORM dnm_private.v44_writable();END IF;
 RETURN dnm_private.v43_service_before_v44(p_action,p);
END $$;
REVOKE ALL ON FUNCTION public.dnm_v43_service(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v43_service(text,jsonb) TO service_role;
CREATE OR REPLACE FUNCTION dnm_private.v44_summary(j uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('id',id,'status',status,'purpose',purpose,'snapshot_at',snapshot_at,'progress',progress,'manifest',manifest,'safety_for',safety_for,'applied_at',applied_at)
 FROM dnm_private.v44_jobs WHERE id=j;
$$;
CREATE OR REPLACE FUNCTION public.dnm_v44_backup_api(p_action text,p jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path='' SET lock_timeout='4s' SET statement_timeout='18s' AS $$
DECLARE j dnm_private.v44_jobs;src dnm_private.v44_jobs;g dnm_private.v44_gate;c record;r record;it jsonb;
 jid uuid;source uuid;cnt bigint;n integer;lastkey text;prog jsonb;arr jsonb:='[]';digest text;rowhash text;k text;rows jsonb;rd jsonb;expected jsonb;col text;now_at timestamptz:=clock_timestamp();
BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION '관리자만 백업·복원을 실행할 수 있습니다.' USING ERRCODE='42501';END IF;
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION '입력 형식을 확인하세요.';END IF;
 IF p_action='status' THEN
  SELECT * INTO g FROM dnm_private.v44_gate WHERE id;
  RETURN jsonb_build_object('ok',true,'version','4.4.0','instance_id',g.instance_id,'busy',g.job_id IS NOT NULL AND g.expires_at>now_at,'job_id',CASE WHEN g.expires_at>now_at THEN g.job_id ELSE NULL END);
 END IF;
 IF p_action='history' THEN
  RETURN jsonb_build_object('ok',true,'items',coalesce((SELECT jsonb_agg(x ORDER BY x.snapshot_at DESC) FROM(
    SELECT id,job_type,status,purpose,snapshot_at,source_id,safety_for,applied_at,ack_at,manifest->'collections' AS collections
    FROM dnm_private.v44_jobs WHERE status IN('ready','applied') ORDER BY snapshot_at DESC LIMIT 100 OFFSET least(greatest(coalesce((p->>'offset')::integer,0),0),100000)
  )x),'[]'::jsonb));
 END IF;
 jid:=(p->>'id')::uuid;IF jid IS NULL THEN RAISE EXCEPTION '작업번호가 없습니다.';END IF;
 IF p_action='begin' THEN
  PERFORM pg_advisory_xact_lock(164044,1);
  SELECT * INTO j FROM dnm_private.v44_jobs WHERE id=jid;
  IF FOUND THEN
   IF j.actor_id<>auth.uid() OR j.job_type<>'backup' THEN RAISE EXCEPTION '작업번호를 확인하세요.';END IF;
   RETURN dnm_private.v44_summary(jid);
  END IF;
  SELECT * INTO g FROM dnm_private.v44_gate WHERE id FOR UPDATE;
  IF g.job_id IS NOT NULL AND g.expires_at>now_at THEN RAISE EXCEPTION '다른 백업이 준비 중입니다. 완료 후 다시 실행하세요.';END IF;
  IF EXISTS(SELECT 1 FROM dnm_private.login_jobs WHERE phase='prepared') OR EXISTS(SELECT 1 FROM dnm_private.login_controls WHERE state='changing') THEN
   RAISE EXCEPTION '처리 중인 사용자 등록·비밀번호 변경을 먼저 완료하거나 확인하세요.';
  END IF;
  IF p->>'purpose'='safety' THEN
   IF NOT EXISTS(SELECT 1 FROM dnm_private.v44_jobs WHERE id=(p->>'safety_for')::uuid AND status='validated' AND job_type='restore' AND actor_id=auth.uid()) THEN RAISE EXCEPTION '먼저 복원할 파일을 검사하세요.';END IF;
  END IF;
  now_at:=clock_timestamp();
  IF g.job_id IS NOT NULL THEN UPDATE dnm_private.v44_jobs SET status='failed' WHERE id=g.job_id AND status='building';END IF;
  prog:='{}';
  FOR c IN SELECT * FROM dnm_private.v44_collections() LOOP
   EXECUTE format('SELECT count(*) FROM public.%I',c.rel) INTO cnt;
   prog:=prog||jsonb_build_object(c.name,jsonb_build_object('count',0,'total',cnt,'last','','done',false));
  END LOOP;
  INSERT INTO dnm_private.v44_jobs(id,actor_id,job_type,purpose,safety_for,status,snapshot_at,revision,progress)
  VALUES(jid,auth.uid(),'backup',CASE WHEN p->>'purpose'='safety' THEN 'safety' ELSE 'normal' END,(p->>'safety_for')::uuid,'building',now_at,g.revision,prog);
  UPDATE dnm_private.v44_gate SET job_id=jid,expires_at=now_at+interval '3 minutes' WHERE id;
  INSERT INTO dnm_private.v44_events(actor_id,action,job_id) VALUES(auth.uid(),'backup_begin',jid);
  RETURN dnm_private.v44_summary(jid);
 END IF;
 SELECT * INTO j FROM dnm_private.v44_jobs WHERE id=jid;
 IF p_action='stage_begin' THEN
  source:=(p->'manifest'->>'backup_id')::uuid;
  SELECT * INTO src FROM dnm_private.v44_jobs WHERE id=source AND job_type='backup' AND status='ready';
  IF NOT FOUND OR src.manifest IS DISTINCT FROM p->'manifest' THEN RAISE EXCEPTION '이 프로그램에서 만든 같은 회사의 완료 백업만 복원할 수 있습니다. 기존 JSON 내보내기는 지원하지 않습니다.';END IF;
  IF j.id IS NOT NULL THEN
   IF j.actor_id<>auth.uid() OR j.job_type<>'restore' OR j.source_id<>source THEN RAISE EXCEPTION '복원 작업번호가 다릅니다.';END IF;
   RETURN dnm_private.v44_summary(jid);
  END IF;
  INSERT INTO dnm_private.v44_jobs(id,actor_id,job_type,source_id,status,manifest) VALUES(jid,auth.uid(),'restore',source,'staging',src.manifest);
  RETURN dnm_private.v44_summary(jid);
 END IF;
 IF j.id IS NULL THEN RAISE EXCEPTION '백업 작업을 찾을 수 없습니다.';END IF;
 IF p_action='read' THEN
  IF j.job_type<>'backup' OR j.status<>'ready' THEN RAISE EXCEPTION '완료된 백업만 내려받을 수 있습니다.';END IF;
  col:=p->>'collection';IF NOT EXISTS(SELECT FROM dnm_private.v44_collections() WHERE name=col) THEN RAISE EXCEPTION '백업 자료 구분이 다릅니다.';END IF;
  WITH candidates AS (SELECT row_key,row_data,row_hash,row_number() OVER(ORDER BY row_key) AS rn,
   sum(octet_length(row_data::text)+200) OVER(ORDER BY row_key) AS bytes
   FROM (SELECT row_key,row_data,row_hash FROM dnm_private.v44_items WHERE job_id=jid AND collection=col AND row_key>coalesce(p->>'after','') COLLATE "C" ORDER BY row_key LIMIT 50) a)
  SELECT coalesce(jsonb_agg(jsonb_build_object('key',row_key,'row_json',row_data::text,'sha256',row_hash) ORDER BY row_key),'[]'::jsonb) INTO rows FROM candidates WHERE bytes<=1500000 OR rn=1;
  RETURN jsonb_build_object('rows',rows,'manifest',CASE WHEN coalesce(p->>'after','')='' THEN j.manifest ELSE NULL END);
 END IF;
 IF p_action='inspect' THEN RETURN dnm_private.v44_summary(jid);END IF;
 IF j.actor_id<>auth.uid() THEN RAISE EXCEPTION '진행 중인 작업은 시작한 관리자가 완료하세요.' USING ERRCODE='42501';END IF;
 IF p_action='cancel' THEN
  PERFORM pg_advisory_xact_lock(164044,1);
  IF j.status NOT IN('building','staging','validated') THEN RAISE EXCEPTION '완료된 작업은 취소하지 않습니다.';END IF;
  UPDATE dnm_private.v44_jobs SET status='cancelled' WHERE id=jid;
  UPDATE dnm_private.v44_gate SET job_id=NULL,expires_at=NULL WHERE id AND job_id=jid;
  INSERT INTO dnm_private.v44_events(actor_id,action,job_id) VALUES(auth.uid(),'cancel',jid);
  RETURN jsonb_build_object('ok',true);
 END IF;
 IF p_action='step' THEN
  PERFORM pg_advisory_xact_lock(164044,1);
  SELECT * INTO j FROM dnm_private.v44_jobs WHERE id=jid FOR UPDATE;
  IF j.status='ready' THEN RETURN dnm_private.v44_summary(jid);END IF;
  SELECT * INTO g FROM dnm_private.v44_gate WHERE id FOR UPDATE;
  IF j.status<>'building' OR g.job_id IS DISTINCT FROM jid OR g.expires_at<=clock_timestamp() OR g.revision<>j.revision THEN RAISE EXCEPTION '백업 연결이 오래 중단되었습니다. 이전 작업을 취소하고 새 백업을 시작하세요.';END IF;
  SELECT * INTO c FROM dnm_private.v44_collections() WHERE NOT coalesce((j.progress->name->>'done')::boolean,false) LIMIT 1;
  IF FOUND THEN
   col:=c.name;lastkey:=j.progress->col->>'last';n:=0;
   FOR r IN EXECUTE format('SELECT (%s)::text AS k,to_jsonb(t) AS d FROM public.%I t WHERE (%s) COLLATE "C">$1 COLLATE "C" ORDER BY (%s) COLLATE "C" LIMIT 50',c.key_sql,c.rel,c.key_sql,c.key_sql) USING lastkey LOOP
    INSERT INTO dnm_private.v44_items(job_id,collection,row_key,row_data,row_hash) VALUES(jid,col,r.k,r.d,dnm_private.v44_hash(r.d::text));
    lastkey:=r.k;n:=n+1;
   END LOOP;
   prog:=jsonb_build_object('count',(j.progress->col->>'count')::bigint+n,'total',(j.progress->col->>'total')::bigint,'last',lastkey,'done',n<50);
   UPDATE dnm_private.v44_jobs SET progress=jsonb_set(progress,ARRAY[col],prog) WHERE id=jid RETURNING * INTO j;
  END IF;
  UPDATE dnm_private.v44_gate SET expires_at=clock_timestamp()+interval '3 minutes' WHERE id;
  IF NOT EXISTS(SELECT FROM dnm_private.v44_collections() WHERE NOT coalesce((j.progress->name->>'done')::boolean,false)) THEN
   FOR c IN SELECT * FROM dnm_private.v44_collections() LOOP
    SELECT count(*),dnm_private.v44_hash(coalesce(string_agg(row_key||':'||row_hash,E'\n' ORDER BY row_key COLLATE "C"),'')) INTO cnt,digest FROM dnm_private.v44_items WHERE job_id=jid AND collection=c.name;
    IF cnt<>(j.progress->c.name->>'total')::bigint THEN RAISE EXCEPTION '백업 건수가 일치하지 않습니다. 중단 후 다시 실행하세요.';END IF;
    arr:=arr||jsonb_build_array(jsonb_build_object('name',c.name,'count',cnt,'sha256',digest,'restore_mode',c.restore_mode));
   END LOOP;
   expected:=jsonb_build_object('format','dnm-business-snapshot-v44','schema_version','4.4.0','backup_id',jid,'instance_id',g.instance_id,
    'captured_at',j.snapshot_at,'collections',arr,'scope','all_dnm_business_tables',
    'preserved_on_restore',jsonb_build_array('auth_passwords_sessions','profile_email_role_active','security_controls','audit_events'),
    'excluded',jsonb_build_array('external_file_bytes','storage_objects','program_code','platform_settings'));
   UPDATE dnm_private.v44_jobs SET status='ready',manifest=expected WHERE id=jid;
   UPDATE dnm_private.v44_gate SET job_id=NULL,expires_at=NULL WHERE id AND job_id=jid;
   INSERT INTO dnm_private.v44_events(actor_id,action,job_id) VALUES(auth.uid(),'backup_ready',jid);
  END IF;
  RETURN dnm_private.v44_summary(jid);
 END IF;
 IF p_action='ack_file' THEN
  IF j.status<>'ready' OR coalesce(p->>'sha256','')!~'^[a-f0-9]{64}$' THEN RAISE EXCEPTION '내려받은 백업 파일을 다시 선택하여 검사하세요.';END IF;
  UPDATE dnm_private.v44_jobs SET ack_at=clock_timestamp(),file_hash=p->>'sha256' WHERE id=jid;
  RETURN jsonb_build_object('ok',true);
 END IF;
 IF p_action='stage_rows' THEN
  PERFORM pg_advisory_xact_lock(164044,2);
  SELECT * INTO j FROM dnm_private.v44_jobs WHERE id=jid FOR UPDATE;
  IF j.job_type<>'restore' OR j.status<>'staging' THEN RAISE EXCEPTION '복원 파일 검사 단계를 다시 시작하세요.';END IF;
  col:=p->>'collection';SELECT * INTO c FROM dnm_private.v44_collections() WHERE name=col;
  IF NOT FOUND OR jsonb_typeof(p->'rows') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'rows')>50 OR octet_length((p->'rows')::text)>5500000 THEN RAISE EXCEPTION '파일 분할 자료 형식·크기를 확인하세요.';END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(p->'rows') LOOP
   rd:=(it->>'row_json')::jsonb;IF jsonb_typeof(rd) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION '자료 형식이 잘못되었습니다.';END IF;
   IF EXISTS(SELECT FROM jsonb_object_keys(rd) f WHERE NOT EXISTS(SELECT FROM pg_attribute a WHERE a.attrelid=('public.'||c.rel)::regclass AND a.attnum>0 AND NOT a.attisdropped AND a.attname=f)) THEN RAISE EXCEPTION '현재 프로그램과 다른 항목이 들어 있습니다.';END IF;
   EXECUTE format('SELECT (%s)::text FROM jsonb_populate_record(NULL::public.%I,$1)',c.key_sql,c.rel) INTO k USING rd;
   rowhash:=dnm_private.v44_hash(rd::text);
   IF k IS NULL OR k IS DISTINCT FROM it->>'key' OR rowhash IS DISTINCT FROM it->>'sha256' THEN RAISE EXCEPTION '백업 내용이 손상되었거나 변경되었습니다.';END IF;
   IF EXISTS(SELECT FROM dnm_private.v44_items WHERE job_id=jid AND collection=col AND row_key=k AND row_hash<>rowhash) THEN RAISE EXCEPTION '같은 번호의 내용이 서로 다릅니다.';END IF;
   INSERT INTO dnm_private.v44_items(job_id,collection,row_key,row_data,row_hash) VALUES(jid,col,k,rd,rowhash) ON CONFLICT DO NOTHING;
  END LOOP;
  SELECT count(*) INTO cnt FROM dnm_private.v44_items WHERE job_id=jid AND collection=col;
  SELECT x INTO expected FROM jsonb_array_elements(j.manifest->'collections') x WHERE x->>'name'=col;
  IF cnt>(expected->>'count')::bigint THEN RAISE EXCEPTION '백업 행 수를 초과했습니다.';END IF;
  RETURN jsonb_build_object('ok',true,'count',cnt);
 END IF;
 IF p_action='stage_verify' THEN
  PERFORM pg_advisory_xact_lock(164044,2);
  SELECT * INTO j FROM dnm_private.v44_jobs WHERE id=jid FOR UPDATE;
  IF j.job_type<>'restore' OR j.status NOT IN('staging','validated') THEN RAISE EXCEPTION '복원 파일 상태를 확인하세요.';END IF;
  FOR c IN SELECT * FROM dnm_private.v44_collections() LOOP
   SELECT x INTO expected FROM jsonb_array_elements(j.manifest->'collections') x WHERE x->>'name'=c.name;
   SELECT count(*),dnm_private.v44_hash(coalesce(string_agg(row_key||':'||row_hash,E'\n' ORDER BY row_key COLLATE "C"),'')) INTO cnt,digest FROM dnm_private.v44_items WHERE job_id=jid AND collection=c.name;
   IF cnt<>(expected->>'count')::bigint OR digest IS DISTINCT FROM expected->>'sha256' THEN RAISE EXCEPTION '파일의 건수 또는 무결성이 일치하지 않습니다: %',c.name;END IF;
  END LOOP;
  IF EXISTS(SELECT FROM dnm_private.v44_items x WHERE x.job_id=jid AND x.collection='profiles' AND NOT EXISTS(SELECT FROM public.dnm_portal_profiles p2 WHERE p2.id::text=x.row_key)) THEN RAISE EXCEPTION '백업에 있던 로그인 계정이 삭제되었습니다. 계정 복구 확인 전에는 복원할 수 없습니다.';END IF;
  UPDATE dnm_private.v44_jobs SET status='validated' WHERE id=jid;
  RETURN dnm_private.v44_summary(jid);
 END IF;
 RAISE EXCEPTION '지원하지 않는 백업 작업입니다.';
END $$;
-- Only the server-side authenticated-and-reauthenticated administrator handler may call this RPC.
CREATE OR REPLACE FUNCTION public.dnm_v44_restore_apply(p_actor uuid,p_stage uuid,p_safety uuid,p_reason text,p_confirmation text) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path='' SET lock_timeout='4s' SET statement_timeout='30s' AS $$
DECLARE j dnm_private.v44_jobs;s dnm_private.v44_jobs;g dnm_private.v44_gate;c record;cols text;cnt bigint;digest text;expected jsonb;ts timestamptz:=clock_timestamp();
BEGIN
 PERFORM pg_advisory_xact_lock(164044,1);PERFORM pg_advisory_xact_lock(164044,2);
 IF NOT EXISTS(SELECT FROM public.dnm_portal_profiles WHERE id=p_actor AND active AND role='admin') THEN RAISE EXCEPTION '관리자 권한이 필요합니다.' USING ERRCODE='42501';END IF;
 SELECT * INTO j FROM dnm_private.v44_jobs WHERE id=p_stage FOR UPDATE;
 IF j.id IS NULL OR j.actor_id<>p_actor OR j.job_type<>'restore' THEN RAISE EXCEPTION '본인이 검사한 백업을 선택하세요.';END IF;
 IF j.status='applied' THEN RETURN jsonb_build_object('ok',true,'applied',true,'already_applied',true,'stage_id',p_stage,'applied_at',j.applied_at);END IF;
 IF j.status<>'validated' OR p_confirmation IS DISTINCT FROM '백업시점복원' OR length(trim(coalesce(p_reason,''))) NOT BETWEEN 2 AND 500 THEN RAISE EXCEPTION '파일 검사, 확인문구, 복원 사유를 확인하세요.';END IF;
 SELECT * INTO s FROM dnm_private.v44_jobs WHERE id=p_safety;
 IF s.id IS NULL OR s.actor_id<>p_actor OR s.status<>'ready' OR s.purpose<>'safety' OR s.safety_for IS DISTINCT FROM p_stage OR s.ack_at IS NULL THEN RAISE EXCEPTION '현재자료 안전백업을 내려받고 같은 파일을 다시 선택하여 검사하세요.';END IF;
 SELECT * INTO g FROM dnm_private.v44_gate WHERE id FOR UPDATE;
 IF g.job_id IS NOT NULL AND g.expires_at>ts THEN RAISE EXCEPTION '다른 백업이 진행 중입니다.';END IF;
 IF g.revision<>s.revision THEN RAISE EXCEPTION '안전백업 후 자료가 변경되었습니다. 다른 사용자의 입력을 멈추고 안전백업을 다시 받으세요.';END IF;
 IF EXISTS(SELECT FROM dnm_private.login_jobs WHERE phase='prepared') OR EXISTS(SELECT FROM dnm_private.login_controls WHERE state='changing') THEN RAISE EXCEPTION '계정 등록·비밀번호 변경을 먼저 완료하세요.';END IF;
 FOR c IN SELECT * FROM dnm_private.v44_collections() LOOP
  SELECT x INTO expected FROM jsonb_array_elements(j.manifest->'collections') x WHERE x->>'name'=c.name;
  SELECT count(*),dnm_private.v44_hash(coalesce(string_agg(row_key||':'||row_hash,E'\n' ORDER BY row_key COLLATE "C"),'')) INTO cnt,digest FROM dnm_private.v44_items WHERE job_id=p_stage AND collection=c.name;
  IF cnt<>(expected->>'count')::bigint OR digest IS DISTINCT FROM expected->>'sha256' THEN RAISE EXCEPTION '검사 후 파일 내용이 달라졌습니다.';END IF;
 END LOOP;
 UPDATE dnm_private.v44_gate SET restore_xid=txid_current() WHERE id;
 UPDATE dnm_private.v44_jobs SET status='applying',reason=trim(p_reason) WHERE id=p_stage;
 SET CONSTRAINTS ALL DEFERRED;
 -- Preserve security records; detach only employees absent from the chosen business snapshot.
 UPDATE dnm_private.login_controls l SET employee_id=NULL,enabled=CASE WHEN l.profile_id=p_actor THEN l.enabled ELSE false END,state=CASE WHEN l.profile_id=p_actor THEN l.state ELSE 'disabled' END,cutoff_at=ts,updated_at=ts
 WHERE l.employee_id IS NOT NULL AND NOT EXISTS(SELECT FROM dnm_private.v44_items i WHERE i.job_id=p_stage AND i.collection='records' AND i.row_key=l.employee_id::text);
 UPDATE dnm_private.login_jobs l SET employee_id=NULL WHERE l.employee_id IS NOT NULL AND NOT EXISTS(SELECT FROM dnm_private.v44_items i WHERE i.job_id=p_stage AND i.collection='records' AND i.row_key=l.employee_id::text);
 -- Business replacement is ONE transaction. An error/timeout rolls back all deletions and inserts.
 DELETE FROM public.dnm_v4_requests;
 DELETE FROM public.dnm_v42_module_access;
 DELETE FROM public.dnm_v4_permissions;
 DELETE FROM public.dnm_portal_notes;
 DELETE FROM public.dnm_v4_records;
 DELETE FROM public.dnm_portal_products;
 DELETE FROM public.dnm_portal_partners;
 FOR c IN SELECT * FROM dnm_private.v44_collections() WHERE restore_mode='replace' LOOP
  SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute WHERE attrelid=('public.'||c.rel)::regclass AND attnum>0 AND NOT attisdropped;
  EXECUTE format('INSERT INTO public.%I (%s) SELECT %s FROM dnm_private.v44_items i CROSS JOIN LATERAL jsonb_populate_record(NULL::public.%I,i.row_data) t WHERE i.job_id=$1 AND i.collection=$2',c.rel,cols,(SELECT string_agg('t.'||quote_ident(attname),',' ORDER BY attnum) FROM pg_attribute WHERE attrelid=('public.'||c.rel)::regclass AND attnum>0 AND NOT attisdropped),c.rel) USING p_stage,c.name;
 END LOOP;
 UPDATE public.dnm_portal_profiles p2 SET display_name=i.row_data->>'display_name'
 FROM dnm_private.v44_items i WHERE i.job_id=p_stage AND i.collection='profiles' AND p2.id::text=i.row_key;
 -- Audit history is append-only: operations after the chosen point remain traceable.
 INSERT INTO public.dnm_portal_audit(id,actor_id,entity,record_id,action,old_value,new_value,created_at) OVERRIDING SYSTEM VALUE
 SELECT t.id,t.actor_id,t.entity,t.record_id,t.action,t.old_value,t.new_value,t.created_at
 FROM dnm_private.v44_items i CROSS JOIN LATERAL jsonb_populate_record(NULL::public.dnm_portal_audit,i.row_data)t
 WHERE i.job_id=p_stage AND i.collection='audit' ON CONFLICT(id) DO NOTHING;
 PERFORM setval(pg_get_serial_sequence('public.dnm_portal_audit','id'),greatest(coalesce((SELECT max(id) FROM public.dnm_portal_audit),0),1),EXISTS(SELECT FROM public.dnm_portal_audit));
 SET CONSTRAINTS ALL IMMEDIATE;
 UPDATE dnm_private.v44_jobs SET status='applied',applied_at=ts WHERE id=p_stage;
 INSERT INTO dnm_private.v44_events(actor_id,action,job_id,source_id,safety_id,details)
 VALUES(p_actor,'restore_applied',p_stage,j.source_id,p_safety,jsonb_build_object('reason',trim(p_reason),'restored_point',j.manifest->'captured_at','security_preserved',true));
 INSERT INTO public.dnm_portal_audit(actor_id,entity,record_id,action,new_value)
 VALUES(p_actor,'backup_restore',p_stage::text,'RESTORE',jsonb_build_object('source',j.source_id,'safety',p_safety,'reason',trim(p_reason)));
 UPDATE dnm_private.v44_gate SET job_id=NULL,expires_at=NULL,restore_xid=NULL,revision=revision+1,session_cutoff=clock_timestamp() WHERE id;
 RETURN jsonb_build_object('ok',true,'applied',true,'stage_id',p_stage,'applied_at',ts,'captured_at',j.manifest->'captured_at','relogin_required',true);
END $$;
-- Extend the context without changing the existing ACL/schema compatibility contract.
DO $$ BEGIN
 IF to_regprocedure('dnm_private.v43_context_before_v44()') IS NULL THEN
  ALTER FUNCTION public.dnm_v4_context() RENAME TO v43_context_before_v44;
  ALTER FUNCTION public.v43_context_before_v44() SET SCHEMA dnm_private;
 END IF;
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v4_context() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT dnm_private.v43_context_before_v44()||jsonb_build_object('backup_management','4.4.0');
$$;
-- Retire the unbounded legacy JSON export with a small actionable reply, not a large query.
CREATE OR REPLACE FUNCTION public.dnm_v4_backup() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN RAISE EXCEPTION '백업 화면을 새로고침한 후 전체 업무자료 백업을 이용하세요.';END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA dnm_private FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.dnm_v44_backup_api(text,jsonb),public.dnm_v44_restore_apply(uuid,uuid,uuid,text,text),public.dnm_v4_context(),public.dnm_v43_session_ok() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v44_backup_api(text,jsonb),public.dnm_v4_context(),public.dnm_v43_session_ok() TO authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v44_restore_apply(uuid,uuid,uuid,text,text) TO service_role;
-- Trigger function is invoked by permitted business-table writes, but is not an API entrypoint.
REVOKE ALL ON FUNCTION public.dnm_portal_touch(),public.dnm_portal_record_change() FROM PUBLIC,anon,authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
