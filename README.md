# DNM Cloud MES v4.0.0

GitHub → Netlify 정적 웹앱 / Supabase Auth + Postgres를 유지하는 구매·생산 통합판입니다.
**먼저 `START_HERE.html` 또는 `docs/UPGRADE_v4_KO.md`를 읽으십시오.**

## 배포 전 핵심
- 기존 v3.0/3.0.1의 **같은 Supabase 프로젝트와 같은 Netlify 프로젝트**를 사용합니다.
- 기존 `public/config.js`는 보존합니다. 실수로 빈 값으로 교체하지 않도록 배포 ZIP에는 이 파일을 넣지 않았습니다.
- 기존 설치에는 `database/04_upgrade_v4.sql`만 추가 적용합니다. 기존 업무자료와 Auth 계정을 삭제하는 명령은 없습니다.
- 새로운 설치만 01_schema.sql → 관리자 계정 생성/02_first_admin.sql → 04_upgrade_v4.sql 순서로 진행합니다.
- 데이터베이스 변경은 운영 백업 후 시험 프로젝트에서 먼저 검증합니다. GitHub Actions의 Postgres 통합검증도 통과한 후 운영에 적용하십시오.
- Netlify Publish directory는 `public`, Build command는 비워둡니다. Node 서버/MySQL/Netlify Blobs는 사용하지 않습니다.
- 서비스 키와 DB 비밀번호는 public/config.js나 GitHub에 넣지 않습니다.

## 통합 범위
`DNM_Cloud_Admin_v3.0`와 `DNM_Login_Patch_3.0.1`의 로그인·연결진단·계정활성화·제품·거래처·공유메모·감사이력을 유지했습니다.
`DNM_rc2_import_message_fix.zip`은 전체 RC2가 아니라 화면/오류처리 패치입니다. 제공된 수주 원본 82열, 검토형 Excel 가져오기, 설비·계측기·공구 목록, 팝업 내 오류 안내와 불확실 결과의 동일요청 재확인 방식을 클라우드에 이식했습니다.
패치에 없는 Routing·실적·구매·검사 등의 서버는 Supabase 업무 함수로 새로 구현했습니다. 미제공된 전체 RC2와의 100% 기능 동일성은 확인하지 못했습니다.

## 업무 메뉴
작업진척 대시보드 / 고객수주 / 수주 원본 / Routing / 나의 작업 / 작업일보 / 구매요청·결재 / 발주·입고 / 정산 / 검사·출하·반품 / 품질문서 / 품목 / 거래처 / 설비 / 계측기 / 작업자 / 설비·작업자 연결 / 공정 템플릿 / 공구·공급업체 / 공유메모 / 사용자 / 업무권한·전결 / 변경이력 / 백업 / 기존 공통현황

## 개발자 점검
```bash
npm run check
npm test
npm run serve
```
별도 npm 패키지 설치는 필요하지 않습니다. Node 22는 개발 점검용이며 서비스 실행에 서버 설치를 요구하지 않습니다.
GitHub Actions는 임시 PostgreSQL 17에서 v3 보존, v4 SQL 재실행, 권한, 핵심 업무흐름을 검증하도록 구성했습니다.
`tests/sql/`은 **시험 DB 전용**입니다. 실제 Supabase에 실행하지 마십시오.

## 검증 상태
문법검사 21개 JS, 단위/정적 검사 47개, 모의 API 브라우저 점검 41개는 통과했습니다.
실제 Supabase/PostgreSQL 실행, 실제 Netlify 배포, 마이크·음성엔진, 동시접속 부하시험은 이 작성환경에서 수행하지 않았습니다.
`docs/TEST_REPORT.md`, `docs/KNOWN_LIMITATIONS.md`를 확인하고 실제 업무 데이터 투입 전 별도 승인시험을 하십시오.

## 자료·보안
첨부 고객·직원·공정·공구 원본은 public에 넣지 않았습니다. 관리자가 자료 가져오기에서 직접 검토 후 등록합니다.
별도 PRIVATE 자료 ZIP은 개발 저장소나 Netlify에 올리지 마십시오. 해당 JSON은 로그인한 앱의 가져오기 화면에서만 선택합니다.
각 페이지 우측 ‘사용방법’ 버튼과 `docs/OPERATING_GUIDE.md`를 사용하십시오.
