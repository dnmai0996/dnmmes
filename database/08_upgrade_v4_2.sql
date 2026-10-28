-- DNM Cloud MES 4.2.0. Additive upgrade AFTER 06_upgrade_v4_1.sql.
-- Never run 04/06 again after this file: they replace authorization entrypoints.
-- No Auth accounts/passwords or existing business rows are removed.
BEGIN;
DO $$ BEGIN
 IF to_regprocedure('public.dnm_v41_validate_steps(jsonb)') IS NULL THEN RAISE EXCEPTION '먼저 v4.1 SQL(06)을 적용하세요.'; END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS dnm_private;
REVOKE ALL ON SCHEMA dnm_private FROM PUBLIC,anon,authenticated;
CREATE TABLE IF NOT EXISTS public.dnm_v42_module_access (
 profile_id uuid NOT NULL REFERENCES public.dnm_portal_profiles(id),
 module text NOT NULL CHECK(module IN ('dashboard','orders','routing','worklogs','purchase','receipts','settlement','quality','documents','products','materials','employees','processes','equipment','instruments','customers','suppliers','templates','assignments','catalog','notes','archives')),
 can_read boolean NOT NULL DEFAULT false,can_create boolean NOT NULL DEFAULT false,can_update boolean NOT NULL DEFAULT false,
 scope text NOT NULL DEFAULT 'own' CHECK(scope IN('own','all')),version integer NOT NULL DEFAULT 1,
 updated_at timestamptz NOT NULL DEFAULT now(),updated_by uuid,
 PRIMARY KEY(profile_id,module),CHECK(can_read OR (NOT can_create AND NOT can_update))
);
ALTER TABLE public.dnm_v42_module_access ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.dnm_v42_module_access FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.dnm_v42_module_access TO authenticated;
DROP POLICY IF EXISTS dnm_v42_acl_read ON public.dnm_v42_module_access;
CREATE POLICY dnm_v42_acl_read ON public.dnm_v42_module_access FOR SELECT TO authenticated USING(profile_id=auth.uid() OR public.dnm_portal_role()='admin');
DROP TRIGGER IF EXISTS dnm_v42_acl_touch ON public.dnm_v42_module_access;
CREATE TRIGGER dnm_v42_acl_touch BEFORE UPDATE ON public.dnm_v42_module_access FOR EACH ROW EXECUTE FUNCTION public.dnm_portal_touch();
CREATE OR REPLACE FUNCTION dnm_private.acl_for(uid uuid,m text,a text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce((SELECT p.active AND (p.role='admin' OR EXISTS(SELECT 1 FROM public.dnm_v42_module_access v WHERE v.profile_id=p.id AND v.module=m AND v.can_read AND CASE a WHEN 'read' THEN true WHEN 'create' THEN p.role='member' AND v.can_create WHEN 'update' THEN p.role='member' AND v.can_update ELSE false END)) FROM public.dnm_portal_profiles p WHERE p.id=uid),false);
$$;
CREATE OR REPLACE FUNCTION public.dnm_v42_allowed(m text,a text DEFAULT 'read') RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT dnm_private.acl_for(auth.uid(),m,a) $$;
CREATE OR REPLACE FUNCTION public.dnm_v42_scope(m text) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT CASE WHEN public.dnm_portal_role()='admin' THEN 'all' ELSE coalesce((SELECT scope FROM public.dnm_v42_module_access WHERE profile_id=auth.uid() AND module=m),'own') END $$;
CREATE OR REPLACE FUNCTION dnm_private.need(m text,a text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN IF NOT public.dnm_v42_allowed(m,a) THEN RAISE EXCEPTION '권한 없음: % / %',m,a USING ERRCODE='42501';END IF;END $$;
CREATE OR REPLACE FUNCTION dnm_private.kind_module(k text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT CASE k WHEN 'order' THEN 'orders' WHEN 'order_source' THEN 'orders' WHEN 'urgency' THEN 'orders' WHEN 'routing' THEN 'routing' WHEN 'operation' THEN 'routing' WHEN 'worklog' THEN 'worklogs' WHEN 'purchase' THEN 'purchase' WHEN 'receipt' THEN 'receipts' WHEN 'inventory' THEN 'receipts' WHEN 'settlement' THEN 'settlement' WHEN 'quality' THEN 'quality' WHEN 'shipment' THEN 'quality' WHEN 'customer_return' THEN 'quality' WHEN 'material' THEN 'routing' WHEN 'quality_doc' THEN 'documents' WHEN 'equipment' THEN 'equipment' WHEN 'instrument' THEN 'instruments' WHEN 'employee' THEN 'employees' WHEN 'assignment' THEN 'assignments' WHEN 'route_template' THEN 'templates' WHEN 'route_candidate' THEN 'templates' WHEN 'part_detail' THEN 'products' WHEN 'products' THEN 'products' WHEN 'material_master' THEN 'materials' WHEN 'process_master' THEN 'processes' WHEN 'catalog' THEN 'catalog' WHEN 'source_routing' THEN 'archives' WHEN 'flow_reference' THEN 'archives' ELSE '' END;
$$;
-- Seed explicit permissions from existing capabilities once. Never overwrite an assigned ACL.
INSERT INTO public.dnm_v42_module_access(profile_id,module,can_read,can_create,can_update,scope)
SELECT p.id,m,
 CASE WHEN p.role='admin' THEN true WHEN p.role='viewer' THEN m IN('dashboard','orders','routing','worklogs','notes')
 WHEN m='worklogs' THEN 'work'=ANY(coalesce(v.capabilities,ARRAY['work']::text[])) OR 'production'=ANY(v.capabilities)
 WHEN m='notes' THEN true WHEN m IN('dashboard','orders','routing') THEN 'production'=ANY(v.capabilities)
 WHEN m IN('purchase','receipts','settlement') THEN 'purchase'=ANY(v.capabilities) OR (m='purchase' AND 'approve'=ANY(v.capabilities))
 WHEN m IN('quality','documents') THEN 'quality'=ANY(v.capabilities)
 WHEN m IN('products','materials','employees','processes','equipment','instruments','customers','suppliers','templates','assignments','catalog','archives') THEN 'master'=ANY(v.capabilities) OR 'production'=ANY(v.capabilities)
 ELSE false END IS TRUE,
 p.role IN('admin','member') AND (p.role='admin' OR CASE WHEN m='worklogs' THEN 'work'=ANY(coalesce(v.capabilities,ARRAY['work']::text[])) WHEN m='notes' THEN true WHEN m IN('orders','routing') THEN 'production'=ANY(v.capabilities) WHEN m IN('purchase','receipts','settlement') THEN 'purchase'=ANY(v.capabilities) WHEN m IN('quality','documents') THEN 'quality'=ANY(v.capabilities) WHEN m IN('products','materials','employees','processes','equipment','instruments','customers','suppliers','templates','assignments','catalog') THEN 'master'=ANY(v.capabilities) ELSE false END IS TRUE),
 p.role IN('admin','member') AND (p.role='admin' OR CASE WHEN m='worklogs' THEN 'work'=ANY(coalesce(v.capabilities,ARRAY['work']::text[])) OR 'production'=ANY(v.capabilities) WHEN m='notes' THEN true WHEN m IN('orders','routing') THEN 'production'=ANY(v.capabilities) WHEN m IN('purchase','receipts','settlement') THEN 'purchase'=ANY(v.capabilities) WHEN m IN('quality','documents') THEN 'quality'=ANY(v.capabilities) WHEN m IN('products','materials','employees','processes','equipment','instruments','customers','suppliers','templates','assignments','catalog') THEN 'master'=ANY(v.capabilities) ELSE false END IS TRUE),
 CASE WHEN p.role IN('admin','viewer') OR 'production'=ANY(v.capabilities) OR 'master'=ANY(v.capabilities) OR 'quality'=ANY(v.capabilities) OR 'purchase'=ANY(v.capabilities) THEN 'all' ELSE 'own' END
FROM public.dnm_portal_profiles p LEFT JOIN public.dnm_v4_permissions v ON v.profile_id=p.id
CROSS JOIN unnest(ARRAY['dashboard','orders','routing','worklogs','purchase','receipts','settlement','quality','documents','products','materials','employees','processes','equipment','instruments','customers','suppliers','templates','assignments','catalog','notes','archives']::text[]) m
ON CONFLICT(profile_id,module) DO NOTHING;
-- Coarse legacy predicates remain, but fine-grained permission checks run before EVERY command.
CREATE OR REPLACE FUNCTION public.dnm_v4_can(p_cap text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT CASE WHEN public.dnm_portal_role()='admin' THEN true WHEN public.dnm_portal_role()<>'member' OR public.dnm_portal_role() IS NULL THEN false
 WHEN p_cap='approve' THEN EXISTS(SELECT 1 FROM public.dnm_v4_permissions WHERE profile_id=auth.uid() AND 'approve'=ANY(capabilities)) AND public.dnm_v42_allowed('purchase','read')
 ELSE EXISTS(SELECT 1 FROM public.dnm_v42_module_access WHERE profile_id=auth.uid() AND can_read AND (can_create OR can_update) AND module=ANY(CASE p_cap WHEN 'master' THEN ARRAY['products','materials','employees','processes','equipment','instruments','customers','suppliers','templates','assignments','catalog','documents'] WHEN 'production' THEN ARRAY['orders','routing'] WHEN 'purchase' THEN ARRAY['purchase','receipts','settlement'] WHEN 'quality' THEN ARRAY['quality','documents'] WHEN 'work' THEN ARRAY['worklogs'] ELSE ARRAY[]::text[] END)) END;
$$;
-- Own-work support only exposes assigned operation/routing/employee/equipment records.
CREATE OR REPLACE FUNCTION dnm_private.own_record(k text,d jsonb,owner uuid,rid uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(CASE WHEN k='employee' THEN d->>'profile_id'=auth.uid()::text WHEN k IN('worklog','operation') THEN d->>'profile_id'=auth.uid()::text OR d->>'manager_id'=auth.uid()::text
 WHEN k='routing' THEN d->>'manager_id'=auth.uid()::text OR EXISTS(SELECT 1 FROM public.dnm_v4_records o WHERE o.kind='operation' AND o.parent_id=rid AND o.data->>'profile_id'=auth.uid()::text)
 WHEN k='equipment' THEN d->>'manager_id'=auth.uid()::text OR EXISTS(SELECT 1 FROM public.dnm_v4_records o WHERE o.kind='operation' AND o.data->>'equipment_id'=rid::text AND o.data->>'profile_id'=auth.uid()::text)
 WHEN k='purchase' THEN owner=auth.uid() OR EXISTS(SELECT 1 FROM jsonb_array_elements(coalesce(d->'approvals','[]'::jsonb)) a WHERE a->>'user_id'=auth.uid()::text)
 ELSE owner=auth.uid() END,false);
$$;
CREATE OR REPLACE FUNCTION public.dnm_v4_readable(p_kind text,p_data jsonb,p_owner uuid,p_id uuid) RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE m text;BEGIN
 IF public.dnm_portal_role() IS NULL THEN RETURN false;END IF;IF public.dnm_portal_role()='admin' THEN RETURN true;END IF;
 m:=dnm_private.kind_module(p_kind);
 IF m<>'' AND public.dnm_v42_allowed(m,'read') THEN RETURN public.dnm_v42_scope(m)='all' OR dnm_private.own_record(p_kind,p_data,p_owner,p_id);END IF;
 IF p_kind IN('operation','routing','equipment','employee') AND public.dnm_v42_allowed('worklogs','read') THEN RETURN dnm_private.own_record(p_kind,p_data,p_owner,p_id);END IF;
 RETURN false;
END $$;
-- Portal tables also obey the new per-module ACL; a hidden menu alone is not security.
DROP POLICY IF EXISTS dnm_product_read ON public.dnm_portal_products;
CREATE POLICY dnm_product_read ON public.dnm_portal_products FOR SELECT TO authenticated USING(public.dnm_v42_allowed('products','read') AND (public.dnm_v42_scope('products')='all' OR created_by=auth.uid()));
DROP POLICY IF EXISTS dnm_product_add ON public.dnm_portal_products;
CREATE POLICY dnm_product_add ON public.dnm_portal_products FOR INSERT TO authenticated WITH CHECK(public.dnm_v42_allowed('products','create') AND created_by=auth.uid());
DROP POLICY IF EXISTS dnm_product_edit ON public.dnm_portal_products;
CREATE POLICY dnm_product_edit ON public.dnm_portal_products FOR UPDATE TO authenticated USING(public.dnm_v42_allowed('products','update') AND (public.dnm_v42_scope('products')='all' OR created_by=auth.uid())) WITH CHECK(public.dnm_v42_allowed('products','update') AND (public.dnm_v42_scope('products')='all' OR created_by=auth.uid()));
DROP POLICY IF EXISTS dnm_partner_read ON public.dnm_portal_partners;
CREATE POLICY dnm_partner_read ON public.dnm_portal_partners FOR SELECT TO authenticated USING((category IN('customer','both') AND (public.dnm_v42_allowed('customers','read') AND (public.dnm_v42_scope('customers')='all' OR created_by=auth.uid()))) OR (category IN('supplier','both') AND (public.dnm_v42_allowed('suppliers','read') AND (public.dnm_v42_scope('suppliers')='all' OR created_by=auth.uid()))));
DROP POLICY IF EXISTS dnm_partner_add ON public.dnm_portal_partners;
CREATE POLICY dnm_partner_add ON public.dnm_portal_partners FOR INSERT TO authenticated WITH CHECK(created_by=auth.uid() AND ((category='customer' AND public.dnm_v42_allowed('customers','create')) OR (category='supplier' AND public.dnm_v42_allowed('suppliers','create')) OR (category='both' AND public.dnm_v42_allowed('customers','create') AND public.dnm_v42_allowed('suppliers','create'))));
DROP POLICY IF EXISTS dnm_partner_edit ON public.dnm_portal_partners;
CREATE POLICY dnm_partner_edit ON public.dnm_portal_partners FOR UPDATE TO authenticated USING((category='customer' AND (public.dnm_v42_allowed('customers','update') AND (public.dnm_v42_scope('customers')='all' OR created_by=auth.uid()))) OR (category='supplier' AND (public.dnm_v42_allowed('suppliers','update') AND (public.dnm_v42_scope('suppliers')='all' OR created_by=auth.uid()))) OR (category='both' AND (public.dnm_v42_allowed('customers','update') AND (public.dnm_v42_scope('customers')='all' OR created_by=auth.uid())) AND (public.dnm_v42_allowed('suppliers','update') AND (public.dnm_v42_scope('suppliers')='all' OR created_by=auth.uid())))) WITH CHECK((category='customer' AND (public.dnm_v42_allowed('customers','update') AND (public.dnm_v42_scope('customers')='all' OR created_by=auth.uid()))) OR (category='supplier' AND (public.dnm_v42_allowed('suppliers','update') AND (public.dnm_v42_scope('suppliers')='all' OR created_by=auth.uid()))) OR (category='both' AND (public.dnm_v42_allowed('customers','update') AND (public.dnm_v42_scope('customers')='all' OR created_by=auth.uid())) AND (public.dnm_v42_allowed('suppliers','update') AND (public.dnm_v42_scope('suppliers')='all' OR created_by=auth.uid()))));
DROP POLICY IF EXISTS dnm_note_read ON public.dnm_portal_notes;
CREATE POLICY dnm_note_read ON public.dnm_portal_notes FOR SELECT TO authenticated USING(public.dnm_v42_allowed('notes','read') AND (public.dnm_v42_scope('notes')='all' OR owner_id=auth.uid()));
DROP POLICY IF EXISTS dnm_note_add ON public.dnm_portal_notes;
CREATE POLICY dnm_note_add ON public.dnm_portal_notes FOR INSERT TO authenticated WITH CHECK(public.dnm_v42_allowed('notes','create') AND owner_id=auth.uid());
DROP POLICY IF EXISTS dnm_note_edit ON public.dnm_portal_notes;
CREATE POLICY dnm_note_edit ON public.dnm_portal_notes FOR UPDATE TO authenticated USING(public.dnm_v42_allowed('notes','update') AND (public.dnm_portal_role()='admin' OR owner_id=auth.uid())) WITH CHECK(public.dnm_v42_allowed('notes','update') AND (public.dnm_portal_role()='admin' OR owner_id=auth.uid()));
CREATE OR REPLACE FUNCTION public.dnm_v4_context() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('version','4.2.0','profile',to_jsonb(p),'capabilities',(SELECT coalesce(jsonb_agg(x),'[]'::jsonb) FROM unnest(ARRAY['master','production','purchase','quality','approve','work']) x WHERE public.dnm_v4_can(x)),
 'permissions',coalesce((SELECT jsonb_object_agg(a.module,jsonb_build_object('read',a.can_read,'create',a.can_create,'update',a.can_update,'scope',a.scope,'version',a.version)) FROM public.dnm_v42_module_access a WHERE a.profile_id=p.id),'{}'::jsonb),
 'people',coalesce((SELECT jsonb_agg(jsonb_build_object('id',u.id,'name',u.display_name,'role',u.role,'production',dnm_private.acl_for(u.id,'routing','create') OR dnm_private.acl_for(u.id,'routing','update'),'approver',(u.role='admin' OR (u.role='member' AND 'approve'=ANY(coalesce(z.capabilities,ARRAY[]::text[])))))) FROM public.dnm_portal_profiles u LEFT JOIN public.dnm_v4_permissions z ON z.profile_id=u.id WHERE u.active),'[]'::jsonb)) FROM public.dnm_portal_profiles p WHERE p.id=auth.uid() AND p.active;
$$;
-- Move v4.1 business implementation out of the exposed schema exactly once.
DO $$ BEGIN
 IF to_regprocedure('dnm_private.dnm_v41_command_impl(text,jsonb,uuid)') IS NULL THEN
  ALTER FUNCTION public.dnm_v4_command(text,jsonb,uuid) RENAME TO dnm_v41_command_impl;
  ALTER FUNCTION public.dnm_v41_command_impl(text,jsonb,uuid) SET SCHEMA dnm_private;
 END IF;
END $$;
REVOKE ALL ON FUNCTION dnm_private.dnm_v41_command_impl(text,jsonb,uuid) FROM PUBLIC,anon,authenticated;
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
   WHEN p_action IN('start_work','manual_work','finish_work','confirm_work','cancel_work','ack_urgency') THEN 'worklogs'
   WHEN p_action IN('urgency','order_close') THEN 'orders'
   WHEN p_action IN('purchase_submit','purchase_decide') THEN 'purchase'
   WHEN p_action IN('purchase_order','purchase_receive','purchase_return') THEN 'receipts'
   WHEN p_action IN('settle','paid') THEN 'settlement'
   WHEN p_action IN('quality','ship','customer_return') THEN 'quality' ELSE '' END;
  a:=CASE WHEN p_action IN('save_routing','start_work','manual_work','purchase_submit','purchase_receive','purchase_return','settle','quality','ship','customer_return') THEN 'create' WHEN p_action='purchase_decide' THEN 'read' ELSE 'update' END;
  IF m='' THEN RAISE EXCEPTION '지원하지 않는 업무 요청';END IF;PERFORM dnm_private.need(m,a);
  IF p_action='save_routing' THEN
   PERFORM dnm_private.need('orders','read');PERFORM dnm_private.need('templates','read');
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
CREATE OR REPLACE FUNCTION public.dnm_v42_set_access(p_user uuid,p_acl jsonb,p_approve boolean,p_limit numeric,p_until date,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e jsonb;m text;caps text[]:=ARRAY[]::text[];old public.dnm_v42_module_access;target_role text;BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION '관리자만 권한 지정 가능' USING ERRCODE='42501';END IF;
 PERFORM public.dnm_v4_required(p_reason,'변경사유',1000);SELECT role INTO target_role FROM public.dnm_portal_profiles WHERE id=p_user;IF NOT FOUND THEN RAISE EXCEPTION '사용자 없음';END IF;
 IF target_role='admin' THEN RAISE EXCEPTION '관리자 계정은 전체 권한입니다. 일반 사용자 기본역할 변경 후 지정하세요.';END IF;
 IF jsonb_typeof(p_acl) IS DISTINCT FROM 'array' OR jsonb_array_length(p_acl)<>22 THEN RAISE EXCEPTION '전체 22개 업무권한을 제출하세요.';END IF;
 IF (SELECT count(DISTINCT value->>'module') FROM jsonb_array_elements(p_acl))<>22 THEN RAISE EXCEPTION '중복 업무권한';END IF;
 PERFORM pg_advisory_xact_lock(164040,1);
 FOR e IN SELECT value FROM jsonb_array_elements(p_acl) LOOP
  m:=e->>'module';SELECT * INTO old FROM public.dnm_v42_module_access WHERE profile_id=p_user AND module=m FOR UPDATE;
  IF FOUND AND (e->>'version')::integer IS DISTINCT FROM old.version THEN RAISE EXCEPTION '권한 변경 충돌. 다시 조회하세요.' USING ERRCODE='40001';END IF;
  IF target_role='viewer' AND (coalesce((e->>'create')::boolean,false) OR coalesce((e->>'update')::boolean,false)) THEN RAISE EXCEPTION '조회자 기본역할에는 등록·수정권한을 부여할 수 없습니다.';END IF;
  INSERT INTO public.dnm_v42_module_access(profile_id,module,can_read,can_create,can_update,scope,updated_by) VALUES(p_user,m,coalesce((e->>'read')::boolean,false),coalesce((e->>'create')::boolean,false),coalesce((e->>'update')::boolean,false),coalesce(e->>'scope','own'),auth.uid()) ON CONFLICT(profile_id,module) DO UPDATE SET can_read=excluded.can_read,can_create=excluded.can_create,can_update=excluded.can_update,scope=excluded.scope,updated_by=auth.uid();
 END LOOP;
 IF EXISTS(SELECT 1 FROM public.dnm_v42_module_access WHERE profile_id=p_user AND (can_create OR can_update) AND module IN('products','materials','employees','processes','equipment','instruments','customers','suppliers','templates','assignments','catalog','documents')) THEN caps:=array_append(caps,'master');END IF;
 IF dnm_private.acl_for(p_user,'routing','create') OR dnm_private.acl_for(p_user,'routing','update') OR dnm_private.acl_for(p_user,'orders','create') OR dnm_private.acl_for(p_user,'orders','update') THEN caps:=array_append(caps,'production');END IF;
 IF EXISTS(SELECT 1 FROM public.dnm_v42_module_access WHERE profile_id=p_user AND (can_create OR can_update) AND module IN('purchase','receipts','settlement')) THEN caps:=array_append(caps,'purchase');END IF;
 IF EXISTS(SELECT 1 FROM public.dnm_v42_module_access WHERE profile_id=p_user AND (can_create OR can_update) AND module IN('quality','documents')) THEN caps:=array_append(caps,'quality');END IF;
 IF dnm_private.acl_for(p_user,'worklogs','create') OR dnm_private.acl_for(p_user,'worklogs','update') THEN caps:=array_append(caps,'work');END IF;
 IF p_approve THEN IF target_role<>'member' OR NOT dnm_private.acl_for(p_user,'purchase','read') THEN RAISE EXCEPTION '결재자는 담당자 역할과 구매 조회권한이 필요합니다.';END IF;caps:=array_append(caps,'approve');END IF;
 IF coalesce(p_limit,0)<0 OR (coalesce(p_limit,0)>0 AND (NOT p_approve OR p_until IS NULL)) THEN RAISE EXCEPTION '전결권·한도·기간 확인';END IF;
 INSERT INTO public.dnm_v4_permissions(profile_id,capabilities,delegation_limit,delegation_until) VALUES(p_user,caps,coalesce(p_limit,0),p_until) ON CONFLICT(profile_id) DO UPDATE SET capabilities=excluded.capabilities,delegation_limit=excluded.delegation_limit,delegation_until=excluded.delegation_until,updated_at=now();
 INSERT INTO public.dnm_portal_audit(actor_id,entity,record_id,action,new_value) VALUES(auth.uid(),'dnm_v42_module_access',p_user::text,'ACL_CHANGE',jsonb_build_object('reason',p_reason,'acl',p_acl,'approve',p_approve,'limit',p_limit,'until',p_until));
 RETURN jsonb_build_object('ok',true);
END $$;
-- Additional source archive kinds; not production/quality results.
ALTER TABLE public.dnm_v4_records DROP CONSTRAINT IF EXISTS dnm_v4_records_kind_check;
ALTER TABLE public.dnm_v4_records ADD CONSTRAINT dnm_v4_records_kind_check CHECK(kind IN ('order','order_source','equipment','instrument','catalog','employee','assignment','route_template','routing','operation','worklog','purchase','receipt','inventory','settlement','quality','shipment','customer_return','material','urgency','quality_doc','batch','part_detail','settings','material_master','process_master','route_candidate','flow_reference','source_routing','data_issue'));
CREATE OR REPLACE FUNCTION public.dnm_v42_import(p_bundle text,p_rows jsonb,p_sources jsonb,p_key uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET statement_timeout='25s' AS $$
DECLARE item jsonb;d jsonb;k text;c text;t text;prev public.dnm_v4_requests;r public.dnm_v4_records;n integer:=0;skip integer:=0;cnt integer;h text;result jsonb;warnings jsonb:='[]';BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION '관리자만 기초자료 구축 가능' USING ERRCODE='42501';END IF;
 IF p_key IS NULL OR jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) NOT BETWEEN 1 AND 100 OR octet_length(p_rows::text)>3000000 THEN RAISE EXCEPTION '한 요청 1~100행, 3MB 이내';END IF;
 PERFORM public.dnm_v4_required(p_bundle,'자료묶음번호',150);PERFORM pg_advisory_xact_lock(164040,1);
 h:=md5(p_bundle||p_rows::text||coalesce(p_sources::text,''));SELECT * INTO prev FROM public.dnm_v4_requests WHERE actor_id=auth.uid() AND request_key=p_key;
 IF FOUND THEN IF prev.payload_hash<>h THEN RAISE EXCEPTION '요청번호 재사용 오류';END IF;RETURN prev.result;END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
  k:=item->>'kind';c:=public.dnm_v4_required(item->>'code','코드',400);t:=public.dnm_v4_required(item->>'title','명칭',300);d:=coalesce(item->'data','{}');
  IF k NOT IN('products','partners','employee','equipment','instrument','catalog','material_master','process_master','part_detail','route_template','route_candidate','flow_reference','source_routing','data_issue','order') OR jsonb_typeof(d) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION '허용되지 않는 초기자료 종류: %',k;END IF;
  IF k IN('products','partners') AND (length(c)>100 OR length(t)>200) THEN RAISE EXCEPTION '제품/거래처 코드·명칭 길이 초과';END IF;
  IF k='products' THEN
   INSERT INTO public.dnm_portal_products(code,name,project,unit,active) VALUES(c,t,left(coalesce(d->>'project',''),200),left(coalesce(d->>'unit',''),20),true) ON CONFLICT(code) DO NOTHING;GET DIAGNOSTICS cnt=ROW_COUNT;
  ELSIF k='partners' THEN
   IF coalesce(d->>'category','') NOT IN('customer','supplier','both') THEN RAISE EXCEPTION '거래처 구분 오류';END IF;
   IF EXISTS(SELECT 1 FROM public.dnm_portal_partners WHERE name=t AND code<>c) THEN cnt:=0;warnings:=warnings||jsonb_build_array(c||': 같은 이름의 기존 거래처 존재, 추가하지 않음');
   ELSE INSERT INTO public.dnm_portal_partners(code,name,category,active) VALUES(c,t,d->>'category',true) ON CONFLICT(code) DO NOTHING;GET DIAGNOSTICS cnt=ROW_COUNT;END IF;
  ELSE
   IF k='employee' AND EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='employee' AND title=t AND code<>c) THEN cnt:=0;warnings:=warnings||jsonb_build_array(c||': 같은 이름의 기존 작업자 존재, 중복 생성하지 않음');
   ELSE
    IF k IN('employee','equipment','instrument','catalog','material_master','process_master','route_template','route_candidate') THEN d:=(d-'profile_id'-'manager_id')||jsonb_build_object('active',false,'verified',false,'review_required',true);END IF;
    IF k IN('route_template','route_candidate') THEN PERFORM public.dnm_v41_validate_steps(d->'steps');END IF;
    IF k='employee' THEN d:=jsonb_build_object('department',d->'department','position',d->'position','hired',d->'hired','source_name',d->'source_name','site',d->'site','active',false,'verified',false,'review_required',true,'code_generated',d->'code_generated','snapshot_date',d->'snapshot_date','sources',d->'sources');END IF;
    IF k='order' THEN
     d:=public.dnm_v4_order_valid(d)||jsonb_build_object('import_review_required',true);
     -- The original 82 columns stay separate. They are not remapped to production quantities.
    END IF;
    INSERT INTO public.dnm_v4_records(kind,code,title,state,data) VALUES(k,c,t,CASE WHEN k='order' THEN 'OPEN' WHEN k IN('source_routing','flow_reference','route_candidate') THEN 'REFERENCE' ELSE 'REVIEW' END,d||jsonb_build_object('seed_bundle',p_bundle)) ON CONFLICT(kind,code) DO NOTHING RETURNING * INTO r;
    GET DIAGNOSTICS cnt=ROW_COUNT;
    IF cnt=1 AND k='order' AND jsonb_typeof(d->'source_columns')='array' THEN
     INSERT INTO public.dnm_v4_records(kind,code,title,state,parent_id,data) VALUES('order_source',r.id::text,c,'OPEN',r.id,jsonb_build_object('file',coalesce(p_sources->'O'->>'file','자료묶음'),'sheet','Sheet1','columns',d->'source_columns','values',d->'source_values','review_reason','첨부 원본 변환자료 / 운영 전 확인')) ON CONFLICT(kind,code) DO NOTHING;
    END IF;
   END IF;
  END IF;
  n:=n+cnt;skip:=skip+1-cnt;
 END LOOP;
 result:=jsonb_build_object('ok',true,'inserted',n,'skipped',skip,'warnings',warnings);
 INSERT INTO public.dnm_v4_requests(actor_id,request_key,action,payload_hash,result) VALUES(auth.uid(),p_key,'v42_import',h,result);
 INSERT INTO public.dnm_portal_audit(actor_id,entity,record_id,action,new_value) VALUES(auth.uid(),'dnm_v42_seed',p_bundle,'IMPORT_CHUNK',result||jsonb_build_object('sources',p_sources));
 RETURN result;
END $$;
-- Review/activation is explicit. Account creation and automatic production approvals are NOT part of import.
CREATE OR REPLACE FUNCTION public.dnm_v42_activate(p_rows jsonb,p_reason text,p_unit text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e jsonb;r public.dnm_v4_records;d jsonb;n integer:=0;BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION '관리자만 일괄확정 가능' USING ERRCODE='42501';END IF;
 PERFORM public.dnm_v4_required(p_reason,'검토사유',1000);IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION '1~200행 선택';END IF;PERFORM pg_advisory_xact_lock(164040,1);
 FOR e IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
  SELECT * INTO r FROM public.dnm_v4_records WHERE id=(e->>'id')::uuid FOR UPDATE;
  IF NOT FOUND OR r.version IS DISTINCT FROM (e->>'version')::integer THEN RAISE EXCEPTION '자료 변경 충돌. 다시 조회하세요.' USING ERRCODE='40001';END IF;
  IF r.kind NOT IN('employee','equipment','instrument','process_master','material_master','catalog','route_template') THEN RAISE EXCEPTION '확정할 수 없는 자료 종류';END IF;d:=r.data;
  IF r.kind='instrument' AND d->>'code_generated'='true' THEN RAISE EXCEPTION '개별 관리번호가 없는 계측기 묶음은 개별 등록 후 사용하세요.';END IF;
  IF r.kind IN('catalog','material_master') AND coalesce(d->>'unit','')='' THEN IF coalesce(p_unit,'')='' THEN RAISE EXCEPTION '단위를 직접 선택/입력하세요.';END IF;d:=d||jsonb_build_object('unit',public.dnm_v4_required(p_unit,'단위',20));END IF;
  IF r.kind='route_template' THEN PERFORM public.dnm_v41_validate_steps(d->'steps');END IF;
  PERFORM public.dnm_v4_put(r.kind,r.code,r.title,'OPEN',r.parent_id,d||jsonb_build_object('active',true,'verified',true,'review_required',false,'reviewed_by',auth.uid(),'reviewed_at',now(),'review_reason',p_reason),r.id,r.version);n:=n+1;
 END LOOP;RETURN jsonb_build_object('ok',true,'updated',n);END $$;
CREATE OR REPLACE FUNCTION public.dnm_v42_setup(p_type text,p_rows jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e jsonb;r public.dnm_v4_records;old public.dnm_v4_records;pid uuid;d jsonb;n integer:=0;nm text;BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION '관리자만 일괄연결 가능' USING ERRCODE='42501';END IF;
 PERFORM public.dnm_v4_required(p_reason,'확인사유',1000);IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION '1~100행 선택';END IF;PERFORM pg_advisory_xact_lock(164040,1);
 FOR e IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
  SELECT * INTO r FROM public.dnm_v4_records WHERE id=(e->>'id')::uuid FOR UPDATE;IF NOT FOUND OR r.version IS DISTINCT FROM (e->>'version')::integer THEN RAISE EXCEPTION '자료 변경 충돌' USING ERRCODE='40001';END IF;
  IF p_type='employee' AND r.kind='employee' THEN
   pid:=nullif(e->>'profile_id','')::uuid;IF pid IS NULL OR NOT EXISTS(SELECT 1 FROM public.dnm_portal_profiles WHERE id=pid AND active) THEN RAISE EXCEPTION '활성 로그인 계정을 선택하세요.';END IF;
   IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='employee' AND id<>r.id AND data->>'profile_id'=pid::text) THEN RAISE EXCEPTION '이미 다른 작업자와 연결된 로그인 계정';END IF;
   d:=r.data||jsonb_build_object('profile_id',pid,'active',true,'verified',true,'review_required',false,'review_reason',p_reason);
   PERFORM public.dnm_v4_put(r.kind,r.code,r.title,'OPEN',r.parent_id,d,r.id,r.version);
  ELSIF p_type='equipment' AND r.kind='equipment' THEN
   pid:=nullif(e->>'manager_id','')::uuid;IF pid IS NULL OR NOT (dnm_private.acl_for(pid,'routing','create') OR dnm_private.acl_for(pid,'routing','update')) THEN RAISE EXCEPTION '생산 Routing 등록/수정권한이 있는 관리자를 선택하세요.';END IF;
   d:=r.data||jsonb_build_object('manager_id',pid,'active',true,'verified',true,'review_required',false,'review_reason',p_reason);
   PERFORM public.dnm_v4_put(r.kind,r.code,r.title,'OPEN',r.parent_id,d,r.id,r.version);
  ELSIF p_type='assignment' AND r.kind='equipment' THEN
   SELECT * INTO old FROM public.dnm_v4_records WHERE id=(e->>'employee_id')::uuid AND kind='employee' AND data->>'active'='true';IF NOT FOUND OR r.data->>'active' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION '활성 설비/작업자만 연결 가능';END IF;
   IF NOT dnm_private.acl_for(nullif(old.data->>'profile_id','')::uuid,'worklogs','create') THEN RAISE EXCEPTION '작업자에게 작업실적 등록권한을 먼저 부여하세요.';END IF;
   IF jsonb_typeof(e->'processes') IS DISTINCT FROM 'array' OR jsonb_array_length(e->'processes')<1 THEN RAISE EXCEPTION '가능 공정을 선택하세요.';END IF;
   nm:=r.code||'/'||old.code;d:=jsonb_build_object('equipment_id',r.id,'employee_id',old.id,'processes',e->'processes','active',true,'review_reason',p_reason);
   SELECT * INTO old FROM public.dnm_v4_records WHERE kind='assignment' AND code=nm;
   PERFORM public.dnm_v4_put('assignment',nm,r.title,'OPEN',NULL,d,old.id,old.version);
  ELSE RAISE EXCEPTION '연결 종류 오류';END IF;n:=n+1;
 END LOOP;RETURN jsonb_build_object('ok',true,'updated',n);END $$;
-- Reuse ONLY administrator-confirmed master assignments; never invent a person from blank source columns.
-- A unique equipment/employee pair must match a source equipment candidate and exact process name.
-- Result remains an unreleased draft and release validates the assignment again.
CREATE OR REPLACE FUNCTION dnm_private.fill_confirmed_assignments(p_steps jsonb,p_manager uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE st jsonb;outsteps jsonb:='[]';pairs jsonb;chosen jsonb;BEGIN
 FOR st IN SELECT value FROM jsonb_array_elements(p_steps) LOOP
  IF st->>'kind'='WORK' AND coalesce(st->>'equipment_id','')='' AND coalesce(st->>'employee_id','')='' AND jsonb_typeof(st->'equipment_candidates')='array' THEN
   SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb) INTO pairs FROM (
    SELECT DISTINCT eq.id AS equipment_id,em.id AS employee_id
    FROM public.dnm_v4_records eq
    JOIN public.dnm_v4_records mp ON mp.kind='assignment' AND mp.data->>'active'='true' AND mp.data->>'equipment_id'=eq.id::text
    JOIN public.dnm_v4_records em ON em.kind='employee' AND em.id::text=mp.data->>'employee_id' AND em.data->>'active'='true'
    WHERE eq.kind='equipment' AND eq.data->>'active'='true' AND eq.data->>'manager_id'=p_manager::text
      AND upper(replace(eq.code,'-','')) IN (SELECT upper(replace(value,'-','')) FROM jsonb_array_elements_text(st->'equipment_candidates'))
      AND mp.data->'processes' ? (st->>'name')
      AND dnm_private.acl_for(nullif(em.data->>'profile_id','')::uuid,'worklogs','create')
   ) q;
   IF jsonb_array_length(pairs)=1 THEN chosen:=pairs->0;st:=st||chosen||jsonb_build_object('assignment_origin','unique_confirmed_master');END IF;
  END IF;
  outsteps:=outsteps||jsonb_build_array(st);
 END LOOP;RETURN outsteps;END $$;
-- Create only un-released drafts; never infer workers or create historical production performance.
CREATE OR REPLACE FUNCTION public.dnm_v42_create_drafts(p_orders jsonb,p_manager uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e jsonb;o public.dnm_v4_records;tpl public.dnm_v4_records;res jsonb;outrows jsonb:='[]';BEGIN
 PERFORM dnm_private.need('routing','create');PERFORM dnm_private.need('orders','read');PERFORM dnm_private.need('templates','read');
 IF jsonb_typeof(p_orders) IS DISTINCT FROM 'array' OR jsonb_array_length(p_orders) NOT BETWEEN 1 AND 30 THEN RAISE EXCEPTION '1~30개 수주 선택';END IF;PERFORM pg_advisory_xact_lock(164040,1);
 FOR e IN SELECT value FROM jsonb_array_elements(p_orders) LOOP
  SELECT * INTO o FROM public.dnm_v4_records WHERE id=(e->>'id')::uuid AND kind='order' AND state='OPEN';
  IF NOT FOUND OR o.version IS DISTINCT FROM (e->>'version')::integer THEN RAISE EXCEPTION '수주 변경 충돌';END IF;
  IF NOT public.dnm_v4_readable(o.kind,o.data,o.created_by,o.id) THEN RAISE EXCEPTION '조회 불가 수주' USING ERRCODE='42501';END IF;
  IF EXISTS(SELECT 1 FROM public.dnm_v4_records WHERE kind='routing' AND parent_id=o.id AND state IN('DRAFT','RELEASED','DONE')) THEN outrows:=outrows||jsonb_build_array(jsonb_build_object('order',o.code,'status','기존 Routing 보존'));CONTINUE;END IF;
  SELECT * INTO tpl FROM public.dnm_v4_records WHERE kind='route_template' AND code=o.data->>'part_no' AND data->>'verified'='true' AND data->>'active'='true' AND data->>'review_required'='false';
  IF NOT FOUND THEN outrows:=outrows||jsonb_build_array(jsonb_build_object('order',o.code,'status','품번별 Routing 검토 필요'));CONTINUE;END IF;
  res:=dnm_private.dnm_v41_command_impl('save_routing',jsonb_build_object('order_id',o.id,'order_version',o.version,'template_id',tpl.id,'template_version',tpl.version,'manager_id',p_manager,'steps',dnm_private.fill_confirmed_assignments(tpl.data->'steps',p_manager),'lot','','serials','','project',o.data->>'project','part_revision',coalesce(tpl.data->>'rev',''),'note','기준정보 자동연결 초안 / 배정·LOT 확인 후 배포'),gen_random_uuid());
  outrows:=outrows||jsonb_build_array(jsonb_build_object('order',o.code,'status','초안 생성','id',res->'id'));
 END LOOP;RETURN jsonb_build_object('ok',true,'rows',outrows);END $$;
-- Backups include the newly added module ACL.
DO $$ BEGIN IF to_regprocedure('dnm_private.dnm_v41_backup_impl()') IS NULL THEN ALTER FUNCTION public.dnm_v4_backup() RENAME TO dnm_v41_backup_impl;ALTER FUNCTION public.dnm_v41_backup_impl() SET SCHEMA dnm_private;END IF;END $$;
REVOKE ALL ON FUNCTION dnm_private.dnm_v41_backup_impl() FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.dnm_v4_backup() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN
 IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION '관리자 전용' USING ERRCODE='42501';END IF;
 RETURN dnm_private.dnm_v41_backup_impl()||jsonb_build_object('format','dnm-cloud-business-v42','module_access',coalesce((SELECT jsonb_agg(to_jsonb(a)) FROM public.dnm_v42_module_access a),'[]'::jsonb));END $$;
DO $$ DECLARE f record;BEGIN
 FOR f IN SELECT oid::regprocedure sig FROM pg_proc WHERE pronamespace='dnm_private'::regnamespace LOOP EXECUTE 'REVOKE ALL ON FUNCTION '||f.sig||' FROM PUBLIC,anon,authenticated';END LOOP;
 FOR f IN SELECT oid::regprocedure sig FROM pg_proc WHERE pronamespace='public'::regnamespace AND (proname LIKE 'dnm_v42_%' OR proname IN('dnm_v4_command','dnm_v4_context','dnm_v4_backup','dnm_v4_can','dnm_v4_readable')) LOOP EXECUTE 'REVOKE ALL ON FUNCTION '||f.sig||' FROM PUBLIC,anon,authenticated';END LOOP;
END $$;
GRANT EXECUTE ON FUNCTION public.dnm_v42_allowed(text,text),public.dnm_v42_scope(text),public.dnm_v4_can(text),public.dnm_v4_readable(text,jsonb,uuid,uuid),public.dnm_v4_context(),public.dnm_v4_command(text,jsonb,uuid),public.dnm_v4_backup(),public.dnm_v42_set_access(uuid,jsonb,boolean,numeric,date,text),public.dnm_v42_import(text,jsonb,jsonb,uuid),public.dnm_v42_activate(jsonb,text,text),public.dnm_v42_setup(text,jsonb,text),public.dnm_v42_create_drafts(jsonb,uuid) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
