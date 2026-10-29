-- DNM MES v4.7 name login: READ ONLY, safe in SQL Editor.
SELECT count(*) FILTER (WHERE employee_id IS NOT NULL) AS registered_worker_accounts,
       count(*) FILTER (WHERE employee_id IS NOT NULL AND login_id IS NOT NULL) AS worker_names_assigned,
       count(*) FILTER (WHERE enabled AND state='ready' AND employee_id IS NOT NULL AND login_id IS NOT NULL) AS ready_name_logins
FROM dnm_private.login_controls;
SELECT login_id, count(*) AS duplicates FROM dnm_private.login_controls
WHERE login_id IS NOT NULL GROUP BY login_id HAVING count(*)>1;
SELECT to_regprocedure('public.dnm_v47_login_lookup(text)') AS server_name_lookup,
       to_regprocedure('public.dnm_v47_accounts()') AS admin_accounts;
