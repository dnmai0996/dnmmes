# DNM Cloud MES v4.1.0

수주 12항목 Excel 업로드 → 품번별 제품 Routing → 주문별 공정·설비·작업자 배정/출력 → 터치/음성 실적 → TV 진척 → Routing 종료.

## 기존 v4.0~v4.0.2에서 업그레이드
1. 기존 코드/config.js/복구 가능한 Supabase DB 백업.
2. 시험 브랜치에서 전체 파일 교체. **기존 public/config.js를 보존**.
3. GitHub Actions와 시험 DB 검수 후 **database/06_upgrade_v4_1.sql** 적용.
4. 같은 Netlify 사이트의 publish=public에 배포. 기존 계정으로 로그인.
5. 기준정보·계정연결·제품 Routing 검토 → 시험수주부터 실증.

**DB 마이그레이션 실행 검증은 이 제작 환경에서 미실시입니다.** 화면 시험은 모의 API 기준이며 실제 Supabase 성공으로 주장하지 않습니다.

- [업그레이드 상세](UPGRADE_v4_1_KO.txt)
- [변경 범위](docs/FEATURE_MATRIX.md)
- [시험 결과](docs/TEST_REPORT.md)
- [제약과 미검증 항목](docs/KNOWN_LIMITATIONS.md)

## 파일과 구조
public/index.html / api.js(로그인4.0.2수정 유지) / modules/v41.js / v41.css
DB: 기존 v3·v4 테이블 유지, 신규 마스터종류·Routing/실적처리함수 추가.
06 적용 후 04를 재실행하지 마십시오. 새 프로젝트 초기설정은 별도 시험환경에서 01→04→06 순서.
운영자료·Auth 암호·Secret key·원본자료를 GitHub/public에 넣지 마십시오.

## 개발 확인
```sh
npm run check
npm test
npm run serve
```
의존 패키지 설치 없이 Node.js로 검사할 수 있습니다. GitHub CI PostgreSQL 데이터는 가상 시험자료입니다.
