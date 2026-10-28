# v4.2.1 메뉴 개편 검수기록

기준: 첨부 DNM_Cloud_MES_v4_2.zip. 작성일: 2026-10-28.

## 수행
- `npm run check`: JavaScript 32개 문법 통과.
- `npm test`: 128개 통과. 기존 102개 중 메뉴 구성 정적검사 1개를 새 UI 요구에 맞춰 갱신, 메뉴·권한·작업지시 순수함수 검사 26개 추가.
- Chromium 오프라인 DOM 화면검사: 217개 통과, pageerror 0개.
- 모든 메뉴(37개)의 제목/현재표시/선택 노출/도움말 확인.
- 1280×600의 긴 메뉴와 긴 본문 독립 스크롤, 현재 메뉴 유지 확인.
- 모바일 320/360/390/768에서 메뉴 개폐, 현재 메뉴 노출, backdrop/Esc 닫기, inert 해제, 가로 넘침 확인.
- 작업지시 초안 제외, 상태필터, 타이핑 검색, 품번·납기·공정순 정렬 확인.
- 작업자 메뉴 제한, 조회전용 설비·계측기 수정버튼 차단 확인.
- 기존 모든 SQL, api.js 로그인코드, 업무 controller/service/printing 파일의 바이트 동일성 대조 확인.

## 시험방법과 한계
이 환경의 Chromium 네트워크 탐색 정책으로 HTTP 시험서버 접속이 차단되어, about:blank에 로컬 HTML/CSS를 올리고 소스의 네이티브 ES 모듈을 blob/import map으로 로딩한 오프라인 harness를 사용했습니다. 업무 소스 로직은 변경 없이 시험하되, import 경로/로고만 시험용으로 치환했습니다. sessionStorage/localStorage, fetch 응답은 메모리 모의 객체이며 about:blank의 secure-context 제약 때문에 UUID 함수를 시험용으로 제공했습니다.

따라서 HTTPS·실제 Netlify CSP/네트워크·Supabase Auth/RLS·DB 동시거래는 검증하지 않았습니다. 시각검사도 실제 기기가 아닌 Chromium 가상 viewport입니다. 실제 마이크·인쇄·서버 저장·교정 알림 시험을 수행한 것으로 간주하지 마세요.

자동/브라우저 원본 결과: UNIT_TEST_v4_2_1.txt, BROWSER_TEST_v4_2_1.json.
과거 docs/TEST_REPORT.md 등은 v4.2 당시 기록입니다.

## 구현 참조
W3C WAI 메뉴 현재위치 안내: https://www.w3.org/WAI/tutorials/menus/structure/
선택 메뉴에 aria-current=page 적용. 메뉴 컨테이너의 scrollTop만 변경하여 본문 스크롤과 분리.
