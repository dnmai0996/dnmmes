-- Read-only install checks. Does not register data or change users.
SELECT now() AS checked_at,
 to_regclass('public.dnm_v4_records') IS NOT NULL AS business_table_exists,
 to_regprocedure('public.dnm_v41_sync_routing(uuid)') IS NOT NULL AS routing_state_helper_exists,
 to_regprocedure('public.dnm_v41_assignment(text,uuid,uuid)') IS NOT NULL AS assignment_guard_exists;
SELECT proname, position('4.1.0' in pg_get_functiondef(oid))>0 AS contains_v41_version
 FROM pg_proc WHERE oid=to_regprocedure('public.dnm_v4_context()');
SELECT relname,relrowsecurity FROM pg_class WHERE oid IN(to_regclass('public.dnm_v4_records'),to_regclass('public.dnm_portal_products'),to_regclass('public.dnm_portal_partners'));
SELECT kind,count(*) AS rows FROM public.dnm_v4_records GROUP BY kind ORDER BY kind;
