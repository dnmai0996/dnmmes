-- Read-only post-install verification; no passwords, keys or personal names returned.
SELECT
 to_regprocedure('public.dnm_v49_accounts()') IS NOT NULL AS worker_accounts_installed,
 to_regprocedure('public.dnm_v49_purchase_catalog()') IS NOT NULL AS purchase_catalog_installed,
 to_regprocedure('dnm_private.v49_is_approver(uuid)') IS NOT NULL AS approver_filter_installed,
 to_regprocedure('dnm_private.v49_context_previous()') IS NOT NULL AS previous_context_preserved,
 to_regprocedure('dnm_private.v49_service_previous(text,jsonb)') IS NOT NULL AS previous_account_service_preserved;
SELECT count(*) AS workers,
 count(*) FILTER(WHERE data->>'active'='true') AS active_workers,
 count(*) FILTER(WHERE nullif(data->>'profile_id','') IS NOT NULL) AS linked_workers
FROM public.dnm_v4_records WHERE kind='employee';
SELECT state,count(*) FROM dnm_private.login_controls GROUP BY state ORDER BY state;
SELECT count(*) AS eligible_approvers FROM public.dnm_portal_profiles WHERE dnm_private.v49_is_approver(id);
SELECT count(*) AS orphan_employee_accounts FROM public.dnm_v4_records e
WHERE e.kind='employee' AND nullif(e.data->>'profile_id','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.dnm_portal_profiles p WHERE p.id::text=e.data->>'profile_id');
