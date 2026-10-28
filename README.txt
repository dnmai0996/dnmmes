DNM 클라우드 공통관리판 3.0.0-admin.1

처음 시작: START_HERE.html을 더블클릭하여 01~06 순서대로 적용하세요.
새 폴더에 압축 해제합니다. 기존 D:\DNM\app을 덮어쓰지 않습니다.

1. Supabase 프로젝트 생성 → database/01_schema.sql 전체 실행
2. Authentication / Users에서 관리자 이메일 계정 생성
3. database/02_first_admin.sql의 이메일 한 곳을 수정하고 실행
4. public/config.js의 빈 문자열 두 곳에 Project URL / Publishable key 입력
5. GitHub 저장소 루트에 public, database, netlify.toml 등을 업로드
6. Netlify에서 GitHub 저장소 연결 / Build command 빈칸 / Publish directory public
7. Published 후 실제 Netlify HTTPS 주소를 PC와 휴대폰에서 열어 사용

순수 HTML/CSS/Vanilla JS, 외부 JS 패키지 의존성 없음.
.env, npm start, Node 서버, 내부 DB/서버, 고정 IP, Ollama가 필요하지 않습니다.
package.json과 tests는 개발자 검증용이며 배포용 서버가 아닙니다.
인터넷과 사용자의 실제 Supabase 프로젝트가 필요합니다.

포함: 품목 식별정보, 거래처, 공유메모, 사용자 역할/활성 상태, 변경 이력.
음성 입력: 공유메모에서 지원 브라우저의 SpeechRecognition, 직접 입력 대체.
미포함: 기존 MES 수주엑셀 업로드, Routing/제조·검사 지시, 작업일보,
구매 결재, 기존 MySQL 데이터 이관, MFA/OTP, 비밀번호 분실 복구 흐름, Ollama 연결.

자세한 설치, 오류 해결, 운영 전 확인 범위: START_HERE.html
검증 기록: VERIFICATION.txt
