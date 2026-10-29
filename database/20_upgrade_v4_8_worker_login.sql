-- DNM MES v4.8.0. Additive change; worker master governs employee login use/stop.
-- Run only after scripts 10 (account), 14 (worker), and 18 (name login).
-- No tables, login accounts, worklogs, or historic approvals are deleted.
BEGIN;
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
COMMIT;
NOTIFY pgrst,'reload schema';
