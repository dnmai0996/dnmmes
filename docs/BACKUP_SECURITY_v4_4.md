# DNM MES v4.4 — 설치·복구 담당자용

## 1. 먼저 확인할 것

이 업데이트는 현재 v4.3(10번 SQL 적용) 이후용입니다. DB 삭제·초기화 스크립트가 아닙니다. 운영 DB 전체 백업 또는 pg_dump와 실제 복구 가능성을 먼저 확인하십시오. 이 개발환경에서는 PostgreSQL/Supabase 실행 검증을 수행하지 못했습니다. GitHub Actions의 임시 PostgreSQL 검사를 통과한 다음, 회사 시험 프로젝트에서 Auth·RLS·실제 데이터로 검수해야 합니다. 성공이라고 미리 표시된 운영검증은 없습니다.

설치 순서: 시험브랜치의 전체 패치 → GitHub Actions 통과 → 시험 DB의 `12_upgrade_v4_4.sql` 적용 및 검수 → 운영 DB에 12 적용 → 같은 Netlify 사이트 배포. `13_verify_v4_4.sql`은 설치상태 조회용입니다. 이전 04/06/08/10을 다시 실행하면 현재 함수와 충돌할 수 있습니다. `public/config.js`는 패키지에 없으며 기존 값을 유지합니다. v4.3에서 사용하던 `DNM_SUPABASE_URL`, `DNM_SUPABASE_SECRET_KEY`를 서버 환경변수로 유지합니다. 비밀키를 공개 파일에 넣지 않습니다.

## 2. 왜 기존 백업을 바꾸었는가

제공된 코드의 기존 `dnm_v4_backup()`은 여러 업무 테이블을 한 응답의 JSON 배열로 집계했습니다. 사용자 화면에서는 statement timeout이 확인되었지만, 실제 DB 실행계획·자료량·부하를 측정하지는 못했습니다. 이번 코드는 전체 JSON 한 번 집계를 중단하고 분할 수집으로 바꾸었습니다. 서버의 전역 시간제한을 해제하지 않습니다.

## 3. 일관된 업무 스냅샷

`dnm_private.v44_gate`와 advisory lock을 이용하여 백업 시작 시 기존 쓰기 완료를 기다립니다. 9개 업무 테이블과 계정 연결 상태 테이블의 statement-level trigger가 변경을 잠시 차단합니다. Auth 비밀번호·세션을 백업에 포함하지 않습니다. 계정 등록/비밀번호 변경이 처리 중이면 캡처를 시작하지 않습니다.

각 step은 50행씩 private 사본에 저장합니다. 백업 준비 중 조회는 가능하나 등록·수정은 안내 후 차단됩니다. step마다 3분의 lease를 갱신합니다. 연결이 장시간 끊기면 미완료 파일은 사용할 수 없고, 만료 후 업무 변경은 다시 허용됩니다. revision이 달라진 상태의 백업은 완료되지 않습니다. 취소 후 재시작하거나 새 백업을 생성합니다.

완성된 사본은 immutable 파일조회 기준이며, 이때 업무 쓰기는 즉시 재개됩니다. 다운로드는 50행/약1.5MB씩 나누어 받습니다. 큰 한 행은 별도 상한 내에서 처리합니다. 파일 내부의 `row_json` 문자열은 PostgreSQL 수치·식별자 정밀도를 유지합니다. 각 행의 SHA-256 및 정렬된 key/hash의 컬렉션 digest를 대조합니다. 파일 생성 시 `captured_at`을 KST로 바꾸어 YYYYMMDD_HHMMSS_KST 접두사를 사용합니다. 파일명에는 중복 방지용 backup ID 8자도 포함합니다.

## 4. 백업·복원 범위

| 컬렉션 | 원본 | 복원 방식 |
|---|---|---|
| profiles | dnm_portal_profiles | 표시이름 복원, 현재 이메일·역할·활성상태 보존 |
| products | dnm_portal_products | 백업시점 전체 교체 |
| partners | dnm_portal_partners | 백업시점 전체 교체 |
| notes | dnm_portal_notes | 백업시점 전체 교체 |
| records | dnm_v4_records | 모든 kind 포함. 백업시점 전체 교체 |
| permissions | dnm_v4_permissions | 업무/전결 권한 복원 |
| module_access | dnm_v42_module_access | 메뉴별 조회·등록·수정·범위 복원 |
| requests | dnm_v4_requests | 백업시점 중복처리 방지기록 복원 |
| audit | dnm_portal_audit | 현재 이력 보존; 빠진 과거 행만 추가 |

`records`에는 기준정보, 원문자료, 수주, Routing·공정, 작업일보, 구매, 입고·반품, 정산, 품질·출하 및 품질문서 대장 등 현재 프로그램이 저장하는 업무 레코드가 모두 포함됩니다. 종류를 화면 필터로 한정하지 않습니다. 첨부문서 대장의 URL·메타데이터와 실제 외부 파일 본문은 다릅니다.

이 백업은 모든 DNM **업무 테이블의 시점복원**이지, Supabase 프로젝트 전체를 신규 프로젝트로 복제하는 재해복구 덤프가 아닙니다. Auth 사용자 자격증명·비밀번호·세션·보안 ticket/hash, 실제 Storage 객체·외부문서, SQL 스키마·코드·Netlify 설정은 제외합니다. 재해복구에는 플랫폼 DB 백업/DB dump + 별도 Storage/외부 파일 + 코드/설정 보관이 필요합니다. Supabase 공식 문서에 따르면 DB 백업은 Storage 객체의 실제 파일 본문을 포함하지 않습니다.

공식 참고:
- https://supabase.com/docs/guides/platform/backups
- https://supabase.com/docs/guides/platform/clone-project
- https://supabase.com/docs/guides/database/postgres/timeouts
- https://www.postgresql.org/docs/current/transaction-iso.html
- https://www.postgresql.org/docs/current/app-pgdump.html

## 5. 암호화 및 저장

다운로드 파일은 AES-256-GCM, PBKDF2-SHA256 250,000회, 랜덤 salt 16byte/IV12byte, AAD DNM-BACKUP-4.4를 사용합니다. 파일 비밀번호는 12~128자이며 서버에 저장하거나 전송하지 않습니다. 개인 비밀번호·관리키를 파일 비밀번호로 재사용하지 않는 것을 권장합니다. 파일 비밀번호 분실 시 해당 파일은 복호화할 수 없습니다. 원본 서버의 백업 사본이 남아 있고 관리자 접근이 가능하면 새 비밀번호로 재다운로드할 수 있습니다.

복원 검사 시 복호화된 업무자료는 현재 프로젝트에 업로드됩니다. HTTPS와 관리자 접근권한이 필요합니다. 서버의 private 스냅샷은 백업 비밀번호로 암호화한 사본이 아니며 DB 관리권한으로 보호됩니다. 서버관리자/서비스키가 침해되면 별도의 위험이 있으므로 키를 보호하고 파일은 회사 승인 저장소에만 보관합니다.

## 6. 복원 보호와 트랜잭션

클라이언트는 원본 백업의 프로젝트 instance_id·backup_id·manifest를 신뢰된 private catalog와 대조합니다. 다른 프로젝트 또는 카탈로그를 잃은 신규 프로젝트에 파일을 임의 적용하지 않습니다. 잘못된/변조/불완전 파일은 stage_verify에서 차단합니다. v4.0~4.3 JSON 내보내기는 복원용 포맷이 아닙니다.

검사 후 최신 현재자료를 safety_for로 연결된 안전백업으로 다시 캡처합니다. 내려받은 동일 암호화 파일을 재선택하여 hash를 대조한 뒤 ack합니다. 관리자의 사유·확인문구·현재 비밀번호 재인증을 서버에서 수행합니다. 다른 origin 요청을 차단하고 재인증 횟수를 제한합니다. service-role 전용 `dnm_v44_restore_apply`는 브라우저 역할이 직접 실행할 수 없습니다.

복원 직전에 safety snapshot revision과 현재 revision이 다르면 중단합니다. 준비된 계정변경이 있어도 차단합니다. 전체 business replacement는 하나의 트랜잭션입니다. 인증·업무 RLS와 trigger를 전역 비활성화하지 않습니다. 지정된 FK만 지연 검사하고, 마지막에 정합성을 확인합니다. DB 오류나 DB statement 취소는 전체 롤백합니다. HTTP 연결 단절이나 브라우저 닫힘은 DB 작업의 취소를 보장하지 않으므로, 결과 미확인 시 반복 요청보다 재로그인 후 내역 확인을 우선합니다. 이미 적용된 stage는 중복 적용하지 않습니다.

Auth와 현재 보안상태를 과거로 돌리지 않습니다. 삭제된 Auth 프로필이 필요한 백업은 먼저 계정 복구 확인이 필요합니다. 백업 이후 만들어진 employee가 없어지는 경우 연결된 일반계정은 보호 목적으로 중지됩니다. 현재 수행 중인 관리자 계정은 유지합니다. 감사이력과 복원 이력은 삭제하지 않습니다. 복원 후에는 모든 기존 세션의 업무 접근을 차단하고 새 로그인을 요구합니다.

## 7. 성능·용량 한계

초기 도입의 수천~수만 행 단위 업무자료를 목표로 합니다. 실제 성능 보장은 없습니다. 클라이언트 평문 백업 100MB 상한, 행 수/입력 크기/요청 제한이 있습니다. 준비·분할 수집은 큰 단일 응답을 피하지만 최종 복원은 원자성을 위해 단일 트랜잭션입니다. 대용량·DB 부하로 복원 제한시간을 넘으면 롤백되며, 담당자가 정비시간에 플랫폼 restore 절차를 선택해야 합니다. 전역 타임아웃 해제는 기본 해법이 아닙니다.

완료 backup·staging 사본은 자동 삭제하지 않습니다. 백업할수록 저장공간이 증가합니다. 초기 운영에서 먼저 충분한 공간을 확인하고, 보관정책은 담당자가 별도로 승인해야 합니다. private 카탈로그를 삭제하면 해당 파일의 앱 복원 검증이 불가능할 수 있습니다. 파일만 보관하고 서버 프로젝트를 지우는 방식으로 운영하지 마세요.

## 8. 필수 검수

시험 DB에서 migration 12 적용 → test user login → 전체 업무 캡처 → 잘못된 자료 추가/수정 → 파일검사 → safety backup 재선택 → 복원 → 원래 값·건수·계정 보안·감사이력 대조. 일반 작업자의 backup RPC/restore RPC 호출 차단을 확인합니다. 안전백업 이후 별도 세션의 수정 시 복원 차단을 확인합니다. DB 실패/timeout 시 현재자료 보존을 확인합니다. Netlify 실제 origin에서 서버 함수와 관리자 재인증을 검수합니다. 회사 직원이 입력 중인 실데이터에 최초 시험하지 않습니다.
