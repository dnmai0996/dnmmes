-- READ ONLY. Confirm after applying database/14_upgrade_v4_5.sql.
SELECT name, present FROM (
 VALUES
 ('v4.5 parallel-worker validation',to_regprocedure('public.dnm_v45_team(text,uuid,jsonb,uuid)') IS NOT NULL),
 ('v4.5 bulk active records',to_regprocedure('public.dnm_v45_bulk_state(text,jsonb,boolean,text)') IS NOT NULL),
 ('workflow command',to_regprocedure('public.dnm_v4_command(text,jsonb,uuid)') IS NOT NULL),
 ('v4.4 backup preserved',to_regprocedure('public.dnm_v44_backup_api(text,jsonb)') IS NOT NULL)
) AS t(name,present);
SELECT kind,count(*) AS total,
       count(*) FILTER (WHERE data->>'active'='true') AS active_rows,
       count(*) FILTER (WHERE data->>'active' IS DISTINCT FROM 'true') AS inactive_rows
FROM public.dnm_v4_records
WHERE kind IN ('equipment','employee','catalog','material_master')
GROUP BY kind ORDER BY kind;
