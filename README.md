# DNM Cloud MES v4.3.0

## 이번 변경
기존 v4.2.1(GitHub·Netlify·Supabase)에 관리자용 작업자 계정 등록/초기화/사용중지와 최초 비밀번호 설정을 추가합니다.
직원은 Supabase 대시보드에 들어가지 않고 DNM 앱에서만 로그인합니다. 인증 저장소는 기존 Supabase Auth를 유지합니다.

**현재 v4.2.1 설치라면 `UPGRADE_v4_3_KO.txt`부터 읽으십시오.**

## 반드시 필요한 설치 3가지
1. `database/10_upgrade_v4_3.sql` 적용(08 적용 이후). `11_verify_v4_3.sql`로 확인.
2. Netlify Functions 환경변수 `DNM_SUPABASE_URL`, `DNM_SUPABASE_SECRET_KEY` 설정.
3. `public/`, `server/`, `netlify/functions/`, `netlify.toml` 등 변경파일 전체를 GitHub로 배포.

`public/config.js`는 기존 파일을 보존하십시오. ZIP에는 실제 설정·개인자료·관리자 비밀키가 없습니다.
10 적용 후 이전 04/06/08 SQL을 재실행하지 마십시오. 기존 직원·기준정보를 다시 가져올 필요가 없습니다.

## 이용 흐름
관리자 → 초기구축·운영 → 사용자 등록·초기화 → 작업자의 로그인 사용자 체크 → 본인 이메일 등록.
직원 → 이메일/1111 → 개인 비밀번호 설정 → 이메일/개인 비밀번호로 업무 로그인.
1111은 30분 동안 비밀번호 설정에만 쓰는 초기번호이고, Supabase의 실제 로그인 비밀번호가 아닙니다.
설정화면은 최대 5분이며 업무 접근은 차단합니다. 관리자 현장확인과 이메일 소유 확인이 필요합니다.
본인 비밀번호는 문자+숫자 포함 12자 이상 / UTF-8 72바이트 이하입니다.
로그인 후 상단 ‘비밀번호 변경’으로 현재 비밀번호를 확인하고 변경할 수 있습니다.

## 권한과 보호
기존 사용자 권한·작업이력 보존. 신규 작업자는 본인 작업 조회/등록/수정의 최소 역할로 생성.
초기화/사용중지는 관리자 재인증 필요. 본인·관리자 계정 보호. 작업자 매핑 유지.
초기번호를 안다는 이유만으로 업무용 토큰을 발급하지 않음. 최초 변경/초기화 상태를 DB RLS와 RPC에서 확인.
서버키는 Netlify 환경변수에만 보관. `public/config.js`에는 기존 공개키만 유지.

## 검수 상태
JavaScript 문법검사 37파일, 단위·정적 검사 165건, 모의 Chromium 계정흐름 34건 및 기존 메뉴 217건 통과.
실제 PostgreSQL·Supabase Auth·Netlify Functions 배포는 미검증입니다. `docs/TEST_REPORT_v4_3.md`를 참조하십시오.

## 검수 명령
```sh
npm run check
npm test
```
GitHub Actions는 임시 PostgreSQL 전체 이행·계정제어 회귀검사를 추가 수행합니다. 실제 운영에는 tests/sql을 실행하지 마십시오.

## 자료
- `UPGRADE_v4_3_KO.txt`: 초보자용 설치·운영 순서
- `docs/ACCOUNTS_SECURITY_v4_3.md`: 서버/DB 보안흐름과 위험
- `docs/FEATURE_MATRIX_v4_3.md`: 기능범위
- `docs/TEST_REPORT_v4_3.md`: 실제 수행/미수행 구분
- `docs/KNOWN_LIMITATIONS.md`: 남아 있는 제한사항

하위의 과거 v4 문서는 역사자료입니다. 계정 생성은 이제 Supabase 수동 생성이 아닌 이 문서의 앱 내 절차를 우선 적용합니다.
