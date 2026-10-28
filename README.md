# DNM Cloud MES v4.2

GitHub → Netlify(public) → Supabase. v4.0.2 fetch constructor fix preserved.

**기존 public/config.js를 보존하세요.** 이 패키지는 실제 고객 DB에 접속하여 설치한 결과가 아닙니다.

1. `UPGRADE_v4_2_KO.txt` 확인.
2. 코드/DB/config 백업 및 시험브랜치 검사.
3. v4.1/06 이후 `database/08_upgrade_v4_2.sql` 적용. 08 이후 04/06 재실행 금지.
4. 같은 Netlify 사이트에서 관리자 로그인.
5. 별도 PRIVATE JSON을 첨부자료 일괄등록 화면에서 선택. PRIVATE 파일은 GitHub/public에 올리지 않음.
6. 원본 검토 → 권한 → 계정·설비 연결 → Routing 초안 → 배포 → 실제 작업입력.

## 이번 변경
- 문서 기반 master/source/template 일괄등록(100행씩), 기존코드 보존, 재시도 중복방지
- 네 가지 접이식 메뉴 + 본인 권한 내 전체펼치기
- 사용자별 22업무 조회/등록/수정 + 본인/담당·전체 범위
- DB/RPC/RLS 권한검사, 기존 직접명령 private 스키마로 격리
- 작업자계정·설비관리자·가능공정 일괄연결
- 원문 Routing 후보·과거 참조·원본출처 관리
- 검토완료 템플릿에서 주문별 미배포 초안·빈 작업일보 양식 준비

## 검증
`npm run check`, `npm test`. `.github/workflows/verify.yml`는 가상 PostgreSQL 검사 포함.
실제 SQL/Supabase와 실제 휴대폰은 아직 검증하지 않았음. 자세한 결과 `docs/TEST_REPORT.md`.

## 디렉터리
- public: 정적앱. config.js는 현재 파일 유지
- database: 01~09 설치/확장/검증
- docs: 운영·업그레이드·기능·한계·검증
- tests: 단위검사 및 가상 PostgreSQL 시나리오

기존 연차관리, SB선보 챗봇과 다른 저장소입니다. 실제 운영자료를 시험자료로 삭제하지 마세요.
