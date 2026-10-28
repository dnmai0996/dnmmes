-- Read-only post-migration verification in Supabase SQL Editor.
SELECT '4.0.0' AS expected_version,
 to_regclass('public.dnm_portal_profiles') IS NOT NULL AS v3_profiles_present,
 to_regclass('public.dnm_v4_records') IS NOT NULL AS v4_records_present,
 to_regprocedure('public.dnm_v4_command(text,jsonb,uuid)') IS NOT NULL AS v4_command_present;
SELECT c.relname,c.relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname IN('dnm_v4_records','dnm_v4_permissions','dnm_v4_requests');
SELECT has_table_privilege('authenticated','public.dnm_v4_records','INSERT') AS direct_insert_must_be_false,
 has_table_privilege('authenticated','public.dnm_v4_records','UPDATE') AS direct_update_must_be_false,
 has_function_privilege('anon','public.dnm_v4_command(text,jsonb,uuid)','EXECUTE') AS anon_command_must_be_false,
 has_function_privilege('authenticated','public.dnm_v4_command(text,jsonb,uuid)','EXECUTE') AS authenticated_command_must_be_true;
SELECT 'profiles' AS name,count(*) FROM public.dnm_portal_profiles UNION ALL SELECT 'products',count(*) FROM public.dnm_portal_products UNION ALL SELECT 'partners',count(*) FROM public.dnm_portal_partners UNION ALL SELECT 'notes',count(*) FROM public.dnm_portal_notes;
