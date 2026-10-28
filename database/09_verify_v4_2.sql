-- Read-only verification after 08_upgrade_v4_2.sql, in Supabase SQL Editor.
-- This file does NOT import data or create/reset users.
SELECT to_regprocedure('public.dnm_v42_import(text,jsonb,jsonb,uuid)') IS NOT NULL AS seed_import_installed,
       to_regprocedure('public.dnm_v42_set_access(uuid,jsonb,boolean,numeric,date,text)') IS NOT NULL AS acl_installed,
       to_regprocedure('public.dnm_v42_create_drafts(jsonb,uuid)') IS NOT NULL AS routing_draft_installed;
SELECT tablename,rowsecurity FROM pg_tables WHERE schemaname='public' AND tablename IN('dnm_v4_records','dnm_v42_module_access','dnm_portal_products','dnm_portal_partners','dnm_portal_notes');
SELECT NOT has_schema_privilege('authenticated','dnm_private','USAGE') AS private_schema_blocked,
       NOT has_function_privilege('authenticated','dnm_private.dnm_v41_command_impl(text,jsonb,uuid)','EXECUTE') AS bypass_command_blocked,
       NOT has_table_privilege('authenticated','public.dnm_v42_module_access','UPDATE') AS direct_acl_update_blocked;
SELECT kind,count(*) AS total_rows,count(*) FILTER(WHERE data->>'seed_origin'='DNM-SOURCES-20261028-v42' OR data->>'seed_bundle' LIKE '%v42%') AS seed_rows,
       count(*) FILTER(WHERE data->>'active'='true') AS active_rows FROM public.dnm_v4_records GROUP BY kind ORDER BY kind;
SELECT (SELECT count(*) FROM public.dnm_portal_products) AS products,
       (SELECT count(*) FROM public.dnm_portal_partners) AS partners,
       (SELECT count(*) FROM public.dnm_v42_module_access) AS module_acl_rows;
