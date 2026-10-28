> v4.3 계정 기능은 FEATURE_MATRIX_v4_3.md, TEST_REPORT_v4_3.md 및 UPGRADE_v4_3_KO.txt를 우선 참조하십시오. 아래는 기존 자료/업무 기능 기록입니다.

# v4.2.1 추가 변경

메뉴 개편 / 설비·계측관리 분리 / 배포 작업지시 조회 / 메뉴 자동 노출 / 현재 위치 표시. DB·권한 원장 변경 없음. 자세한 내용은 UPGRADE_v4_2_1_KO.txt 참조.

---

# v4.2 변경 범위

v4.1 전체 기능 위에 아래를 추가했습니다. 미제공 원본 RC2 전체와 완전히 동일하다는 의미는 아닙니다.

|요청|구현 위치|확인|
|문서에서 기준정보 구축|별도 PRIVATE bundle + dnm_v42_import|실제원문 추출/형식검증; 운영DB 미등록|
|기존자료 보존|import ON CONFLICT DO NOTHING, 동일명경고|정적검사; DB통합시험 포함|
|Routing 준비|후보/템플릿검토+create_drafts|미배포 초안, 검토된 유일 배정만 연결|
|작업일보 준비|workCards + 기존 현장입력|지시값 사전작성, 실제시각/수량은 비움|
|왼쪽 그룹메뉴|permissions.js GROUPS + app.js|4그룹/접기/전체펼침/모바일 점검|
|사용자별 메뉴|22개 module ACL|읽기 허용 메뉴만 렌더링|
|조회·등록 분리|read/create/update + scope|UI와 RPC/RLS 모두 반영, 실제DB검수 필요|
|권한 임의우회 방지|dnm_private 원명령 격리|PUBLIC/anon/auth 실행권한 제거|
|기존 로그인|api.js v4.0.2 constructor|보존·단위검사|
|소스 키|config.js 미포함|기존값 보존|
|GitHub-Netlify-Supabase|기존 정적배포+DB RPC|유지|
|로컬 STT/Ollama|이번 범위 아님|브라우저 음성 유지|
|과거실적 자동생성|수행하지 않음|과거 2875행 참조만|
