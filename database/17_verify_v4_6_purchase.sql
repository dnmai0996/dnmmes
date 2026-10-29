-- 조회 전용. Supabase SQL Editor에서 실행합니다. 업무자료는 바꾸지 않습니다.
SELECT '구매업무 명령함수' AS 항목, CASE WHEN to_regprocedure('dnm_private.dnm_v46_purchase_impl(text,jsonb,uuid)') IS NOT NULL THEN '설치 확인' ELSE '미설치' END AS 상태
UNION ALL SELECT '중앙 업무명령',CASE WHEN to_regprocedure('public.dnm_v4_command(text,jsonb,uuid)') IS NOT NULL THEN '존재' ELSE '미설치' END
UNION ALL SELECT 'v4.5 설비·작업자 배정',CASE WHEN to_regprocedure('public.dnm_v45_team(text,uuid,jsonb,uuid)') IS NOT NULL THEN '존재' ELSE '미설치' END;
SELECT kind,coalesce(data->>'entry_type','기존방식') AS 지급구분,count(*) AS 건수 FROM public.dnm_v4_records WHERE kind='settlement' GROUP BY kind,coalesce(data->>'entry_type','기존방식');
