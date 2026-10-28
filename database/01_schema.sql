-- DNM 공통관리판 3.0.0-admin.1 / Supabase SQL Editor에서 실행
-- 기존 MES/MySQL과 무관한 새 테이블만 사용합니다. 삭제/초기화 명령 없음.
BEGIN;

CREATE TABLE IF NOT EXISTS public.dnm_portal_profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email text NOT NULL,
  display_name text NOT NULL DEFAULT '',
  role text NOT NULL DEFAULT 'viewer' CHECK (role IN ('admin','member','viewer')),
  active boolean NOT NULL DEFAULT false,
  version integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.dnm_portal_products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE CHECK (length(trim(code)) BETWEEN 1 AND 100),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 200),
  project text NOT NULL DEFAULT '' CHECK (length(project)<=200),
  unit text NOT NULL DEFAULT '' CHECK (length(unit)<=20),
  active boolean NOT NULL DEFAULT true,
  version integer NOT NULL DEFAULT 1,
  created_by uuid DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.dnm_portal_partners (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE CHECK (length(trim(code)) BETWEEN 1 AND 100),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 200),
  category text NOT NULL CHECK (category IN ('customer','supplier','both')),
  contact text NOT NULL DEFAULT '' CHECK (length(contact)<=100),
  phone text NOT NULL DEFAULT '' CHECK (length(phone)<=80),
  active boolean NOT NULL DEFAULT true,
  version integer NOT NULL DEFAULT 1,
  created_by uuid DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.dnm_portal_notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 160),
  body text NOT NULL CHECK (length(trim(body)) BETWEEN 1 AND 10000),
  owner_id uuid NOT NULL DEFAULT auth.uid(),
  version integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.dnm_portal_audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_id uuid,
  entity text NOT NULL,
  record_id text NOT NULL,
  action text NOT NULL,
  old_value jsonb,
  new_value jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS dnm_portal_notes_updated ON public.dnm_portal_notes(updated_at DESC);
CREATE INDEX IF NOT EXISTS dnm_portal_audit_created ON public.dnm_portal_audit(created_at DESC);

ALTER TABLE public.dnm_portal_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dnm_portal_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dnm_portal_partners ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dnm_portal_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dnm_portal_audit ENABLE ROW LEVEL SECURITY;

-- 권한 확인 함수는 SQL 소유자 권한으로 실행하며 search_path를 고정합니다.
CREATE OR REPLACE FUNCTION public.dnm_portal_role() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT role FROM public.dnm_portal_profiles WHERE id = auth.uid() AND active = true;
$$;
REVOKE ALL ON FUNCTION public.dnm_portal_role() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_portal_role() TO authenticated;

CREATE OR REPLACE FUNCTION public.dnm_portal_touch() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  NEW.updated_at := now(); NEW.version := OLD.version + 1;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.dnm_portal_touch() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.dnm_portal_record_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.dnm_portal_audit(actor_id,entity,record_id,action,old_value,new_value)
  VALUES(auth.uid(),TG_TABLE_NAME,NEW.id::text,TG_OP,
    CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) ELSE NULL END,to_jsonb(NEW));
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.dnm_portal_record_change() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.dnm_portal_new_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.dnm_portal_profiles(id,email,display_name)
  VALUES(NEW.id,coalesce(NEW.email,''),left(coalesce(NEW.raw_user_meta_data->>'display_name',split_part(NEW.email,'@',1),''),100))
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.dnm_portal_new_user() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS dnm_portal_auth_user ON auth.users;
CREATE TRIGGER dnm_portal_auth_user AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.dnm_portal_new_user();
INSERT INTO public.dnm_portal_profiles(id,email,display_name)
SELECT id,coalesce(email,''),left(coalesce(raw_user_meta_data->>'display_name',split_part(email,'@',1),''),100)
FROM auth.users ON CONFLICT (id) DO NOTHING;

DROP TRIGGER IF EXISTS dnm_portal_touch ON public.dnm_portal_profiles;
CREATE TRIGGER dnm_portal_touch BEFORE UPDATE ON public.dnm_portal_profiles FOR EACH ROW EXECUTE FUNCTION public.dnm_portal_touch();
DROP TRIGGER IF EXISTS dnm_portal_touch ON public.dnm_portal_products;
CREATE TRIGGER dnm_portal_touch BEFORE UPDATE ON public.dnm_portal_products FOR EACH ROW EXECUTE FUNCTION public.dnm_portal_touch();
DROP TRIGGER IF EXISTS dnm_portal_touch ON public.dnm_portal_partners;
CREATE TRIGGER dnm_portal_touch BEFORE UPDATE ON public.dnm_portal_partners FOR EACH ROW EXECUTE FUNCTION public.dnm_portal_touch();
DROP TRIGGER IF EXISTS dnm_portal_touch ON public.dnm_portal_notes;
CREATE TRIGGER dnm_portal_touch BEFORE UPDATE ON public.dnm_portal_notes FOR EACH ROW EXECUTE FUNCTION public.dnm_portal_touch();
DROP TRIGGER IF EXISTS dnm_portal_audit ON public.dnm_portal_profiles;
CREATE TRIGGER dnm_portal_audit AFTER INSERT OR UPDATE ON public.dnm_portal_profiles FOR EACH ROW EXECUTE FUNCTION public.dnm_portal_record_change();
DROP TRIGGER IF EXISTS dnm_portal_audit ON public.dnm_portal_products;
CREATE TRIGGER dnm_portal_audit AFTER INSERT OR UPDATE ON public.dnm_portal_products FOR EACH ROW EXECUTE FUNCTION public.dnm_portal_record_change();
DROP TRIGGER IF EXISTS dnm_portal_audit ON public.dnm_portal_partners;
CREATE TRIGGER dnm_portal_audit AFTER INSERT OR UPDATE ON public.dnm_portal_partners FOR EACH ROW EXECUTE FUNCTION public.dnm_portal_record_change();
DROP TRIGGER IF EXISTS dnm_portal_audit ON public.dnm_portal_notes;
CREATE TRIGGER dnm_portal_audit AFTER INSERT OR UPDATE ON public.dnm_portal_notes FOR EACH ROW EXECUTE FUNCTION public.dnm_portal_record_change();

CREATE OR REPLACE FUNCTION public.dnm_portal_set_access(p_id uuid,p_version integer,p_name text,p_role text,p_active boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE changed integer;
BEGIN
  IF public.dnm_portal_role() IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION '관리자 권한이 필요합니다.' USING ERRCODE='42501';
  END IF;
  IF p_id = auth.uid() THEN RAISE EXCEPTION '본인 권한은 이 화면에서 변경할 수 없습니다.'; END IF;
  IF p_role IS NULL OR p_role NOT IN ('admin','member','viewer') OR p_active IS NULL
     OR p_name IS NULL OR length(trim(p_name)) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION '성명·역할·활성 상태를 확인하세요.';
  END IF;
  UPDATE public.dnm_portal_profiles SET display_name=trim(p_name),role=p_role,active=p_active
  WHERE id=p_id AND version=p_version;
  GET DIAGNOSTICS changed = ROW_COUNT;
  IF changed <> 1 THEN RAISE EXCEPTION '다른 사용자가 변경했습니다. 다시 조회하세요.'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.dnm_portal_set_access(uuid,integer,text,text,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dnm_portal_set_access(uuid,integer,text,text,boolean) TO authenticated;

REVOKE ALL ON TABLE public.dnm_portal_profiles,public.dnm_portal_products,public.dnm_portal_partners,public.dnm_portal_notes,public.dnm_portal_audit FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.dnm_portal_profiles,public.dnm_portal_products,public.dnm_portal_partners,public.dnm_portal_notes,public.dnm_portal_audit TO authenticated;
GRANT INSERT(code,name,project,unit,active), UPDATE(code,name,project,unit,active) ON public.dnm_portal_products TO authenticated;
GRANT INSERT(code,name,category,contact,phone,active), UPDATE(code,name,category,contact,phone,active) ON public.dnm_portal_partners TO authenticated;
GRANT INSERT(title,body), UPDATE(title,body) ON public.dnm_portal_notes TO authenticated;

DROP POLICY IF EXISTS dnm_profile_read ON public.dnm_portal_profiles;
CREATE POLICY dnm_profile_read ON public.dnm_portal_profiles FOR SELECT TO authenticated
USING (id=(SELECT auth.uid()) OR (SELECT public.dnm_portal_role())='admin');
DROP POLICY IF EXISTS dnm_product_read ON public.dnm_portal_products;
CREATE POLICY dnm_product_read ON public.dnm_portal_products FOR SELECT TO authenticated
USING ((SELECT public.dnm_portal_role()) IN ('admin','member','viewer'));
DROP POLICY IF EXISTS dnm_product_add ON public.dnm_portal_products;
CREATE POLICY dnm_product_add ON public.dnm_portal_products FOR INSERT TO authenticated
WITH CHECK ((SELECT public.dnm_portal_role()) IN ('admin','member'));
DROP POLICY IF EXISTS dnm_product_edit ON public.dnm_portal_products;
CREATE POLICY dnm_product_edit ON public.dnm_portal_products FOR UPDATE TO authenticated
USING ((SELECT public.dnm_portal_role()) IN ('admin','member'))
WITH CHECK ((SELECT public.dnm_portal_role()) IN ('admin','member'));
DROP POLICY IF EXISTS dnm_partner_read ON public.dnm_portal_partners;
CREATE POLICY dnm_partner_read ON public.dnm_portal_partners FOR SELECT TO authenticated
USING ((SELECT public.dnm_portal_role()) IN ('admin','member','viewer'));
DROP POLICY IF EXISTS dnm_partner_add ON public.dnm_portal_partners;
CREATE POLICY dnm_partner_add ON public.dnm_portal_partners FOR INSERT TO authenticated
WITH CHECK ((SELECT public.dnm_portal_role()) IN ('admin','member'));
DROP POLICY IF EXISTS dnm_partner_edit ON public.dnm_portal_partners;
CREATE POLICY dnm_partner_edit ON public.dnm_portal_partners FOR UPDATE TO authenticated
USING ((SELECT public.dnm_portal_role()) IN ('admin','member'))
WITH CHECK ((SELECT public.dnm_portal_role()) IN ('admin','member'));
DROP POLICY IF EXISTS dnm_note_read ON public.dnm_portal_notes;
CREATE POLICY dnm_note_read ON public.dnm_portal_notes FOR SELECT TO authenticated
USING ((SELECT public.dnm_portal_role()) IN ('admin','member','viewer'));
DROP POLICY IF EXISTS dnm_note_add ON public.dnm_portal_notes;
CREATE POLICY dnm_note_add ON public.dnm_portal_notes FOR INSERT TO authenticated
WITH CHECK ((SELECT public.dnm_portal_role()) IN ('admin','member') AND owner_id=(SELECT auth.uid()));
DROP POLICY IF EXISTS dnm_note_edit ON public.dnm_portal_notes;
CREATE POLICY dnm_note_edit ON public.dnm_portal_notes FOR UPDATE TO authenticated
USING ((SELECT public.dnm_portal_role())='admin' OR ((SELECT public.dnm_portal_role())='member' AND owner_id=(SELECT auth.uid())))
WITH CHECK ((SELECT public.dnm_portal_role())='admin' OR ((SELECT public.dnm_portal_role())='member' AND owner_id=(SELECT auth.uid())));
DROP POLICY IF EXISTS dnm_audit_read ON public.dnm_portal_audit;
CREATE POLICY dnm_audit_read ON public.dnm_portal_audit FOR SELECT TO authenticated
USING ((SELECT public.dnm_portal_role())='admin');

NOTIFY pgrst, 'reload schema';
COMMIT;
