> v4.3 계정 기능은 FEATURE_MATRIX_v4_3.md, TEST_REPORT_v4_3.md 및 UPGRADE_v4_3_KO.txt를 우선 참조하십시오. 아래는 기존 자료/업무 기능 기록입니다.

# DNM Cloud MES v4.2 검증 기록

제작·검토일: 2026-10-28

## 수행한 검사
|항목|결과|범위|
|JavaScript 문법|28 파일 통과|node --check|
|단위·정적 검사|102 tests 통과|기존 기능+권한/메뉴/자료묶음 규칙|
|브라우저 모의 검사|102 checks 통과, pageerror 0|Chromium 내장 메모리 문서+mock API, 1440/360 대표 화면|
|실제 변환자료 검증|12,633개 행/길이/공정/공란/중복 등 조건 통과|DB 실행이 아닌 파일 구조·업무입력 형식 검사|
|원본 Excel 자료|10개 파일 분석|XLSM 매크로 실행 없음|
|검토대장|15개 시트, 요약 COUNTA/COUNTIF 수식 확인|artifact_tool 생성, 요약표 렌더 확인|

## 브라우저 검사 환경 제한
이 작업환경 Chromium은 HTTP URL 탐색이 차단되어 있습니다. 보안정책을 해제하지 않았습니다.
page.set_content와 데이터 URL import map을 이용하고 fetch/storage/crypto를 모의 처리하여 실제 앱 모듈을 실행했습니다.
따라서 실제 HTTP·Netlify CSP·DNS·Supabase 인증·RLS를 검증한 결과가 아닙니다.
관리자 그룹 펼치기/접기, 34개 화면, 권한 대화상자, 실제 PRIVATE 파일 미리보기, 작은 가상자료 등록, 작업자/조회자 메뉴·버튼 차단을 확인했습니다.

## 반드시 별도로 수행할 검사
- PostgreSQL 실제 마이그레이션·함수 컴파일·RLS·RPC 권한·동시저장
- 실제 Supabase 관리자/담당자/작업자/조회전용 계정별 직접 API 차단
- 실제 Netlify와 개인별 로그인, 키/프로젝트 일치, 재배포 후 캐시
- 실제 휴대폰 음성/터치PC/인쇄/TV 갱신
- 운영자료 보존·초기자료 재등록·업무 백업/복원

실제 PostgreSQL 설치가 이 환경에 없으므로 SQL 실행검사는 수행하지 못했습니다.
.github/workflows/verify.yml에 임시 PostgreSQL17 시험을 포함했습니다. 08을 두 번 적용하고 integration_v42.sql을 실행하도록 구성했습니다.
이 통합시험은 아직 실행 결과를 확인하지 못한 시험 코드이며 통과했다고 보고하지 않습니다.

실제 사용자 Supabase/Netlify 계정에 접속하여 변경하지 않았습니다. PRIVATE 데이터를 이미 운영 DB에 등록한 것이 아닙니다.
