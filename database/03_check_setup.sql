-- 01/02 적용 후 실행. 읽기 전용 구성 확인이며 실제 사용자별 통합 테스트는 별도입니다.
SELECT c.relname AS table_name,c.relrowsecurity AS rls_enabled,
  NOT has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE') AS anon_table_access_blocked
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relname IN
('dnm_portal_profiles','dnm_portal_products','dnm_portal_partners','dnm_portal_notes','dnm_portal_audit')
ORDER BY c.relname;
-- 위 결과: 5행, 두 확인 열 모두 true여야 합니다.

SELECT email,role,active FROM public.dnm_portal_profiles WHERE role='admin' AND active=true;
-- 위 결과: 02 단계에서 지정한 관리자가 있어야 합니다.

SELECT tablename,policyname,cmd FROM pg_policies
WHERE schemaname='public' AND tablename IN
('dnm_portal_profiles','dnm_portal_products','dnm_portal_partners','dnm_portal_notes','dnm_portal_audit')
ORDER BY tablename,policyname;
-- 위 결과: 이 버전에서 작성한 정책 11개. DELETE 허용 정책 없음.
