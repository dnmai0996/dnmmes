-- DNM v4.9.0. Existing v4.2+ business schema required. One atomic transaction.
BEGIN;
DO $pre$ BEGIN
 IF to_regprocedure('public.dnm_v42_setup(text,jsonb,text)') IS NULL OR to_regprocedure('public.dnm_v42_set_access(uuid,jsonb,boolean,numeric,date,text)') IS NULL THEN
 RAISE EXCEPTION 'v4.2 이상 기존 업무 스키마가 필요합니다. 적용 중단: 기존 자료 변경 없음.'; END IF;
END $pre$;

DO $install$ BEGIN IF to_regprocedure('public.dnm_v43_accounts()') IS NULL THEN EXECUTE $source$-- DNM Cloud MES v4.3: administrator-managed worker login.
-- Apply AFTER 08_upgrade_v4_2.sql. Additive: no business rows or accounts removed.
-- Temporary 1111 is NOT a Supabase Auth password. It grants a short-lived password-setup ticket only.

DO $$ BEGIN
 IF to_regprocedure('public.dnm_v42_setup(text,jsonb,text)') IS NULL THEN RAISE EXCEPTION '먼저 v4.2 SQL(08)을 적용하세요.'; END IF;
 IF to_regclass('auth.sessions') IS NULL OR to_regprocedure('auth.jwt()') IS NULL THEN RAISE EXCEPTION 'Supabase Auth 세션 구조를 확인하세요.'; END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS dnm_private;
REVOKE ALL ON SCHEMA dnm_private FROM PUBLIC,anon,authenticated;
CREATE TABLE IF NOT EXISTS dnm_private.login_controls (
 profile_id uuid PRIMARY KEY REFERENCES public.dnm_portal_profiles(id),
 employee_id uuid UNIQUE REFERENCES public.dnm_v4_records(id),
 email text NOT NULL,enabled boolean NOT NULL DEFAULT false,
 state text NOT NULL CHECK(state IN('provisioning','pending','changing','ready','disabled','error')),
 generation uuid NOT NULL DEFAULT gen_random_uuid(),
 code_salt text,code_hash text,expires_at timestamptz,
 cutoff_at timestamptz NOT NULL DEFAULT now(),changed_at timestamptz,
 updated_by uuid,updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS dnm_private.login_jobs (
 id uuid PRIMARY KEY,employee_id uuid NOT NULL REFERENCES public.dnm_v4_records(id),
 actor_id uuid NOT NULL,action text NOT NULL CHECK(action IN('provision','reset','disable')),
 email text NOT NULL,target_id uuid,generation uuid NOT NULL,is_new boolean NOT NULL DEFAULT false,
 phase text NOT NULL DEFAULT 'prepared' CHECK(phase IN('prepared','done','failed')),
 employee_version integer NOT NULL,reason text NOT NULL,
 result jsonb,created_at timestamptz NOT NULL DEFAULT now(),finished_at timestamptz
);
CREATE TABLE IF NOT EXISTS dnm_private.login_tickets (
 ticket_hash text PRIMARY KEY CHECK(length(ticket_hash)=64),profile_id uuid NOT NULL REFERENCES public.dnm_portal_profiles(id),
 generation uuid NOT NULL,phase text NOT NULL DEFAULT 'issued' CHECK(phase IN('issued','using','used')),
 expires_at timestamptz NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS dnm_private.login_rate (
 bucket text PRIMARY KEY,window_at timestamptz NOT NULL,count integer NOT NULL CHECK(count>=0)
);
REVOKE ALL ON ALL TABLES IN SCHEMA dnm_private FROM PUBLIC,anon,authenticated;

-- The session check is enforced by both RLS and SECURITY DEFINER business entry points.
-- Reset invalidates OLD SESSION IDs as well as old access tokens (refresh cannot bypass it).
CREATE OR REPLACE FUNCTION public.dnm_v43_session_ok() RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid();c dnm_private.login_controls;sid text;
BEGIN
 IF uid IS NULL THEN RETURN false; END IF;
 SELECT * INTO c FROM dnm_private.login_controls WHERE profile_id=uid;
 IF NOT FOUND THEN RETURN true; END IF; -- preserve existing unmanaged accounts
 IF NOT c.enabled OR c.state<>'ready' THEN RETURN false; END IF;
 IF c.employee_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.dnm_v4_records e WHERE e.id=c.employee_id AND e.kind='employee' AND e.data->>'active'='true') THEN RETURN false;END IF;
 sid:=auth.jwt()->>'session_id';
 IF sid IS NULL OR sid !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN RETURN false;END IF;
 RETURN EXISTS(SELECT 1 FROM auth.sessions s WHERE s.id=sid::uuid AND s.user_id=uid AND s.created_at>=c.cutoff_at);
END $$;
CREATE OR REPLACE FUNCTION public.dnm_portal_role() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT role FROM public.dnm_portal_profiles WHERE id=auth.uid() AND active AND public.dnm_v43_session_ok();
$$;
CREATE OR REPLACE FUNCTION dnm_private.acl_for(uid uuid,m text,a text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce((SELECT p.active
 AND (CASE WHEN uid=auth.uid() THEN public.dnm_v43_session_ok()
 ELSE NOT EXISTS(SELECT 1 FROM dnm_private.login_controls c WHERE c.profile_id=uid AND (NOT c.enabled OR c.state IN('disabled','error','provisioning'))) END)
 AND (p.role='admin' OR EXISTS(SELECT 1 FROM public.dnm_v42_module_access v WHERE v.profile_id=p.id AND v.module=m AND v.can_read AND CASE a WHEN 'read' THEN true WHEN 'create' THEN p.role='member' AND v.can_create WHEN 'update' THEN p.role='member' AND v.can_update ELSE false END))
 FROM public.dnm_portal_profiles p WHERE p.id=uid),false);
$$;
DO $$ BEGIN
 IF to_regprocedure('dnm_private.dnm_v42_context_impl()') IS NULL THEN
  ALTER FUNCTION public.dnm_v4_context() RENAME TO dnm_v42_context_impl;
  ALTER FUNCTION public.dnm_v42_context_impl() SET SCHEMA dnm_private;
 END IF;
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v4_context() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE x jsonb;BEGIN
 IF public.dnm_portal_role() IS NULL THEN RAISE EXCEPTION '로그인 사용중지 또는 비밀번호 변경 대기 상태입니다. 다시 로그인하세요.' USING ERRCODE='42501';END IF;
 x:=dnm_private.dnm_v42_context_impl();RETURN x||jsonb_build_object('account_management','4.3.0');
END $$;
-- An additional RESTRICTIVE policy protects every existing DNM table, including own-profile queries.
DO $$ DECLARE r record;BEGIN
 FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND (c.relname LIKE 'dnm_portal_%' OR c.relname LIKE 'dnm_v4_%' OR c.relname LIKE 'dnm_v42_%') LOOP
  EXECUTE format('DROP POLICY IF EXISTS dnm_v43_session_gate ON public.%I',r.relname);
  EXECUTE format('CREATE POLICY dnm_v43_session_gate ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING (public.dnm_v43_session_ok()) WITH CHECK (public.dnm_v43_session_ok())',r.relname);
 END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.dnm_v43_my_account_status() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('managed',EXISTS(SELECT 1 FROM dnm_private.login_controls WHERE profile_id=auth.uid()),
 'state',(SELECT state FROM dnm_private.login_controls WHERE profile_id=auth.uid()),'allowed',public.dnm_v43_session_ok());
$$;
CREATE OR REPLACE FUNCTION public.dnm_v43_accounts() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION '관리자만 사용자 계정을 관리할 수 있습니다.' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('version','4.3.0','workers',coalesce((SELECT jsonb_agg(jsonb_build_object(
 'id',e.id,'version',e.version,'code',e.code,'name',e.title,'department',e.data->>'department','position',e.data->>'position','hired',e.data->>'hired',
 'employee_active',e.data->>'active'='true','email',coalesce(p.email,e.data->>'email',''),
 'profile_id',p.id,'role',p.role,'profile_active',coalesce(p.active,false),
 'enabled',coalesce(c.enabled,p.active,false),'state',coalesce(c.state,CASE WHEN p.id IS NULL THEN 'unregistered' WHEN p.active THEN 'existing' ELSE 'disabled' END),
 'expires_at',c.expires_at,'changed_at',c.changed_at,
 'protected',p.role='admin','last_operation',j.phase)
 ORDER BY e.code) FROM public.dnm_v4_records e
 LEFT JOIN public.dnm_portal_profiles p ON p.id::text=e.data->>'profile_id'
 LEFT JOIN dnm_private.login_controls c ON c.profile_id=p.id
 LEFT JOIN LATERAL (SELECT phase FROM dnm_private.login_jobs WHERE employee_id=e.id ORDER BY created_at DESC LIMIT 1) j ON true
 WHERE e.kind='employee'),'[]'::jsonb));
END $$;

-- One service-role-only RPC is used by Netlify. Client callers cannot execute it.
CREATE OR REPLACE FUNCTION public.dnm_v43_service(p_action text,p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET statement_timeout='15s' AS $$
DECLARE v_emp public.dnm_v4_records;v_usr public.dnm_portal_profiles;v_ctl dnm_private.login_controls;v_job dnm_private.login_jobs;v_ticket dnm_private.login_tickets;
 actor uuid;uid uuid;job uuid;v_email text;act text;gen uuid;isnew boolean:=false;res jsonb;v_bucket text;lim integer;seconds integer;nr integer;ts timestamptz:=clock_timestamp();
BEGIN
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'invalid payload';END IF;
 IF p_action='health' THEN RETURN jsonb_build_object('ok',true,'version','4.3.0');END IF;
 IF p_action='rate' THEN
  v_bucket:=p->>'bucket';lim:=(p->>'limit')::integer;seconds:=(p->>'seconds')::integer;
  IF v_bucket IS NULL OR length(v_bucket)>150 OR lim NOT BETWEEN 1 AND 1000 OR seconds NOT BETWEEN 30 AND 86400 THEN RAISE EXCEPTION 'invalid rate';END IF;
  INSERT INTO dnm_private.login_rate AS lr(bucket,window_at,count) VALUES(v_bucket,ts,1)
  ON CONFLICT ON CONSTRAINT login_rate_pkey DO UPDATE SET window_at=CASE WHEN lr.window_at<=ts-make_interval(secs=>seconds) THEN ts ELSE lr.window_at END,
  count=CASE WHEN lr.window_at<=ts-make_interval(secs=>seconds) THEN 1 ELSE lr.count+1 END RETURNING count INTO nr;
  DELETE FROM dnm_private.login_rate WHERE window_at<ts-interval '2 days';
  RETURN jsonb_build_object('allowed',nr<=lim);
 END IF;
 IF p_action='clear_rate' THEN
  DELETE FROM dnm_private.login_rate WHERE bucket='email:'||(p->>'email_hash');
  RETURN jsonb_build_object('ok',true);
 END IF;
 IF p_action='probe' THEN
  v_email:=lower(trim(p->>'email'));
  SELECT x.* INTO v_ctl FROM dnm_private.login_controls x JOIN public.dnm_portal_profiles z ON z.id=x.profile_id
   WHERE lower(x.email)=v_email AND x.enabled AND z.active AND z.role<>'admin' AND x.state='pending' AND x.expires_at>ts AND EXISTS(SELECT 1 FROM public.dnm_v4_records worker_row WHERE worker_row.id=x.employee_id AND worker_row.kind='employee' AND worker_row.data->>'active'='true');
  IF NOT FOUND THEN RETURN jsonb_build_object('valid',false);END IF;
  RETURN jsonb_build_object('valid',true,'profile_id',v_ctl.profile_id,'generation',v_ctl.generation,'salt',v_ctl.code_salt,'hash',v_ctl.code_hash);
 END IF;
 IF p_action='issue_ticket' THEN
  SELECT * INTO v_ctl FROM dnm_private.login_controls WHERE profile_id=(p->>'profile_id')::uuid FOR UPDATE;
  IF NOT FOUND OR NOT v_ctl.enabled OR v_ctl.state<>'pending' OR v_ctl.generation<>(p->>'generation')::uuid OR v_ctl.expires_at<=ts THEN RAISE EXCEPTION '초기 로그인 시간이 만료되었습니다. 관리자에게 다시 초기화를 요청하세요.';END IF;
  IF length(p->>'hash')<>64 THEN RAISE EXCEPTION 'invalid ticket';END IF;
  UPDATE dnm_private.login_tickets SET phase='used' WHERE profile_id=v_ctl.profile_id;
  INSERT INTO dnm_private.login_tickets(ticket_hash,profile_id,generation,expires_at) VALUES(p->>'hash',v_ctl.profile_id,v_ctl.generation,least(ts+interval '5 minutes',v_ctl.expires_at));
  DELETE FROM dnm_private.login_tickets WHERE expires_at<ts-interval '1 day';
  RETURN jsonb_build_object('ok',true,'expires_at',least(ts+interval '5 minutes',v_ctl.expires_at));
 END IF;
 IF p_action='begin_change' THEN
  SELECT * INTO v_ticket FROM dnm_private.login_tickets WHERE ticket_hash=p->>'hash' FOR UPDATE;
  IF NOT FOUND OR v_ticket.phase<>'issued' OR v_ticket.expires_at<=ts THEN RAISE EXCEPTION '설정 시간이 만료되었거나 이미 사용한 요청입니다. 관리자에게 초기화를 요청하세요.';END IF;
  SELECT * INTO v_ctl FROM dnm_private.login_controls WHERE profile_id=v_ticket.profile_id FOR UPDATE;
  IF NOT FOUND OR NOT v_ctl.enabled OR v_ctl.state<>'pending' OR v_ctl.generation<>v_ticket.generation THEN RAISE EXCEPTION '계정 설정 상태가 변경되었습니다.';END IF;
  UPDATE dnm_private.login_tickets SET phase='using' WHERE ticket_hash=v_ticket.ticket_hash;
  UPDATE dnm_private.login_controls SET state='changing',updated_at=ts WHERE profile_id=v_ctl.profile_id;
  RETURN jsonb_build_object('ok',true,'profile_id',v_ctl.profile_id,'email',v_ctl.email);
 END IF;
 IF p_action='finish_change' THEN
  SELECT * INTO v_ticket FROM dnm_private.login_tickets WHERE ticket_hash=p->>'hash' FOR UPDATE;
  IF NOT FOUND OR v_ticket.phase<>'using' OR v_ticket.expires_at<=ts THEN RAISE EXCEPTION '설정 요청을 다시 확인하세요.';END IF;
  SELECT * INTO v_ctl FROM dnm_private.login_controls WHERE profile_id=v_ticket.profile_id FOR UPDATE;
  IF NOT FOUND OR NOT v_ctl.enabled OR v_ctl.state<>'changing' OR v_ctl.generation<>v_ticket.generation THEN RAISE EXCEPTION '계정 상태 변경';END IF;
  UPDATE dnm_private.login_controls SET state='ready',code_salt=NULL,code_hash=NULL,expires_at=NULL,cutoff_at=ts,changed_at=ts,updated_at=ts WHERE profile_id=v_ctl.profile_id;
  UPDATE dnm_private.login_tickets SET phase='used' WHERE ticket_hash=v_ticket.ticket_hash;
  INSERT INTO public.dnm_portal_audit(actor_id,entity,record_id,action,new_value) VALUES(v_ctl.profile_id,'login_account',v_ctl.profile_id::text,'PASSWORD_SET',jsonb_build_object('state','ready'));
  RETURN jsonb_build_object('ok',true);
 END IF;
 IF p_action='change_failed' THEN
  SELECT * INTO v_ticket FROM dnm_private.login_tickets WHERE ticket_hash=p->>'hash' FOR UPDATE;
  IF FOUND THEN
   UPDATE dnm_private.login_controls SET state='error',code_salt=NULL,code_hash=NULL,expires_at=NULL,updated_at=ts WHERE profile_id=v_ticket.profile_id AND generation=v_ticket.generation AND state='changing';
   UPDATE dnm_private.login_tickets SET phase='used' WHERE ticket_hash=v_ticket.ticket_hash;
  END IF;RETURN jsonb_build_object('ok',true);
 END IF;
 IF p_action='self_changed' THEN
  uid:=(p->>'profile_id')::uuid;
  IF NOT EXISTS(SELECT 1 FROM public.dnm_portal_profiles WHERE id=uid AND active) THEN RAISE EXCEPTION '계정 상태를 확인하세요.';END IF;
  SELECT * INTO v_ctl FROM dnm_private.login_controls WHERE profile_id=uid FOR UPDATE;
  IF FOUND AND (NOT v_ctl.enabled OR v_ctl.state<>'ready') THEN RAISE EXCEPTION '계정 상태가 변경되었습니다.';END IF;
  INSERT INTO dnm_private.login_controls(profile_id,email,enabled,state,cutoff_at,changed_at,updated_at)
  SELECT id,email,true,'ready',ts,ts,ts FROM public.dnm_portal_profiles WHERE id=uid
  ON CONFLICT(profile_id) DO UPDATE SET cutoff_at=excluded.cutoff_at,changed_at=excluded.changed_at,updated_at=excluded.updated_at;
  INSERT INTO public.dnm_portal_audit(actor_id,entity,record_id,action,new_value) VALUES(uid,'login_account',uid::text,'PASSWORD_CHANGE',jsonb_build_object('sessions','previous_sessions_denied'));
  RETURN jsonb_build_object('ok',true);
 END IF;
 IF p_action IN('prepare','finish','failed') THEN
  actor:=(p->>'actor_id')::uuid;
  IF NOT EXISTS(SELECT 1 FROM public.dnm_portal_profiles z WHERE z.id=actor AND z.active AND z.role='admin') OR EXISTS(SELECT 1 FROM dnm_private.login_controls z WHERE z.profile_id=actor AND (NOT z.enabled OR z.state<>'ready')) THEN RAISE EXCEPTION '관리자 권한이 필요합니다.' USING ERRCODE='42501';END IF;
  PERFORM pg_advisory_xact_lock(164043,1);
  job:=(p->>'request_id')::uuid;
  SELECT * INTO v_job FROM dnm_private.login_jobs WHERE id=job FOR UPDATE;
  IF p_action='prepare' THEN
   act:=p->>'action';v_email:=lower(trim(p->>'email'));
   IF act NOT IN('provision','reset','disable') OR length(coalesce(p->>'reason','')) NOT BETWEEN 2 AND 1000 THEN RAISE EXCEPTION '변경사유를 입력하세요.';END IF;
   IF v_job.id IS NOT NULL THEN
    IF v_job.actor_id<>actor OR v_job.employee_id<>(p->>'employee_id')::uuid OR v_job.action<>act OR v_job.email<>v_email THEN RAISE EXCEPTION '같은 요청번호의 내용이 다릅니다.';END IF;
    IF v_job.phase='done' THEN RETURN jsonb_build_object('done',true,'result',v_job.result);END IF;
    RAISE EXCEPTION '이 요청은 처리 중이거나 실패했습니다. 목록을 새로고침하고 새 요청으로 다시 진행하세요.';
   END IF;
   SELECT * INTO v_emp FROM public.dnm_v4_records WHERE id=(p->>'employee_id')::uuid AND kind='employee' FOR UPDATE;
   IF NOT FOUND OR v_emp.version<>(p->>'version')::integer THEN RAISE EXCEPTION '작업자 정보가 변경되었습니다. 다시 조회하세요.';END IF;
   IF EXISTS(SELECT 1 FROM dnm_private.login_jobs WHERE employee_id=v_emp.id AND phase='prepared' AND created_at>ts-interval '2 minutes') THEN RAISE EXCEPTION '같은 작업자의 계정 처리가 진행 중입니다. 2분 후 다시 조회하세요.';END IF;
   IF v_email IS NULL OR length(v_email)>254 OR v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN RAISE EXCEPTION '본인의 정확한 이메일을 입력하세요.';END IF;
   uid:=nullif(v_emp.data->>'profile_id','')::uuid;
   IF uid IS NOT NULL THEN
    SELECT * INTO v_usr FROM public.dnm_portal_profiles WHERE id=uid;
    IF NOT FOUND OR lower(v_usr.email)<>v_email THEN RAISE EXCEPTION '연결된 계정의 이메일은 여기서 변경하지 않습니다.';END IF;
   ELSE
    SELECT id INTO uid FROM auth.users WHERE lower(auth.users.email)=v_email;
    IF uid IS NOT NULL THEN SELECT * INTO v_usr FROM public.dnm_portal_profiles WHERE id=uid;END IF;
   END IF;
   IF uid=actor OR v_usr.role='admin' THEN RAISE EXCEPTION '본인·관리자 계정은 작업자 초기화 기능으로 변경할 수 없습니다.';END IF;
   IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='employee' AND id<>v_emp.id AND data->>'profile_id'=uid::text) THEN RAISE EXCEPTION '다른 작업자에게 연결된 이메일입니다.';END IF;
   IF EXISTS(SELECT 1 FROM dnm_private.login_jobs x WHERE x.email=lower(trim(p->>'email')) AND x.employee_id<>v_emp.id AND x.phase='prepared' AND x.created_at>ts-interval '2 minutes') THEN RAISE EXCEPTION '같은 이메일의 등록이 진행 중입니다.';END IF;
   -- Same-email concurrency is also caught by Auth uniqueness and finish re-validation.
   IF act='provision' AND nullif(v_emp.data->>'profile_id','') IS NOT NULL THEN RAISE EXCEPTION '이미 등록된 작업자입니다. 초기화 또는 사용중지를 선택하세요.';END IF;
   IF act IN('reset','disable') AND (uid IS NULL OR nullif(v_emp.data->>'profile_id','') IS NULL) THEN RAISE EXCEPTION '먼저 로그인 사용자로 등록하세요.';END IF;
   gen:=gen_random_uuid();isnew:=uid IS NULL;
   -- Recover only a partial creation by this workflow; never infer role from a matching name.
   IF NOT isnew AND nullif(v_emp.data->>'profile_id','') IS NULL AND EXISTS(SELECT 1 FROM auth.users a WHERE a.id=uid AND a.raw_user_meta_data->>'dnm_employee_id'=v_emp.id::text)
     AND EXISTS(SELECT 1 FROM dnm_private.login_jobs x WHERE x.employee_id=v_emp.id AND x.email=v_email AND x.is_new AND x.phase='failed')
     AND NOT EXISTS(SELECT 1 FROM public.dnm_v42_module_access x WHERE x.profile_id=uid) THEN isnew:=true;END IF;
   UPDATE dnm_private.login_jobs SET phase='failed',finished_at=ts WHERE employee_id=v_emp.id AND phase='prepared';
   INSERT INTO dnm_private.login_jobs(id,employee_id,actor_id,action,email,target_id,generation,is_new,employee_version,reason)
   VALUES(job,v_emp.id,actor,act,v_email,uid,gen,isnew,v_emp.version,p->>'reason');
   IF uid IS NOT NULL THEN
    INSERT INTO dnm_private.login_controls(profile_id,employee_id,email,enabled,state,generation,cutoff_at,updated_by)
    VALUES(uid,v_emp.id,v_email,act<>'disable',CASE WHEN act='disable' THEN 'disabled' ELSE 'provisioning' END,gen,ts,actor)
    ON CONFLICT(profile_id) DO UPDATE SET employee_id=excluded.employee_id,email=excluded.email,enabled=excluded.enabled,state=excluded.state,generation=gen,code_hash=NULL,code_salt=NULL,expires_at=NULL,cutoff_at=ts,updated_by=actor,updated_at=ts;
    UPDATE dnm_private.login_tickets SET phase='used' WHERE profile_id=uid;
   END IF;
   IF act='disable' THEN
    UPDATE public.dnm_portal_profiles SET active=false WHERE id=uid;
    UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('login_enabled',false) WHERE id=v_emp.id;
    res:=jsonb_build_object('ok',true,'state','disabled','message','로그인 사용을 중지했습니다. 기존 작업이력은 보존됩니다.');
    UPDATE dnm_private.login_jobs SET phase='done',result=res,finished_at=ts WHERE id=job;
    INSERT INTO public.dnm_portal_audit(actor_id,entity,record_id,action,new_value) VALUES(actor,'login_account',uid::text,'DISABLE',jsonb_build_object('reason',p->>'reason','employee_id',v_emp.id));
    RETURN jsonb_build_object('done',true,'result',res);
   END IF;
   RETURN jsonb_build_object('done',false,'profile_id',uid,'email',v_email,'name',v_emp.title,'employee_id',v_emp.id,'generation',gen,'new_user',uid IS NULL);
  END IF;
  IF v_job.id IS NULL OR v_job.actor_id<>actor THEN RAISE EXCEPTION '처리요청을 확인하세요.';END IF;
  IF v_job.phase='done' THEN RETURN v_job.result;END IF;
  IF p_action='failed' THEN
   UPDATE dnm_private.login_jobs SET phase='failed',finished_at=ts WHERE id=job AND phase='prepared';
   UPDATE dnm_private.login_controls SET state='error',code_hash=NULL,code_salt=NULL,expires_at=NULL,updated_at=ts WHERE profile_id=v_job.target_id AND generation=v_job.generation AND state='provisioning';
   RETURN jsonb_build_object('ok',true);
  END IF;
  IF v_job.phase<>'prepared' THEN RAISE EXCEPTION '새 계정 처리요청이 필요합니다.';END IF;
  uid:=(p->>'profile_id')::uuid;
  IF NOT EXISTS(SELECT 1 FROM auth.users WHERE id=uid AND lower(auth.users.email)=v_job.email) THEN RAISE EXCEPTION '생성된 인증계정의 이메일을 확인하세요.';END IF;
  IF v_job.target_id IS NOT NULL AND v_job.target_id<>uid THEN RAISE EXCEPTION '계정 불일치';END IF;
  SELECT * INTO v_emp FROM public.dnm_v4_records WHERE id=v_job.employee_id AND version=v_job.employee_version FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '처리 중 작업자 정보가 변경되었습니다.';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='employee' AND id<>v_emp.id AND data->>'profile_id'=uid::text) THEN RAISE EXCEPTION '다른 작업자와 연결된 계정입니다.';END IF;
  SELECT * INTO v_usr FROM public.dnm_portal_profiles WHERE id=uid FOR UPDATE;
  IF NOT FOUND OR v_usr.role='admin' OR uid=actor THEN RAISE EXCEPTION '보호된 계정입니다.';END IF;
  IF length(p->>'salt')<>32 OR length(p->>'hash')<>128 THEN RAISE EXCEPTION '초기번호 검증정보 오류';END IF;
  UPDATE public.dnm_portal_profiles SET active=true,display_name=v_emp.title,role=CASE WHEN v_job.is_new THEN 'member' ELSE role END WHERE id=uid;
  INSERT INTO dnm_private.login_controls(profile_id,employee_id,email,enabled,state,generation,code_salt,code_hash,expires_at,cutoff_at,updated_by,updated_at)
  VALUES(uid,v_emp.id,v_job.email,true,'pending',v_job.generation,p->>'salt',p->>'hash',ts+interval '30 minutes',ts,actor,ts)
  ON CONFLICT(profile_id) DO UPDATE SET employee_id=excluded.employee_id,email=excluded.email,enabled=true,state='pending',generation=v_job.generation,code_salt=excluded.code_salt,code_hash=excluded.code_hash,expires_at=excluded.expires_at,cutoff_at=ts,updated_by=actor,updated_at=ts;
  UPDATE public.dnm_v4_records SET data=data||jsonb_build_object('profile_id',uid,'email',v_job.email,'login_enabled',true,'active',true,'verified',true,'review_required',false) WHERE id=v_emp.id;
  IF v_job.is_new THEN
   INSERT INTO public.dnm_v42_module_access(profile_id,module,can_read,can_create,can_update,scope,updated_by)
   VALUES(uid,'worklogs',true,true,true,'own',actor),(uid,'notes',true,false,false,'own',actor) ON CONFLICT(profile_id,module) DO NOTHING;
   INSERT INTO public.dnm_v4_permissions(profile_id,capabilities) VALUES(uid,ARRAY['work']::text[]) ON CONFLICT(profile_id) DO NOTHING;
  END IF;
  res:=jsonb_build_object('ok',true,'state','pending','profile_id',uid,'expires_at',ts+interval '30 minutes','message','이메일 / 초기번호 1111로 30분 안에 접속하여 본인 비밀번호를 설정하세요.');
  UPDATE dnm_private.login_jobs SET target_id=uid,phase='done',result=res,finished_at=ts WHERE id=job;
  INSERT INTO public.dnm_portal_audit(actor_id,entity,record_id,action,new_value) VALUES(actor,'login_account',uid::text,CASE v_job.action WHEN 'reset' THEN 'RESET' ELSE 'REGISTER' END,jsonb_build_object('employee_id',v_emp.id,'reason',v_job.reason,'state','pending'));
  RETURN res;
 END IF;
 RAISE EXCEPTION '허용되지 않는 계정 작업';
END $$;

REVOKE ALL ON FUNCTION public.dnm_v43_service(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v43_service(text,jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.dnm_v43_accounts(),public.dnm_v43_my_account_status(),public.dnm_v43_session_ok(),public.dnm_portal_role(),public.dnm_v4_context() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v43_accounts(),public.dnm_v43_my_account_status(),public.dnm_v43_session_ok(),public.dnm_portal_role(),public.dnm_v4_context() TO authenticated;
REVOKE ALL ON FUNCTION dnm_private.dnm_v42_context_impl(),dnm_private.acl_for(uuid,text,text) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION dnm_private.keep_login_mapping() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c dnm_private.login_controls;BEGIN
 IF NEW.kind='employee' THEN
  SELECT * INTO c FROM dnm_private.login_controls WHERE employee_id=NEW.id;
  IF FOUND THEN
   IF nullif(NEW.data->>'profile_id','') IS NOT NULL AND NEW.data->>'profile_id'<>c.profile_id::text THEN RAISE EXCEPTION '로그인 연결은 사용자 관리에서만 변경할 수 있습니다.';END IF;
   NEW.data:=NEW.data||jsonb_build_object('profile_id',c.profile_id,'email',c.email,'login_enabled',c.enabled);
  END IF;
 END IF;RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS dnm_v43_keep_login_mapping ON public.dnm_v4_records;
CREATE TRIGGER dnm_v43_keep_login_mapping BEFORE UPDATE ON public.dnm_v4_records FOR EACH ROW EXECUTE FUNCTION dnm_private.keep_login_mapping();
CREATE OR REPLACE FUNCTION dnm_private.prevent_pending_admin() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NEW.role='admin' AND OLD.role<>'admin' AND EXISTS(SELECT 1 FROM dnm_private.login_controls c WHERE c.profile_id=NEW.id AND (NOT c.enabled OR c.state<>'ready')) THEN
  RAISE EXCEPTION '직원이 본인 비밀번호 설정을 완료한 뒤 관리자 역할을 지정하세요.';
 END IF;RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS dnm_v43_pending_admin ON public.dnm_portal_profiles;
CREATE TRIGGER dnm_v43_pending_admin BEFORE UPDATE ON public.dnm_portal_profiles FOR EACH ROW EXECUTE FUNCTION dnm_private.prevent_pending_admin();
REVOKE ALL ON FUNCTION dnm_private.keep_login_mapping(),dnm_private.prevent_pending_admin() FROM PUBLIC,anon,authenticated;

NOTIFY pgrst,'reload schema';

$source$; END IF; END $install$;

-- DNM MES v4.7: Korean worker name is the login ID; Auth email remains private account metadata.
-- Apply AFTER 16_upgrade_v4_6_purchase.sql. Existing users/passwords/permissions/business data unchanged.
-- Service-role-only lookup: unauthenticated browser requests NEVER receive a name-to-email directory.

DO $$ BEGIN
 IF to_regclass('dnm_private.login_controls') IS NULL OR to_regprocedure('public.dnm_v43_accounts()') IS NULL
 THEN RAISE EXCEPTION '먼저 DNM v4.3 이상 계정관리 SQL(10)을 적용하세요.'; END IF;
END $$;

ALTER TABLE dnm_private.login_controls ADD COLUMN IF NOT EXISTS login_id text;

CREATE OR REPLACE FUNCTION dnm_private.assign_worker_login_id() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE base_name text; candidate text; num integer:=2;
BEGIN
 IF NEW.employee_id IS NULL THEN NEW.login_id:=NULL; RETURN NEW; END IF;
 -- Do not change an assigned login ID when a password or account state is updated.
 IF TG_OP='UPDATE' AND NEW.employee_id IS NOT DISTINCT FROM OLD.employee_id
    AND nullif(btrim(NEW.login_id),'') IS NOT NULL THEN RETURN NEW; END IF;
 SELECT btrim(e.title) INTO base_name FROM public.dnm_v4_records e
 WHERE e.id=NEW.employee_id AND e.kind='employee';
 IF nullif(base_name,'') IS NULL THEN RAISE EXCEPTION '작업자 성명을 먼저 등록하세요.'; END IF;
 base_name:=left(base_name,60);
 -- Serialise duplicate-name allocation; do not rely on a person->machine relationship.
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('dnm-worker-login:'||lower(base_name)));
 candidate:=base_name;
 WHILE EXISTS (SELECT 1 FROM dnm_private.login_controls c
               WHERE lower(c.login_id)=lower(candidate) AND c.profile_id<>NEW.profile_id) LOOP
   candidate:=base_name||'-'||num::text;
   num:=num+1;
   IF num>9999 THEN RAISE EXCEPTION '동명이인 로그인 ID 발급 한도를 확인하세요.'; END IF;
 END LOOP;
 NEW.login_id:=candidate;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS dnm_v47_assign_worker_login_id ON dnm_private.login_controls;
CREATE TRIGGER dnm_v47_assign_worker_login_id
 BEFORE INSERT OR UPDATE OF employee_id,login_id ON dnm_private.login_controls
 FOR EACH ROW EXECUTE FUNCTION dnm_private.assign_worker_login_id();

-- Backfill ONLY currently managed worker accounts, leaving administrator accounts untouched.
-- The trigger uses the employee's name and appends -2, -3, ... only for homonyms.
DO $$ DECLARE r record; BEGIN
 FOR r IN SELECT c.profile_id FROM dnm_private.login_controls c
          JOIN public.dnm_v4_records e ON e.id=c.employee_id AND e.kind='employee'
          WHERE nullif(btrim(c.login_id),'') IS NULL ORDER BY e.title,e.code,c.profile_id LOOP
   UPDATE dnm_private.login_controls SET login_id=NULL WHERE profile_id=r.profile_id;
 END LOOP;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS dnm_v47_worker_login_id_unique
 ON dnm_private.login_controls (lower(login_id)) WHERE login_id IS NOT NULL;
ALTER TABLE dnm_private.login_controls DROP CONSTRAINT IF EXISTS dnm_v47_login_id_format;
ALTER TABLE dnm_private.login_controls ADD CONSTRAINT dnm_v47_login_id_format CHECK (
 login_id IS NULL OR (length(btrim(login_id)) BETWEEN 1 AND 80 AND login_id !~ '@' AND login_id=btrim(login_id))
);

-- Only the Netlify server-side service key may resolve worker login IDs to Auth email addresses.
CREATE OR REPLACE FUNCTION public.dnm_v47_login_lookup(p_login text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE x jsonb;
BEGIN
 IF p_login IS NULL OR length(p_login)>80 OR length(btrim(p_login))<1 THEN RETURN '{}'::jsonb; END IF;
 SELECT jsonb_build_object(
  'profile_id',c.profile_id,'email',c.email,'login_id',c.login_id,
  'name',e.title,'state',c.state,'enabled',c.enabled
 ) INTO x
 FROM dnm_private.login_controls c
 JOIN public.dnm_v4_records e ON e.id=c.employee_id AND e.kind='employee'
 JOIN public.dnm_portal_profiles p ON p.id=c.profile_id
 WHERE lower(c.login_id)=lower(btrim(p_login))
   AND c.enabled AND c.state IN('ready','pending')
   AND p.active AND p.role<>'admin' AND e.data->>'active'='true';
 RETURN coalesce(x,'{}'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.dnm_v47_login_lookup(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v47_login_lookup(text) TO service_role;

-- Keep legacy account list unchanged. Extend its admin-only result with a login ID field.
CREATE OR REPLACE FUNCTION public.dnm_v47_accounts() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE x jsonb; workers jsonb;
BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN
  RAISE EXCEPTION '관리자만 사용자 계정을 관리할 수 있습니다.' USING ERRCODE='42501';
 END IF;
 x:=public.dnm_v43_accounts();
 SELECT coalesce(jsonb_agg(w || jsonb_build_object('login_id',coalesce(c.login_id,'')) ORDER BY w->>'code'),'[]'::jsonb)
 INTO workers FROM pg_catalog.jsonb_array_elements(x->'workers') w
 LEFT JOIN dnm_private.login_controls c ON c.employee_id=(w->>'id')::uuid;
 RETURN jsonb_set(x,'{workers}',workers)||jsonb_build_object('name_login','4.7.0');
END $$;
REVOKE ALL ON FUNCTION public.dnm_v47_accounts() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v47_accounts() TO authenticated;
REVOKE ALL ON FUNCTION dnm_private.assign_worker_login_id() FROM PUBLIC,anon,authenticated;

NOTIFY pgrst,'reload schema';

-- DNM MES v4.8.0. Additive change; worker master governs employee login use/stop.
-- Run only after scripts 10 (account), 14 (worker), and 18 (name login).
-- No tables, login accounts, worklogs, or historic approvals are deleted.

DO $$ BEGIN
 IF to_regprocedure('public.dnm_v47_accounts()') IS NULL
 OR to_regprocedure('public.dnm_v42_set_access(uuid,jsonb,boolean,numeric,date,text)') IS NULL
 OR to_regclass('dnm_private.login_controls') IS NULL
 THEN RAISE EXCEPTION '기존 v4.7까지 필요한 SQL이 설치되지 않았습니다. 먼저 누락된 SQL부터 확인하세요.'; END IF;
END $$;

-- Role and ACL are committed in the same transaction to avoid viewer write-permission errors.
CREATE OR REPLACE FUNCTION public.dnm_v48_set_access(
 p_user uuid,p_role text,p_acl jsonb,p_approve boolean,p_limit numeric,p_until date,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE old_role text;
BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION '관리자만 권한을 지정할 수 있습니다.' USING ERRCODE='42501'; END IF;
 IF p_user IS NULL OR p_user=auth.uid() THEN RAISE EXCEPTION '관리자 자신의 권한은 변경할 수 없습니다.' USING ERRCODE='42501'; END IF;
 IF p_role NOT IN ('viewer','member') THEN RAISE EXCEPTION '조회자 또는 일반사용자 역할을 선택하세요.'; END IF;
 IF jsonb_typeof(p_acl) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION '업무권한 목록을 확인하세요.'; END IF;
 IF p_role='viewer' AND EXISTS (
  SELECT 1 FROM pg_catalog.jsonb_array_elements(p_acl) x
  WHERE coalesce((x->>'create')::boolean,false) OR coalesce((x->>'update')::boolean,false)
 ) THEN RAISE EXCEPTION '등록·수정 권한이 있으면 일반사용자를 선택하세요.'; END IF;
 SELECT role INTO old_role FROM public.dnm_portal_profiles WHERE id=p_user FOR UPDATE;
 IF NOT FOUND OR old_role='admin' THEN RAISE EXCEPTION '관리자 계정은 이 화면에서 수정할 수 없습니다.' USING ERRCODE='42501'; END IF;
 UPDATE public.dnm_portal_profiles SET role=p_role WHERE id=p_user AND role IS DISTINCT FROM p_role;
 RETURN public.dnm_v42_set_access(p_user,p_acl,p_approve,p_limit,p_until,p_reason);
END $$;
REVOKE ALL ON FUNCTION public.dnm_v48_set_access(uuid,text,jsonb,boolean,numeric,date,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v48_set_access(uuid,text,jsonb,boolean,numeric,date,text) TO authenticated;

-- Existing login_controls remains an internal security table, not a second employee register.
CREATE OR REPLACE FUNCTION dnm_private.sync_worker_login(p_employee uuid,p_active boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c dnm_private.login_controls; target_role text; next_enabled boolean; next_state text;
BEGIN
 SELECT * INTO c FROM dnm_private.login_controls WHERE employee_id=p_employee FOR UPDATE;
 IF NOT FOUND THEN RETURN; END IF;
 SELECT role INTO target_role FROM public.dnm_portal_profiles WHERE id=c.profile_id FOR UPDATE;
 IF target_role='admin' THEN RAISE EXCEPTION '관리자 계정의 사용상태는 작업자 화면에서 변경할 수 없습니다.' USING ERRCODE='42501'; END IF;
 -- Reactivation only of previously established credentials. Never re-enable a failed or expired setup ticket.
 next_state:=CASE
   WHEN p_active AND c.state IN ('disabled','ready') AND c.changed_at IS NOT NULL THEN 'ready'
   ELSE c.state END;
 next_enabled:=p_active AND (
   (next_state='ready' AND c.changed_at IS NOT NULL)
   OR (next_state='pending' AND c.expires_at>now())
 );
 UPDATE dnm_private.login_controls SET
  enabled=next_enabled, state=next_state,
  cutoff_at=CASE WHEN NOT p_active OR (p_active AND NOT c.enabled) THEN now() ELSE cutoff_at END,
  updated_at=now() WHERE profile_id=c.profile_id;
 UPDATE public.dnm_portal_profiles SET active=next_enabled
 WHERE id=c.profile_id AND active IS DISTINCT FROM next_enabled;
 IF NOT p_active THEN UPDATE dnm_private.login_tickets SET phase='used'
  WHERE profile_id=c.profile_id AND phase='issued'; END IF;
END $$;
REVOKE ALL ON FUNCTION dnm_private.sync_worker_login(uuid,boolean) FROM PUBLIC,anon,authenticated;

-- Any employee master active toggle applies to the corresponding managed account, even when using master editor.
CREATE OR REPLACE FUNCTION dnm_private.worker_master_state_trigger() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' AND auth.role() IS DISTINCT FROM 'service_role'
 THEN RAISE EXCEPTION '작업자 사용·중지는 관리자만 변경할 수 있습니다.' USING ERRCODE='42501'; END IF;
 PERFORM dnm_private.sync_worker_login(NEW.id,coalesce((NEW.data->>'active')::boolean,false));
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION dnm_private.worker_master_state_trigger() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS dnm_v48_worker_master_state ON public.dnm_v4_records;
CREATE TRIGGER dnm_v48_worker_master_state AFTER UPDATE OF data ON public.dnm_v4_records
FOR EACH ROW WHEN (NEW.kind='employee' AND (NEW.data->>'active') IS DISTINCT FROM (OLD.data->>'active'))
EXECUTE FUNCTION dnm_private.worker_master_state_trigger();

CREATE OR REPLACE FUNCTION public.dnm_v48_set_worker_active(p_employee uuid,p_active boolean,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e public.dnm_v4_records;
BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION '관리자만 작업자 사용상태를 변경할 수 있습니다.' USING ERRCODE='42501'; END IF;
 IF p_active IS NULL OR length(btrim(coalesce(p_reason,''))) NOT BETWEEN 2 AND 1000 THEN RAISE EXCEPTION '사용·중지와 변경사유를 확인하세요.'; END IF;
 SELECT * INTO e FROM public.dnm_v4_records WHERE id=p_employee AND kind='employee' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '작업자가 등록되어 있지 않습니다.'; END IF;
 UPDATE public.dnm_v4_records SET data=jsonb_set(coalesce(data,'{}'::jsonb),'{active}',to_jsonb(p_active),true)
 WHERE id=e.id AND (data->>'active') IS DISTINCT FROM p_active::text;
 -- Account was previously disabled separately? One master operation also reconciles it.
 PERFORM dnm_private.sync_worker_login(e.id,p_active);
 INSERT INTO public.dnm_portal_audit(actor_id,entity,record_id,action,new_value)
 VALUES(auth.uid(),'employee_login_state',e.id::text,CASE WHEN p_active THEN 'ENABLE' ELSE 'DISABLE' END,
        jsonb_build_object('active',p_active,'reason',btrim(p_reason)));
 RETURN jsonb_build_object('ok',true,'employee_id',e.id,'active',p_active);
END $$;
REVOKE ALL ON FUNCTION public.dnm_v48_set_worker_active(uuid,boolean,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v48_set_worker_active(uuid,boolean,text) TO authenticated;
-- Reconcile existing worker master flags with existing managed login accounts once on upgrade.
DO $$ DECLARE r record; BEGIN
 FOR r IN
  SELECT e.id,(coalesce((e.data->>'active')::boolean,false)) AS is_active
  FROM public.dnm_v4_records e
  JOIN dnm_private.login_controls c ON c.employee_id=e.id
  JOIN public.dnm_portal_profiles u ON u.id=c.profile_id AND u.role<>'admin'
  WHERE e.kind='employee'
 LOOP PERFORM dnm_private.sync_worker_login(r.id,r.is_active); END LOOP;
END $$;

NOTIFY pgrst,'reload schema';


-- Preserve the currently installed context and all backup/security behavior.
DO $$ BEGIN
 IF to_regprocedure('dnm_private.v49_context_previous()') IS NULL THEN
 ALTER FUNCTION public.dnm_v4_context() RENAME TO v49_context_previous;
 ALTER FUNCTION public.v49_context_previous() SET SCHEMA dnm_private;
 END IF;
 IF to_regprocedure('dnm_private.v49_service_previous(text,jsonb)') IS NULL THEN
 ALTER FUNCTION public.dnm_v43_service(text,jsonb) RENAME TO v49_service_previous;
 ALTER FUNCTION public.v49_service_previous(text,jsonb) SET SCHEMA dnm_private;
 END IF;
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v4_context() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF public.dnm_portal_role() IS NULL THEN RAISE EXCEPTION '사용중지 또는 비밀번호 변경 대기 계정입니다.' USING ERRCODE='42501'; END IF;
 RETURN dnm_private.v49_context_previous() || jsonb_build_object('account_management','4.3.0','worker_management','4.9.0');
END $$;
REVOKE ALL ON FUNCTION dnm_private.v49_context_previous(),dnm_private.v49_service_previous(text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.dnm_v4_context() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v4_context() TO authenticated;

CREATE OR REPLACE FUNCTION public.dnm_v43_service(p_action text,p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_result jsonb; worker public.dnm_v4_records; target uuid;
BEGIN
 -- Hold the employee lock during prepare/finish; a concurrent stop cannot be undone by provisioning.
 IF p_action='prepare' THEN target:=(p->>'employee_id')::uuid;
 ELSIF p_action='finish' THEN SELECT employee_id INTO target FROM dnm_private.login_jobs WHERE id=(p->>'request_id')::uuid;
 END IF;
 IF target IS NOT NULL AND (p_action='finish' OR p->>'action'<>'disable') THEN
 SELECT * INTO worker FROM public.dnm_v4_records WHERE id=target AND kind='employee' FOR UPDATE;
 IF NOT FOUND OR worker.data->>'active' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION '미사용 작업자는 계정을 발급하거나 초기화할 수 없습니다.'; END IF;
 END IF;
 IF p_action='prepare' AND coalesce((p->>'auto_provision')::boolean,false) AND EXISTS(SELECT 1 FROM auth.users u WHERE lower(u.email)=lower(p->>'email') AND u.raw_user_meta_data->>'dnm_employee_id' IS DISTINCT FROM p->>'employee_id') THEN
 RAISE EXCEPTION '기존 인증계정과 내부 ID가 충돌합니다. 기존 계정은 변경하지 않았습니다.'; END IF;
 v_result:=dnm_private.v49_service_previous(p_action,p);
 IF p_action='finish' AND v_result->>'state'='pending' THEN
 UPDATE dnm_private.login_controls SET expires_at='infinity'::timestamptz WHERE profile_id=(v_result->>'profile_id')::uuid AND state='pending';
 v_result:=v_result||jsonb_build_object('expires_at','infinity','message','이름(ID)과 1111로 첫 접속 후 개인 비밀번호를 설정하세요.');
 UPDATE dnm_private.login_jobs j SET result=v_result WHERE j.id=(p->>'request_id')::uuid;
 END IF;
 RETURN v_result;
END $$;


REVOKE ALL ON FUNCTION public.dnm_v43_service(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v43_service(text,jsonb) TO service_role;
CREATE OR REPLACE FUNCTION public.dnm_v49_accounts() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN RETURN public.dnm_v47_accounts()||jsonb_build_object('worker_management','4.9.0'); END $$;
REVOKE ALL ON FUNCTION public.dnm_v49_accounts() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v49_accounts() TO authenticated;

-- One-time conversion requested by the owner. Re-running never reactivates stopped workers.
CREATE TABLE IF NOT EXISTS dnm_private.worker_upgrade_log(version text PRIMARY KEY,applied_at timestamptz NOT NULL DEFAULT now());
REVOKE ALL ON dnm_private.worker_upgrade_log FROM PUBLIC,anon,authenticated;
DO $$ DECLARE saved_role text; saved_claims text; BEGIN
 IF NOT EXISTS(SELECT 1 FROM dnm_private.worker_upgrade_log WHERE version='4.9.0') THEN
 saved_role:=current_setting('request.jwt.claim.role',true); saved_claims:=current_setting('request.jwt.claims',true);
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
 UPDATE public.dnm_v4_records e SET data=e.data||jsonb_build_object('active',true)
 WHERE e.kind='employee' AND e.data->>'active' IS DISTINCT FROM 'true'
 AND NOT EXISTS(SELECT 1 FROM dnm_private.login_controls c JOIN public.dnm_portal_profiles u ON u.id=c.profile_id WHERE c.employee_id=e.id AND u.role='admin');
 PERFORM set_config('request.jwt.claim.role',coalesce(saved_role,''),true);
 PERFORM set_config('request.jwt.claims',coalesce(saved_claims,''),true);
 INSERT INTO dnm_private.worker_upgrade_log(version) VALUES('4.9.0');
 END IF;
END $$;
-- Existing unclaimed credentials remain initial credentials, not an authenticated session.
UPDATE dnm_private.login_controls c SET expires_at='infinity'::timestamptz,enabled=true
WHERE c.state='pending' AND c.code_hash IS NOT NULL AND EXISTS(SELECT 1 FROM public.dnm_v4_records e WHERE e.id=c.employee_id AND e.data->>'active'='true');
UPDATE public.dnm_portal_profiles u SET active=true WHERE EXISTS(SELECT 1 FROM dnm_private.login_controls c WHERE c.profile_id=u.id AND c.enabled AND c.state='pending') AND u.role<>'admin';
CREATE OR REPLACE FUNCTION dnm_private.v49_is_approver(p_user uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.dnm_portal_profiles u JOIN public.dnm_v4_permissions a ON a.profile_id=u.id
 WHERE u.id=p_user AND u.active AND u.role IN('admin','member') AND 'approve'=ANY(a.capabilities)
 AND dnm_private.acl_for(u.id,'purchase','read')
 AND NOT EXISTS(SELECT 1 FROM public.dnm_v4_records e WHERE e.kind='employee' AND e.data->>'profile_id'=u.id::text AND e.data->>'active' IS DISTINCT FROM 'true')
 AND NOT EXISTS(SELECT 1 FROM dnm_private.login_controls c WHERE c.profile_id=u.id AND (NOT c.enabled OR c.state NOT IN('pending','ready'))));
$$;
REVOKE ALL ON FUNCTION dnm_private.v49_is_approver(uuid) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.dnm_v4_context() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE x jsonb; people jsonb;
BEGIN
 IF public.dnm_portal_role() IS NULL THEN RAISE EXCEPTION '사용중지 또는 비밀번호 변경 대기 계정입니다.' USING ERRCODE='42501'; END IF;
 x:=dnm_private.v49_context_previous();
 SELECT coalesce(jsonb_agg(a||jsonb_build_object('approver',dnm_private.v49_is_approver((a->>'id')::uuid))),'[]'::jsonb)
 INTO people FROM jsonb_array_elements(coalesce(x->'people','[]'::jsonb)) a;
 RETURN x||jsonb_build_object('people',people,'account_management','4.3.0','worker_management','4.9.0');
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v49_set_admin_approver(p_user uuid,p_enabled boolean,p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION '관리자만 결재권을 지정할 수 있습니다.' USING ERRCODE='42501'; END IF;
 PERFORM pg_advisory_xact_lock(164040,1);
 IF p_enabled IS NULL OR length(btrim(coalesce(p_reason,'')))<2 THEN RAISE EXCEPTION '변경 사유를 입력하세요.'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.dnm_portal_profiles WHERE id=p_user AND role='admin' AND active) THEN RAISE EXCEPTION '활성 관리자 계정을 선택하세요.'; END IF;
 INSERT INTO public.dnm_v4_permissions(profile_id,capabilities) VALUES(p_user,ARRAY[]::text[]) ON CONFLICT(profile_id) DO NOTHING;
 UPDATE public.dnm_v4_permissions SET capabilities=CASE WHEN p_enabled THEN array_append(array_remove(capabilities,'approve'),'approve') ELSE array_remove(capabilities,'approve') END WHERE profile_id=p_user;
 INSERT INTO public.dnm_portal_audit(actor_id,entity,record_id,action,new_value) VALUES(auth.uid(),'purchase_approver',p_user::text,'SET',jsonb_build_object('enabled',p_enabled,'reason',p_reason));
 RETURN jsonb_build_object('ok',true);
END $$;
REVOKE ALL ON FUNCTION public.dnm_v49_set_admin_approver(uuid,boolean,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v49_set_admin_approver(uuid,boolean,text) TO authenticated;
DO $$ BEGIN
 IF to_regprocedure('dnm_private.v49_command_previous(text,jsonb,uuid)') IS NULL THEN
 ALTER FUNCTION public.dnm_v4_command(text,jsonb,uuid) RENAME TO v49_command_previous;
 ALTER FUNCTION public.v49_command_previous(text,jsonb,uuid) SET SCHEMA dnm_private;
 END IF;
END $$;
CREATE OR REPLACE FUNCTION public.dnm_v4_command(p_action text,p_payload jsonb,p_key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a jsonb; BEGIN
 IF public.dnm_portal_role() IS NULL THEN RAISE EXCEPTION '활성 로그인 계정이 필요합니다.' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(164040,1);
 IF p_action='purchase_submit' THEN
 FOR a IN SELECT value FROM jsonb_array_elements(p_payload->'data'->'approvals') LOOP
 IF NOT dnm_private.v49_is_approver((a->>'user_id')::uuid) THEN RAISE EXCEPTION '현재 사용 중이며 관리자가 지정한 구매 결재자만 선택하세요.'; END IF;
 END LOOP;
 ELSIF p_action='purchase_decide' AND NOT dnm_private.v49_is_approver(auth.uid()) THEN
 RAISE EXCEPTION '구매 결재권이 없거나 사용중지된 계정입니다.' USING ERRCODE='42501';
 END IF;
 RETURN dnm_private.v49_command_previous(p_action,p_payload,p_key);
END $$;
REVOKE ALL ON FUNCTION dnm_private.v49_command_previous(text,jsonb,uuid),public.dnm_v4_command(text,jsonb,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v4_command(text,jsonb,uuid) TO authenticated;
-- A scoped lookup exposes only purchase-relevant fields, not arbitrary master records.
CREATE OR REPLACE FUNCTION public.dnm_v49_purchase_catalog() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE rows jsonb; BEGIN
 IF public.dnm_portal_role() IS NULL OR NOT public.dnm_v42_allowed('purchase','read') THEN RAISE EXCEPTION '구매 조회권한이 필요합니다.' USING ERRCODE='42501'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',e.id,'kind',e.kind,'code',e.code,'title',e.title,'state',e.state,
 'data',jsonb_build_object('item',coalesce(e.data->>'item',e.title),'specification',e.data->>'specification','unit',e.data->>'unit',
 'unit_price',e.data->'unit_price','supplier',e.data->>'supplier','active',e.data->'active','review_required',e.data->'review_required')) ORDER BY e.title,e.code),'[]'::jsonb)
 INTO rows FROM public.dnm_v4_records e WHERE e.kind IN('material_master','catalog');
 RETURN jsonb_build_object('ok',true,'rows',rows);
END $$;
REVOKE ALL ON FUNCTION public.dnm_v49_purchase_catalog() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_v49_purchase_catalog() TO authenticated;

COMMIT;
NOTIFY pgrst,'reload schema';
