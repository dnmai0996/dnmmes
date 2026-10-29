-- Run first: read-only schema inventory. No data or secret values returned.
SELECT version();
SELECT name,to_regprocedure(name) IS NOT NULL AS installed FROM unnest(ARRAY[
'public.dnm_v42_setup(text,jsonb,text)',
'public.dnm_v42_set_access(uuid,jsonb,boolean,numeric,date,text)',
'public.dnm_v43_accounts()',
'public.dnm_v4_context()',
'public.dnm_v43_service(text,jsonb)',
'public.dnm_v47_accounts()',
'public.dnm_v48_set_worker_active(uuid,boolean,text)',
'public.dnm_v49_accounts()']) AS name;
SELECT kind,count(*) FROM public.dnm_v4_records GROUP BY kind ORDER BY kind;
