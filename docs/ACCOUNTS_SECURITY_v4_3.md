# v4.3 계정 처리·보안 설계

## 구성
브라우저 → 동일 출처 Netlify Function `dnm-accounts` → Supabase Auth 관리자 API 및 service_role 전용 RPC.
브라우저는 기존 Publishable key와 본인의 JWT만 사용하며 서버키를 받지 않습니다.
DB의 `dnm_private` 스키마는 anon/authenticated에 노출하지 않습니다.

## 새 계정·초기화
1. 서버에서 JWT를 Auth /user로 검증하고 DNM context의 active/admin 역할 확인.
2. 동일 출처 Origin, JSON 타입·크기, worker UUID·버전·메일·사유·본인확인 검증.
3. 초기화/사용중지는 관리자 현재 비밀번호로 재인증. 재인증용 임시 세션은 로컬 폐기.
4. service-only prepare: SQL에서 관리자 재확인, 현재 작업자 버전, 기존 이메일·중복연결·관리자/자기계정 보호, 처리 잠금, 요청번호 검증.
5. 기존 계정은 즉시 provisioning/disabled 상태로 업무 접근을 막음. 새 Auth 계정은 무작위 강한 암호로 생성.
6. Auth 관리자 호출 성공 후 finish: 기존 프로필·신규 여부·이메일 재검증, 작업자와 연결, 신규만 최소 권한 설정.
7. 초기번호 1111은 scrypt+무작위 salt 해시로 private에 저장, 30분 유효. 로그에는 출력하지 않음.
8. 동일 요청번호 완료 결과는 재사용. 통신이 불명확하면 목록 재조회로 상태 확인. DB와 Auth는 분산 호출이므로 완전한 단일 트랜잭션은 아님.

## 최초 비밀번호 설정
- 이메일/1111은 Auth 로그인으로 전송하지 않음.
- trusted Netlify context.ip로 IP 120회/15분, 이메일 해시 기준 5회/15분 제한.
- 알 수 없는 이메일도 유사한 scrypt 검사 경로를 사용하고 동일 오류 메시지 반환.
- 올바른 임시번호일 때 난수 32바이트 티켓만 발급. 브라우저 메모리에만 보관, DB는 SHA256 해시만 보관.
- 유효기간 min(발급 후5분, 초기번호 만료). 새 티켓 발급 시 이전 티켓 무효화.
- 티켓의 issued → using → used 상태전이. 한 번만 사용. 관리자 초기화 generation이 바뀌면 이전 티켓 거부.
- 새 암호는 문자+숫자12자/UTF8최대72바이트, Auth에 저장. 성공 후 초기 해시 삭제, ready 전환.
- 여기서 업무 토큰을 반환하지 않음. 새 개인암호로 일반 Auth 로그인을 다시 진행.

## 세션·DB 차단
`dnm_v43_session_ok`는 enabled/ready/직원active와 JWT session_id를 확인합니다.
Auth의 실제 session created_at이 계정 cutoff_at 이후여야 합니다. JWT iat만 비교하지 않으므로 오래된 refresh token으로 새 JWT를 얻어도 예전 세션은 차단 대상입니다.
RESTRICTIVE RLS policy를 DNM public 테이블에 추가하고 role/acl/context 및 기존 RPC 권한경로에도 동일 검사를 적용합니다.
아직 관리되지 않은 기존 계정은 기존 정책을 유지합니다. 최초 자체 비밀번호 변경 시부터 해당 세션 통제에 편입합니다.
이전 기기에 이미 표시된 데이터·다운로드한 자료를 원격 삭제하는 기능은 아닙니다.

## 기존 데이터 보호
원본 기준정보·수주·Routing·작업일보 삭제 없음. 직원 profile_id/email 매핑은 trigger에서 보존합니다.
사용중지는 active=false 및 계정제어 disabled로 처리하고 Auth와 업무기록은 보존합니다.
신규만 member + worklogs own(read/create/update), notes own(read). 기존 계정은 role/ACL 보존.
초기 설정 대기 계정을 관리자로 승격하는 변경은 차단합니다.

## 제한·잔여 위험
- 공용1111은 본인 소유 증명의 강한 인증수단이 아닙니다. 당사자 앞에서 발급하고 빠르게 변경해야 합니다.
- 선택적인 정확한 공인IP 허용목록은 초기 설정만 제한하며 일반 로그인 전체의 접근통제는 아닙니다.
- 개인별 초대링크/일회용난수/회사 SSO/MFA를 이번 기능에 추가한 것으로 주장하지 않습니다.
- DB/Auth/Netlify 사이의 지연·실패는 error 또는 pending으로 닫고 수동 확인·재초기화가 필요할 수 있습니다.
- 실제 Supabase의 auth.sessions 구조, 관리자 API, 재인증 정책과 서비스롤 처리 검수 필요.
- DB 세션 확인은 앱의 업무 RLS 범위입니다. 별도 플러그인/Storage 버킷 정책은 별도 검토 필요.
- 계정 이메일 변경, 본인/관리자 분실 암호 복구, 메일 소유 자동검증은 이 작업자 기능의 범위가 아닙니다.

## 참고
https://supabase.com/docs/reference/javascript/auth-admin-createuser
https://supabase.com/docs/reference/javascript/auth-admin-updateuserbyid
https://supabase.com/docs/guides/auth/password-security
https://supabase.com/docs/guides/getting-started/api-keys
https://docs.netlify.com/build/functions/environment-variables/
https://docs.netlify.com/build/functions/api/
