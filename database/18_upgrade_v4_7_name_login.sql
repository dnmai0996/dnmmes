-- DNM MES v4.7: Korean worker name is the login ID; Auth email remains private account metadata.
-- Apply AFTER 16_upgrade_v4_6_purchase.sql. Existing users/passwords/permissions/business data unchanged.
-- Service-role-only lookup: unauthenticated browser requests NEVER receive a name-to-email directory.
BEGIN;
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
COMMIT;
NOTIFY pgrst,'reload schema';
