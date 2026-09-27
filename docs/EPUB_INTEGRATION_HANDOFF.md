# EPUB 및 중단 세션 인수 — 2026-09-26

현재 요약과 다음 작업은 [CURRENT_HANDOFF.md](CURRENT_HANDOFF.md)를 우선한다.
아래 날짜별 기록은 이력이다. 최종 wa4be8509 설치와 Home 3회 검증은 완료했으며,
EPUB 실기기 읽기 수용은 남아 있다. 추가 성능 튜닝은 별도 과제로 분리했다.

## 작업 위치와 통합 주의

- 앱 변경은 2026-09-27 main 작업 폴더에 통합했다. 기준 HEAD는 `d9dcfd8`이며
  변경은 아직 미커밋이다. `../pocket-daily-epub`에도 같은 소스가 남아 있으므로
  중복으로 다시 반영하지 않는다.
- main의 기존 미커밋 iPhone 스크린샷 3장은
  `.build/integration-backup-20260927/`에 보존한 뒤 검증된 새 캡처로 교체했다.
  백업의 `imported-files.json`은 통합 파일 30개의 SHA-256 목록이다.
- Claude가 재개되면 먼저 이 문서와 펌웨어 인수 문서를 확인한다. 동일 펌웨어
  파일을 다시 구현하거나 예전 렌더러/스크린샷을 덮어쓰지 않는다.
- 커밋/푸시/릴리스는 하지 않았다. 기기 설치 이력은 아래 날짜별 기록을 따른다.
  앱 PROJECT_MEMORY는 커밋 시 해당
  변경과 함께 갱신한다. main 작업 폴더 통합은 완료했고 커밋/푸시는 하지 않았다.

## 앱 변경

- `Sources/Convert/`: 일반 텍스트 → 목차 있는 EPUB 3(nav + NCX), 섹션 크기 제한,
  스트리밍 STORE ZIP, 원자적 파일 생성, 입력/파일명 검증, 취소와 임시 파일 정리.
- `ContentView`의 기존 글쓰기 sheet를 새 `TextDocumentComposer`에 연결했다.
  EPUB/Plain text 선택과 전송 준비 결과를 확인한다. 자동 연결/전송은 하지 않는다.
- 새 시험: `EPUBExporterTests`, `ReadingDocumentPreparationTests`,
  `PocketFlowTests.testTypedTextCanBecomeAnOfflineEPUB`.
- `Support/PocketUIHost/`: 아래 펌웨어 최종 소스로 빌드·검증한 host artifact.
  파일 등록은 XcodeGen으로 재생성했다. `project.yml` 변경은 없다.
- API, 제한, 세부 검증과 실기기 샘플은 [EPUB_ENGINE.md](EPUB_ENGINE.md).
  제품 후보의 우선순위/범위는 [PRODUCT_BACKLOG.md](PRODUCT_BACKLOG.md).

## 펌웨어 인수

중단된 Sync Home/Sleep 구현을 검토·보완했다. 코드와 인수 문서는
`../pocket-daily-firmware`에 남아 있다. 세부 내용은
[SCREEN_PRESENTATION_HANDOFF.md](../../pocket-daily-firmware/docs/SCREEN_PRESENTATION_HANDOFF.md).

- 호스트 429개, route 경계 11개, 엄격 cppcheck, 서식/공백 검사 통과.
- default 빌드 성공. 모델 감지로 X3/X4를 지원하는 공용 이미지다.
- HTTP에서는 요청을 준비하고 render task에서 한 번 그린다. Home/Sleep과 카드가
  공유하는 슬롯의 busy/영수증 규칙을 계약에 명시했다.
- generation 오버플로, 한국어 빈 날씨 폰트, 카드 이미지 읽기 실패 처리를 수정했다.
- 기존 CI exit 127 조치는 `af70853c`에 이미 반영됐다. 로컬 cppcheck 도구 미러
  연결 거부는 별개의 문제였으며 같은 버전 2.11을 로컬 빌드해 검사했다.

## 남은 실기기 수용

- 새 펌웨어를 사용자가 설치한 뒤 Home/Daily Brief 반복 Apply, Back 복귀,
  카드 ↔ Home 전환, 30분 유휴와 heap/최대 블록, 실제 패널 표시를 확인한다.
- Side buttons → Up turns forward 설정을 앱에서 Apply한 뒤 기기 readback과
  실제 페이지 방향을 확인한다. 현재 값이나 적용 성공을 추정하지 않는다.
- EPUB 샘플의 첫 열기/목차/한글/분할 경계/마지막 장/재열기 진행도는 X3/X4에서
  별도 수용한다. 생성 구조와 시뮬레이터 대기열 검증이 기기 읽기를 대신하지 않는다.
- HTML/URL/PDF/DOCX 가져오기, 이미지, 뉴스 수집은 이번 구현에 포함하지 않는다.

## 앱 최종 검증

- 전체 단위 시험 **314/314**, 최신 renderer 시험 **10/10** 통과.
- iPhone/iPad 각각 UI 흐름 10개 + 스크린샷 시험 통과. Mac 캡처 성공.
  물리 캡처를 요구하는 Mac parity 시험은 입력이 없어 제외한다.
- iOS 및 macOS 빌드, XcodeGen 파일 등록, `git diff --check`, 문서 링크 확인 통과.
- 스크린샷 **11장**(iPhone 4, iPad 4, Mac 3) 재생성 및 이미지 검토 완료.
  `scripts/validate_app_store.sh` 통과. 원격 제출/승인 결과를 뜻하지 않는다.
- `.build/epub-full-unit.log`, `.build/epub-final-renderer-tests.log`,
  `.build/epub-final-mac.log`, `.build/epub-final-screenshots.log`에 로컬 결과가 있다.
  기존 Swift 6 capture 및 copyBytes 반환값 경고는 이번 범위에서 수정하지 않았다.


## 2026-09-26 19:00 — 실기기 전송 완료, 설치 대기

사용자 승인 후 새 펌웨어 `/update.bin`과 독서 샘플
`/Pocket-EPUB-check-c175a49c.epub`를 Same Wi-Fi로 전송했다.
각각 6,007,344 bytes/CRC32 `3542B12E`, 188,867 bytes/CRC32 `35A81A11`로
기기 수신 및 원자적 게시 확인을 통과했다. 자동 flash는 호출하지 않았다.

현재 실행 버전은 여전히 `1.7.0-beta.1`이며 `screenPresentation`이 없다.
사용자가 Back으로 Sync 종료 → 기기의 설치 확인 승인 → 재부팅 후 Same Wi-Fi
재연결을 해야 다음 시험을 진행할 수 있다. 기대 설치 버전은
`1.7.0-dev-main-bca376e7-webfaff08`, 기능 플래그는 `screenPresentation: 1`이다.

버튼 설정 readback은 `sideButtonLayout=0`(Up turns back),
`frontButtonFollowOrientation=0`. 값을 변경하지 않았으며 Up turns forward 및
실제 페이지 방향 검증은 남아 있다. EPUB은 전송만 확인했고 실제 읽기는 미검증이다.


## 2026-09-27 00:07 — 설치 및 표시 응답 확인

사용자 설치 후 기대 버전 `1.7.0-dev-main-bca376e7-webfaff08`과
`screenPresentation: 1`을 확인했다. 저장 설정(generation 3)은 변경하지 않고
Home 3회 → Brief → Home을 요청했고 모두 `rendered`/`failure: none` 응답을 받았다.
실제 화면은 사용자 확인 대기다. 현재 Home 표시를 요청한 상태로 두었다.
이는 앱의 설정 변경 Apply 전체 시험이나 30분 유휴 시험을 대체하지 않는다.
버튼 값은 여전히 Up turns back(0)이다. EPUB 읽기와 물리 버튼 검증은 남아 있다.


## 2026-09-27 — 사용자 화면 확인 및 main 통합

사용자는 앱 Apply로 화면이 바뀌는 것을 확인했고, Sync의 사선 표지와 달리
일반 Home에서는 실제 표지가 정상 표시됨을 확인했다. 사선은 Sync에서 표지
디코딩을 생략하는 명시된 제한이며 표지 데이터 유실로 판단하지 않는다.

검증된 EPUB 소스/시험, host artifact, 캡처를 main 작업 폴더에 반영했다.
XcodeGen 재생성 결과가 검증 worktree와 바이트 단위로 같고, renderer pin 검사와
스토어 패키지 검증을 통과했다. 30분 유휴/카드 전환은 Same Wi-Fi 재연결 대기,
EPUB 목차/한글/진행도 및 물리 버튼 수용은 미완료다.

main 통합 후 iOS 및 macOS 앱 빌드도 모두 통과했다. 로그는
`.build/epub-integration-ios.log`, `.build/epub-integration-mac.log`이다.
소스/시험/아티팩트/스크린샷은 기존 검증 worktree의 파일 해시와 일치한다.


## 2026-09-27 01:59 — 카드 전환 확인, 지연 발견, 유휴 시험 진행 중

실기기 카드→Home 렌더 응답 및 이전 영수증의 409 무효화를 확인했다.
표시 직후 상태 조회가 10초를 넘는 지연은 두 화면에서 재현됐다. 앱의 기존
읽기 재시도 정책으로 약 14초 후 성공하며 재시작은 관측되지 않았다.
지연이 해결됐다고 주장하지 않는다. SD/콘텐츠 검증 경로는 원인 후보다.

01:59:55부터 30분 상태/영수증 관찰(5분 간격) 및 마지막 Home 재표시 시험을
시작했다. 초기 heap 36,324 B, uptime 296 s. 최종 결과는 아직 대기이며
후속 작업에서 기록한다. EPUB 실제 읽기·물리 Back·버튼 방향 등은 별도다.


## 2026-09-27 02:30 — 30분 연결 시험 완료

7회 관측에서 동일 버전·Home generation 4·rendered 응답을 유지했고 uptime은
296→2,096초로 이어졌다. 가용 heap은 36,324→36,320 B(차이 -4 B), 관측 범위는
36,292–36,336 B였다. 이번 구간에서 지속적인 감소나 재시작은 관측되지 않았다.
일반 50 KB 목표 충족이나 메모리 누수 부재 전체를 증명하는 결과는 아니다.

30분 후 Home 재표시도 `rendered`/`failure: none`이었다. 준비 시 heap 35,284 B,
최대 블록 29,684 B. 다만 첫 10초 상태 조회 timeout 후 읽기 재시도로 약 14초에
확인되어 지연 문제는 남아 있다. 새 전송·flash·코드 변경은 하지 않았다.

Same Wi-Fi의 표본 연결/가동시간/영수증 및 유휴 후 재표시 검증만 완료 처리한다.
물리 Back, 버튼 방향 변경, EPUB 실제 읽기, X4/direct 시험은 아직 별도다.
상세 결과와 지연 원인 후보는 펌웨어 SCREEN_PRESENTATION_HANDOFF.md에 기록했다.


## 2026-09-27 — 콘텐츠 중복 검증 제거 및 표지 안내

ContentViewState는 active revision 검증 중 해독한 카드를 재사용하여 두 번째
전체 검증을 제거한다. 읽기 전후 SHA와 손상 거부·이전 유효 revision 복구는
유지한다. 시험 fixture의 SHA 처리량은 3,004→1,502 B이다. 이는 실제 Apply
시간이 절반이라는 뜻이 아니며, 약 14초 지연 개선은 아직 실기기 미측정이다.

펌웨어 host 433/433, content-store 56/56, route 11/11, 엄격 cppcheck 결함 0,
default 빌드 오류·경고 0. 상세는
[CONTENT_LOAD_HANDOFF.md](../../pocket-daily-firmware/docs/CONTENT_LOAD_HANDOFF.md).
소스 지문을 검증한 Apple host artifact를 다시 빌드해 앱 두 작업 폴더에 반영했다.
앱 Apply 성공 문구에 Sync에서는 책 표지를 placeholder로 표시한다는 안내를
추가했다. 화면 표시 시험 6/6 및 새 renderer 시험 10/10, macOS 빌드 통과.

새 로컬 펌웨어는 `1.7.0-dev-main-bca376e7-wa4be8509`, 6,007,488 B, SHA-256
`44400247cf2146a470138fff0f03aaea0cec9c354c874e1d11d206b5cfdd3cbf`이다.
리더 상태 조회가 timeout되어 새 파일은 기기로 전송하지 않았다. 이 빌드의
설치·실기기 속도 검증은 남아 있으며, 이전 30분 시험 결과를 이 빌드에
적용하지 않는다. 마지막 확인된 설치 버전은 `webfaff08`이다.

최종 앱 검증: iPhone UI 11/11(흐름 10 + 캡처 1), iPad UI/캡처 성공,
Mac 캡처 성공. 최신 iOS 시험 빌드와 macOS 빌드 모두 통과했다.
스크린샷 11장을 재생성하고 육안 검토했으며 스토어 패키지 검사를 통과했다.
물리 입력을 요구하는 Mac parity 시험은 이번에도 별도다. 로그는
`.build/content-snapshot-renderer-tests.log`, `.build/content-snapshot-mac.log`,
`.build/content-snapshot-screenshots.log`이다. 문서 로컬 링크와 diff 검사 통과.


## 2026-09-27 — 새 최적화 빌드 Wi-Fi 전송 완료

사용자의 Same Wi-Fi 재연결 후 기존 기기 ID 일치를 확인하고
`1.7.0-dev-main-bca376e7-wa4be8509` 이미지를 `/update.bin`으로 전송했다.
6,007,488 B / CRC32 `8639E84F`, SHA-256
`44400247cf2146a470138fff0f03aaea0cec9c354c874e1d11d206b5cfdd3cbf`.
기기 수신 검사와 원자적 게시가 성공했다. 전송 로그는 펌웨어 저장소의
`build/content-snapshot-upload.log`. 설치/flash는 호출하지 않았다.
전송 후 실행 버전은 여전히 `1.7.0-dev-main-bca376e7-webfaff08`이다.
사용자가 Back으로 Sync 종료 후 기기 설치 확인을 승인하고 Same Wi-Fi로
다시 연결하면 새 버전 확인과 표시 지연 측정을 이어간다.


## 2026-09-27 03:28 — 최적화 빌드 설치 및 Home 반복 측정

사용자 설치·재연결 후 동일 기기에서 `1.7.0-dev-main-bca376e7-wa4be8509`와
`screenPresentation: 1`을 확인했다. 저장된 generation 4 Home을 변경 없이
3회 요청했고 모두 `rendered` / `failure: none`이었다. 앱과 같은 2초 polling,
10초 GET timeout, 90초 budget에서 완료 응답까지 14.290 / 14.259 / 14.149초,
각각 GET timeout 1회 후 읽기 재시도로 성공했다. POST는 0.108 / 0.177 /
0.025초였다. 이는 패널 자체의 광학 측정이 아닌 HTTP 완료 확인 시간이다.

이전 약 14초와 비교해 전체 지연 개선은 확인되지 않았다. 중복 SHA 읽기
감소는 유효하지만 이번 최적화로 표시 지연을 해결했다고 판단하지 않는다.
폰트/패널 등 단계별 시간 계측 없이는 지배 원인을 특정할 수 없다.

uptime 49→101초로 재시작 없이 이어졌고, 요청 사이 heap은 기준 36,200 B에서
36,100 / 36,120 / 36,128 B였다. receipt heap은 34,900 / 34,496 / 34,516 B,
최대 블록은 29,684 / 29,684 / 28,660 B였다. 짧은 3회 측정으로 장기 안정성이나
누수 부재를 주장하지 않는다. 마지막 화면은 Home이다. 새 빌드의 30분 시험,
물리 EPUB 읽기·버튼 방향·X4/direct 확인은 별도다.

근거: 펌웨어 `build/screen-presentation-verification/optimized-20260927-032818.jsonl`.


## 2026-09-27 — 통합 정리와 실기기 실패

기능별 로컬 커밋으로 정리했다. 이후 상태는 [CURRENT_HANDOFF.md](CURRENT_HANDOFF.md)를 우선한다.
사용자가 샘플 첫 본문을 확인했지만, ZWJ 이모지가 깨져 보이고 긴 섹션 제목/본문에서
입력이 멈췄다고 보고했다. 사용자가 재부팅해 Sync 복귀; 저장 crash report 없음, USB 로그 없음.
EPUB 실기기 수용은 미완료/실패이며 원인은 아직 확정하지 않았다.
옆 버튼 Apply의 저장값 1은 재부팅 전후 읽어 확인했으나 물리 방향은 별도 검증이다.
