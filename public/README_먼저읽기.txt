(주)디엔엠 Cloud MES v4.0.1 로그인/연결 오류 수정 패치
====================================================

대상: 기존 DNM Cloud MES v4.0 (Netlify + Supabase)
변경 파일: public/api.js 1개
변경 안 함: public/config.js / Supabase 프로젝트 / 기존 사용자 및 비밀번호 / 데이터베이스 / 업무 테이블 / Netlify 접근 공개 설정

확인된 프로그램 오류
------------------
기존 코드에서 브라우저 표준 fetch 함수를 PortalApi 인스턴스의 메서드로 호출하여
Chrome에서 `Illegal invocation`이 발생할 수 있음.
프로그램은 실제 원인을 CONNECTION_FAILED로 표시하므로 비밀번호 오류로 오인할 수 있음.

수정 내용
---------
기존: this.fetcher=fetcher;
수정: this.fetcher=(...args)=>fetcher(...args);

수정 후 원래 브라우저 fetch의 올바른 호출 문맥을 유지하며, 기존 모의 API 테스트도 유지함.

적용 순서 (GitHub Desktop)
------------------------
1. 현재 DNM MES 운영 GitHub 저장소를 GitHub Desktop에서 선택하십시오.
   디엔엠 연차관리 저장소(dnmannual)나 SB선보 저장소가 아닙니다.
2. Repository > Show in Explorer 클릭.
3. 프로그램 폴더 안의 public > api.js를 다른 이름으로 백업하십시오.
4. 이 패치 ZIP 안의 public/api.js 파일 한 개로 교체하십시오.
5. GitHub Desktop > Changes 확인 > Summary에 'fix: v4.0.1 Supabase fetch' 입력
   > Commit to main > Push origin 실행.
6. Netlify에서 해당 프로젝트의 Deploys에 새 배포가 Published로 표시되는지 확인하십시오.
7. https://dnmmes.netlify.app/?v=4.0.1 를 새로 열고
   'Supabase 연결 진단 > 연결 확인(비밀번호 불필요)'을 클릭하십시오.
8. '인증 서비스의 공개 설정을 정상 조회했습니다'가 나타나면
   기존 사용자 계정으로 로그인하십시오.

주의사항
--------
- SQL을 다시 실행하거나 Supabase 프로젝트를 재생성하지 마십시오.
- Secret key나 service_role key를 config.js에 넣지 마십시오.
- 이 패치는 통신 코드 문제를 교정하며, 별도 계정 비활성/암호 오류나 정책 오류까지 보장하는 것은 아닙니다.
- Supabase 연결 진단 결과가 여전히 오류면 연결 화면의 오류 문구만 전달하십시오(키/비밀번호 노출 금지).

검증
----
- 원본 api.js: 실제 Chromium에서 native fetch 메서드 호출시 CONNECTION_FAILED 재현
- 교정본 api.js: 동일한 Chromium data JSON fetch 시험 성공
- 기존 Node 자동 테스트: 47/47 통과
- 실제 DNM 운영 Supabase 로그인은 접근 권한이 없어 시험하지 못함.
