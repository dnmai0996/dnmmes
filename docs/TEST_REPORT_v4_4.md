# DNM MES v4.4 검증기록

## 수행한 검사
- JavaScript 문법: 46개 파일 통과.
- Node 단위·정적 테스트: 201개 통과. 네이티브 Node WebCrypto로 AES 암호화/복호화, 오암호·변조, 무결성·정밀수치·페이지분할·권한·서버응답 분기 확인.
- 기존 메뉴 Chromium 가상자료 회귀검사: 217개 통과, pageerror 0개.
- 기존 사용자계정 Chromium 가상자료 회귀검사: 34개 통과, pageerror 0개.
- 백업·복원 Chromium 화면 흐름검사: 38개 통과, pageerror 0개. 관리 브라우저의 URL 실행 제한 때문에 about:blank에서 모의 API와 로컬 AES/PBKDF2 브리지를 사용. 실제 브라우저 원산지/WebCrypto/다운로드 보안정책 검증으로 간주하지 않음.
- 320/360/390/768/1440px 백업·도움말 화면의 페이지 가로 넘침 없음.
- 원본 public/api.js의 로그인 fetch constructor 보존 확인.
- 관리자 9쪽·현장 사용자 5쪽 DOCX/PDF 렌더링 및 시각검수.

## 화면 검사의 실제 범위
비밀번호 확인 불일치, 진행률/커서/버튼중복 차단, 타임스탬프 파일명, 암호화 본문, 잘못된 파일 비밀번호, 안전백업 전 복원차단, 동일 안전파일 재선택, 확인문구, 재로그인 화면, timeout 문구 변환, 도움말 기술설명 접힘 상태. 모의 성공 응답은 실제 DB 삭제/복구 성공을 뜻하지 않음.

## 수행하지 못한 검사
이 컨테이너에 PostgreSQL 서버가 없고 패키지 네트워크가 제한되어 실제 SQL migration·snapshot·restore·RLS 실행 검사는 수행하지 못함. 운영 Supabase 접속, 실제 Netlify Functions 배포, 실제 Auth 비밀번호 재인증, 동시 사용자 백업/복원, 실제 휴대폰과 생산 DB 성능은 미검증.

`tests/sql/integration_v44.sql` 및 GitHub Actions에 임시 PostgreSQL 실행시험을 추가했음. **이 SQL 시험은 아직 로컬에서 실행된 것이 아니며**, Actions 결과를 확인해야 함. 정상·권한차단·변조·50행분할·안전백업누락·시점변경·강제오류시롤백·시점복원·감사이력보존·재로그인·lease만료를 확인하도록 작성.

## 설치 전 게이트
자동검사 통과 + 시험 Supabase에서 실제 DB/Auth/서버함수 검수 + 플랫폼 백업 확보 후 운영 적용. 실패 시 임의 SQL 반복 실행이나 테이블 삭제 금지. 오류와 test output을 담당자에게 제공.
