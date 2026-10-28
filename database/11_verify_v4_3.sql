-- Read-only verification. Run in Supabase SQL Editor AFTER migration 10.
SELECT CASE WHEN to_regprocedure('public.dnm_v43_accounts()') IS NOT NULL AND to_regprocedure('public.dnm_v43_service(text,jsonb)') IS NOT NULL THEN 'v4.3 계정 관리 DB 확장 설치 확인' ELSE '10_upgrade_v4_3.sql 적용 필요' END AS status;
SELECT has_function_privilege('anon','public.dnm_v43_service(text,jsonb)','EXECUTE') AS anon_must_be_false,
 has_function_privilege('authenticated','public.dnm_v43_service(text,jsonb)','EXECUTE') AS user_must_be_false,
 has_function_privilege('service_role','public.dnm_v43_service(text,jsonb)','EXECUTE') AS server_must_be_true;
SELECT tablename,policyname,permissive FROM pg_policies WHERE schemaname='public' AND policyname='dnm_v43_session_gate' ORDER BY tablename;
-- No code hashes, password hashes, tickets or tokens are selected here.
SELECT state,count(*) AS account_count FROM dnm_private.login_controls GROUP BY state ORDER BY state;
