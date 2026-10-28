-- READ-ONLY verification. Run after 12_upgrade_v4_4.sql. Does not change or restore business data.
SELECT '업데이트 설치' AS check_name,
 CASE WHEN to_regprocedure('public.dnm_v44_backup_api(text,jsonb)') IS NOT NULL
 AND to_regprocedure('public.dnm_v44_restore_apply(uuid,uuid,uuid,text,text)') IS NOT NULL
 THEN '준비됨' ELSE '설치 확인 필요' END AS result;
SELECT '일반계정 복원 실행 차단' AS check_name,
 CASE WHEN NOT has_function_privilege('authenticated','public.dnm_v44_restore_apply(uuid,uuid,uuid,text,text)','EXECUTE') THEN '정상' ELSE '권한 확인 필요' END AS result;
SELECT '변경차단 연결' AS check_name,count(*) AS table_count FROM pg_trigger
 WHERE tgname='dnm_v44_write_guard' AND NOT tgisinternal;
SELECT '백업자료 구분' AS check_name,count(*) AS collection_count FROM dnm_private.v44_collections();
SELECT '최근 백업 상태' AS check_name,status,count(*) AS count FROM dnm_private.v44_jobs GROUP BY status;
