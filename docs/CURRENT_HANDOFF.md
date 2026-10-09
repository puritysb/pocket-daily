# 현재 인수인계 — 2026-10-09

현재 구현은 [PROJECT_MEMORY.md](PROJECT_MEMORY.md)의 날짜별 검증 기록과 실제 코드를
기준으로 한다. **1차 기능 구현은 갖췄지만 출시 승인 완료 상태는 아니다.**

- 디자인 시스템 변경은 `f0adf02`로 원격 main에 반영됐다. 정리 시작 시 작업 트리는
  깨끗했고 로컬 main은 `0c93a4f`(다중 리더)까지였다. 이 커밋의 물리적 다중 기기
  동시 연결 검증은 아직 없으며, 디자인 테스트 통과와 구분한다.
- Library와 My Reader가 주 목적지다. Reader Settings 안에 Home / Sleep / Reading
  범위가 있고 Manage Reader는 기기 옵션에서 연다. 아래 9월의 Screens / Device
  메뉴 및 BLE 미병합 설명은 현재 구조를 설명하지 않는다.
- 이번 마감에서 넓은 화면의 탐색 제목을 콘텐츠 제목과 분리했다. iPhone의
  My Reader는 이미 인라인 제목이다. 옛 QA 캡처를 최신 화면으로 판단하지 않는다.
- 후속 UI 정리: 카드·날씨 연결 단계의 주요 행동을 하단에 고정했다.
  리더 선택은 Readers… → Manage Readers로 구분하고 Mac 관리 시트를 줄였다.
  End Session…은 리더의 Sync 종료와 재연결 방법을 확인한 후 실행한다.
- 최신 제품 코드의 서명 IPA·Mac PKG 생성과 검증은 완료했다. 출시 전에는 실제
  iPhone/X4 전송·복구·이어 읽기 수용 시험, TestFlight, 심사 연락처/앱 레코드/업로드/
  실기기 영상 확인이 필요하다. 최신 export 증거는 `appstore/submission.json`에 있다.
- 기준 확인: 과거 테스트 수를 최신 HEAD 재검증으로 인용하지 않는다. 이번 제목
  변경과 후속 실기기 확인 결과는 아래에 기록한다. 계정·출시 작업은 수행하지 않았다.

## 이번 제목 정리의 검증

- 2026-10-09: `POCKET_SCREENSHOT_TEST_TARGET=PocketUITests/PocketScreenshotTests
  ./scripts/capture_screenshots.sh` 종료 코드 0. iPhone/iPad 캡처·접근성 테스트와
  Mac 테스트 통과, 스크린샷 19장 재생성, 소스 패키지 검증 통과.
- iPhone/iPad의 Manage Reader와 Mac의 My Reader QA 캡처를 직접 확인했다.
  Mac 탐색 제목은 17pt, 넓은 iPad는 headline, iPhone은 기존 인라인 제목이다.
- 로그: `.build/design-closeout-capture.log`. Mac My Reader QA 이미지:
  `.build/design-closeout/my-reader.png`(로컬 산출물). 전체 단위 테스트 재실행,
  설치된 앱 교체, 실기기 및 새 배포본 검증을 의미하지 않는다.

## 후속 UI 수정 전 재빌드 및 X3 검증 — 2026-10-09

- 기준: HEAD `0c93a4f` + 위 탐색 제목 변경. 서명된 sandbox Debug Mac 앱을
  개발 파이프라인으로 재빌드하여 `~/Applications/Pocket Daily.app`에 설치·실행했다.
  최종 파이프라인 후 설치 앱을 다시 실행했고 X3 Same Wi-Fi 연결 상태를 확인했다.
  설치본과 빌드 실행 파일의 SHA-256은
  `f03535cb7b56cc60d4c6dbc4f3846e710e91010f8fb3824e09935a9131830740`이며 바이트 일치 확인.
- iOS 단위 테스트: 543개 실행, 하드웨어 opt-in 1개 건너뜀, 실패 0.
  로그 `.build/final-unit.log`. 이는 물리 iPhone 검증을 대신하지 않는다.
- iOS UI 회귀: 첫 실행 8개 중 7개 통과. 기사 재개 시험은 단위 시험이 남긴
  비규격 가짜 기기 ID로 등록 복구가 실패한 테스트 환경 문제를 확인했다. 이 시험에
  기존 `--ui-test-empty-discovery` 등록 격리를 적용하고, 여러 대기 작업의 메뉴도
  선택하도록 고쳤다. 수정 후 기사 저장·읽기·준비·재실행·재개·삭제 시험 통과.
  로그 `.build/final-ui.log`, `.build/final-article-ui-isolated.log`.
- 실제 X3 / Same Wi-Fi: 개발 파이프라인 연결·전체 inventory 페이지 확인 통과
  (`../pocket-daily-firmware/build/dev-pipeline-runs/20261009T042817-e13ac1/report.json`).
  펌웨어는 `0.1.0-dev-fix-ble-window-cache-preflight-8925b142-ble-standby-w7763019d`.
- 실행 앱에서 테스트 글 작성 → EPUB 저장 → 한글 포함 본문 읽기 → X3 전송 →
  기기 보관함 갱신 확인. 앱의 폴더 복사 기능으로 얻은 EPUB과 실제 리더 다운로드가
  3,114바이트 및 SHA-256 `9368ac81f9e1a19ced2b3df569b8dace422118f1464dd654066db61a76b2f722` 일치.
  증거 `.build/final-verification/reader-roundtrip.json`. 로컬 폴더 복사이며 실제 SD 매체 시험은 아니다.
- Reading 여백 5→10px 적용을 기기 API로 확인하고 5px로 복원 확인.
  기존 Home 미적용 초안은 보존했다. 테스트 책 `Pocket QA 20261009-1333`은 앱과 X3에 남아 있다.
- 연결 종료 후 재연결은 실패했다. Disconnect가 기기의 Sync 세션을 종료한 뒤
  My Readers의 Connect가 탐색을 마쳤지만 `No Pocket reader was visible`로 끝났고 HTTP도
  응답하지 않았다. BLE 깨우기 성공으로 해석하지 않는다. X3에서 Sync → Same Wi-Fi를
  사용자가 다시 열자 설치 앱이 자동 재연결하고 inventory를 갱신했다.
  Sync가 열린 기기에 재연결하는 경로는 확인됐지만, 종료된 Sync를 BLE로 깨우는 경로는 미확인이다.
- 실제 iPhone 첫 시도는 잠금으로 중단됐으나, 사용자가 잠금을 해제한 후 서명 빌드와
  Mac·물리 iPhone 연결/inventory 파이프라인이 모두 통과했다. 최종 두 플랫폼 모두
  루트 20개·/Books 3개 엔트리를 끝까지 조회했고 inventory 15개를 확인했다.
  최종 보고서 `../pocket-daily-firmware/build/dev-pipeline-runs/20261009T044234-25e75e/report.json`,
  로그 `.build/final-hardware-iphone-unlocked.log`. iPhone 파일 전송·직접 Wi-Fi·BLE·이어 읽기
  수용 시험까지 통과한 것으로 확대하지 않는다.
- `./scripts/validate_app_store.sh` 통과. 새 제출·업로드·출시 승인을 의미하지 않는다.
- 이번 확인 범위 밖: X4, 물리 다중 리더 동시 연결, BLE 절전 깨우기·직접 Wi-Fi,
  물리 리더 화면·장 넘김·양방향 이어 읽기 수용 시험, iCloud 기기간 교환, TestFlight·출시 서명 export.

## 후속 마감 — 2026-10-09

- 일반 End Session은 펌웨어의 Sync를 닫고 홈으로 복귀한다. 이는 개발용 BLE standby와
  다른 상태다. 이전 Disconnect 뒤 실패를 곧바로 standby wake 결함으로 판단하지 않는다.
- 최종 설치 펌웨어 그대로 Mac의 제어된 standby→BLE wake→Same Wi-Fi 복귀가
  2회 연속 통과(13.21/12.94초). 보고서 `20261009T053635-d99fbe`.
- 실기기 시험을 확장해 앱의 실제 Library→준비→전송 경로로 생성 EPUB을 보내고,
  기기 다운로드와 전체 바이트를 비교한 뒤 그 파일만 크기·경로 검증을 거쳐 삭제한다.
  Mac 2,856바이트 왕복·정리 및 13.17초 standby wake 통과
  (`20261009T054304-49d77f`의 Mac 단계). 보고서는 형제 저장소 `build/dev-pipeline-runs/`에 있다.
- 확장 시험의 첫 시도는 비동기 준비를 기다리지 않는 시험 코드 문제로 전송 전에 실패했다.
  준비 완료 대기를 추가했다. 이전 실패의 생성 작업은 진단용으로 남을 수 있으며,
  기존 사용자 책이나 확인되지 않은 발행을 일괄 삭제하지 않는다.
- 전송 단위 시험은 기존 UI 파일을 읽지 않도록 시험별 ReaderSessionStorage로 분리했다.
  이후 전체 단위 543개: 542 통과, opt-in 하드웨어 1 건너뜀, 실패 0.
- 최종 UI의 편집 초안 유지·연결 복귀와 선택 책 작업 복귀 2개 시험 통과.
  연결 버튼의 하단 위치도 검증하고 실제 캡처를 확인했다. 스크린샷 19장 재생성,
  Mac 시험과 스토어 소스 검증 통과 (`.build/followup-editor-ui-v3.log`,
  `.build/followup-screenshots.log`).
- 최종 제품 코드의 Mac 재빌드·연결·inventory·2,856바이트 EPUB 왕복 및 시험 파일 정리
  통과: `20261009T055656-a28dde/report.json`. 설치본과 빌드 실행 파일 SHA-256
  `db9f181a0b29c14f20549cb3bc3fad8aa27f316b81482b1463d0c7a9624a929e` 일치,
  서명 검증 통과. 설치 앱을 실행해 X3 Same Wi-Fi 자동 연결과 목록 갱신을 확인했다.
- 확장된 iPhone 전송·standby 시험은 다시 잠긴 기기 때문에 실행되지 못했다
  (`20261009T054304-49d77f`). 앞선 iPhone 연결·inventory 통과와 구분한다.
  X4, 물리 다중 리더, 직접 Wi-Fi, 양방향 이어 읽기·iCloud 및 TestFlight는 남은 수용 시험이다.

- 최종 배포 파이프라인 `.build/app-store/final-20261009-v2/` 완료: 단위 543개 중
  542 통과/1 건너뜀, arm64 iOS IPA 및 universal sandbox Mac PKG 서명·프로파일·
  개인정보 매니페스트 검증 통과. 본앱과 Share 확장의 App Group 프로파일·버전도 일치.
  `release-evidence.json`과 `appstore/submission.json`에 전체 해시를 기록했다.
  빌드 기준은 `0c93a4f` + 이번 커밋의 제품 변경이며 이후 제품 코드는 바뀌지 않았다.
  업로드·심사·출시는 수행하지 않았다.

# 2026-09-29 당시 상태 (이력)

이 절과 아래 이력은 당시 상태이며 현재 출시 판단의 근거가 아니다. 삭제된 기능(KOSync)을 되살리지 않는다.

- 제품: 기기 없이 쓰는 집중형 리더 + X3/X4 컴패니언([READER_EXPANSION.md](READER_EXPANSION.md)).
  Library 첫 화면, Screens(Home/Sleep·읽기 설정), Device(연결·파일·펌웨어), Weather/Calendar 분리,
  Articles(RSS/Atom 구독, 로컬 주소 링크 차단), foliate-js 리더(Mac은 창 안에서 열림).
- 이어 읽기: iCloud 키-값과 리더 교환. 리더 교환은 연결 시 + 같은 Wi-Fi의 마지막 리더(같은 deviceID)와
  자동(앱 활성화·책 열기/닫기, 1.5초 탐침). 책을 여는 것만으로는 읽은 시각이 바뀌지 않는다.
  펌웨어는 페이지 첫 글자 기준 정확한 XPointer를 기록·적용한다(섹션 캐시 v133, X3 확인).
  계약: [READING_PROGRESS.md](READING_PROGRESS.md), 펌웨어 `docs/reading-progress-v1.md`.
- main 상태: 앱·펌웨어 모두 main에 병합·푸시. 펌웨어 pre-release `v1.7.0-beta.3`(bc24adb3, CI 통과).
  App Store 서명 export는 c4eea1a 기준으로 검증됨(업로드 안 함, `appstore/submission.json`).
- 보류: Bluetooth 자동 이어 읽기(reading-sync-ble-v1)는 양쪽 `feat/ble-reading-sync` 브랜치에만 있다
  (원격 `origin/feat/ble-reading-sync`에 보관, main 미병합). X3 실측: 창은 열리지만 NimBLE 후 여유 heap 13.5 KB, 최저 6.9 KB/블록 2 KB.
  마지막 실기기 시험에서 iPhone이 리더를 등록하지 못했다(원인 미확정, 앱 브랜치에 등록 경로 수정과
  `reading-sync.log` 추적 추가됨). 재개 시 이 브랜치에서 시작하고 heap 여유를 먼저 설계한다.
- X3(`5B09AF70`): main 빌드 `1.7.0-dev-main-bc24adb3` 스테이징됨(리더에서 설치 확인 필요).
- 남은 일(나중): App Store Connect 기록·리뷰 연락처(계정 소유자), TestFlight 업로드, 실기기 영상,
  X4 확인, 니체 책 색인 지연 확인, 출시 후 Bluetooth 동기화·Android.
- 이 Mac은 Python의 LAN 접근이 막혀 있다. 펌웨어 스테이징은 `/usr/bin/curl`로 `/upload` 후
  `/api/pocket/v1/commit`(아래 4차 이력 참고). 리더 주소는 서브넷 스캔으로 찾는다(최근 192.168.68.56).

# 이력 (당시 상태, 최신순)

## 9월 28일: X3 실기기 결과 (펌웨어 `feat/reader-support`)

- 멈춤: `75df8f0e` 설치 후 「나는 고양이로소이다」(일본어·한국어 대역) 페이지 넘김 멈춤 재현 안 됨.
- 검은 팝업·빈 페이지의 세로 막대: 활성 UI pack(`studio-6c134a9368a44871`)의 `popupCornerRadius`가
  상자를 검게 만들고 글자도 검게 둬 모든 팝업이 검은 상자였다(beta.1부터). `7191e1a7`로 수정,
  X3에서 "Failed to index…" 문구가 읽히는 것을 사용자가 확인. 세로 막대는 가로 방향(orientation 1)의 그 팝업.
- 4장 색인 실패: 첫 장 압축 해제의 연속 32 KiB 창이 단편화된 heap에서 할당 실패. `f8c9d118`로 8 KiB×4
  분할, `1e338826`/`13d46fa7`로 실패 기록(`/api/status` `lastBuildError`, SD 96바이트). X3 설치
  (`13d46fa7`) 후 4장 열림, `lastBuildError` 없음, 위치 기록에 XPointer 저장 확인.
- 진행 중: 페이지 넘김 성능(기기 단계별 시간 `readerPerf` 텔레메트리, host 프로파일링, 출력 동일 최적화).
- 나중: 니체 「인간적인 너무나 인간적인」(570 KB, 독일어·한국어 대역) 59% 부근 스크롤 불가 보고 —
  File Transfer 모드에서 책과 SD 루트의 `crash_report.1.txt`/`.3.txt`를 받아 확인할 것.
- formatter가 바꾼 공백·줄바꿈 전용 파일 5개는 사용자 승인으로 되돌렸다(기능 변경 없음).

## 9월 27일 4차: KOReader 제외, 미리보기 대체 글꼴, X3 멈춤 조사

- 사용자 결정: KOReader 동기화 연동은 이번 버전에서 제외하고 노출하지 않는다. 이어 읽기는 iCloud와
  리더 직접 교환만 쓴다(Library → Continue Reading, 토글 2개). 관련 코드·시험·스크립트 삭제, 스토어·
  개인정보·공개 페이지 문구 정리. 앱 단위 373·UI 14 통과, 스크린샷 14장·패키지 검사 통과.
- 앱 미리보기에 대체 글꼴 연결: 펌웨어 `75df8f0e`의 `pdui_set_fallback_font`, 렌더러 artifact 재가져오기.
  이모지 카드가 오류 대신 그려진다. Cached/BoundedUI 차이는 굵은 한글 윗줄 약 1픽셀(시험으로 한정).
- X3 멈춤 보고(「나는 고양이로소이다」 한국어, 여러 장 넘김 후 먹통): 기기 펌웨어는 `1.7.0-beta.1`로
  이번 세션의 멈춤 수정(`93017b70` 페이지 글리프 캐시, `347c6ec8` 글자 수 캐시)이 없다. 재시작 원인
  "software restart", crash report 없음 → 긴 정지 후 수동 재시작과 일치. 책 파일은 Mac에 없어 host 재현 전.
- 수정 펌웨어 `1.7.0-dev-feat-reader-support-75df8f0e-wafd75b32`를 X3(192.168.68.73)에 스테이징함
  (size 6,055,584, CRC32 8A05CB14 확인). **리더에서 설치 확인과 같은 책 재시험 대기.**
- 이 Mac은 Python의 로컬 네트워크 접근이 막혀 `pocket_put.py`가 "No route to host"로 실패한다.
  `/usr/bin/curl`은 된다: `curl -F "file=@firmware/update.bin;filename=.pocket-<id>.part" "http://<ip>/upload?path=/"`
  후 `POST /api/pocket/v1/commit` `{staging,target:"/update.bin",size,crc32}` (앱의 HTTP 경로와 같음).

## 9월 27일 3차: 펌웨어 위험 보완과 기기 간 교차 검증 (펌웨어 `feat/reader-support`)

- 글자 수가 많은 장: advance 캐시를 LRU(768, 긴 문단 2,048)로 바꾸고 블록 단위로 읽는다.
  1,596개 서로 다른 음절 장의 SD open 10,217 → 3, 줄바꿈 결과 byte 동일(host).
- 없는 글자: 보이지 않는 문자(ZWJ·변형 선택자·피부색 등)는 그리지 않고, 이모지 연쇄는 첫 이모지 하나로,
  없으면 OFL 대체 글꼴 PocketSymbols(Noto Emoji·Symbols 2·Math, 예약 이름 없음, 413 KB) → 작은 점선 틀.
  섹션 캐시 버전 131(모든 책 1회 재배치). 앱은 이 글꼴을 번들하고 Reader → Files에서 보내기를 제안한다
  (리더 재시작 후 적용). **기존 버그 수정: 무선 전송된 .cpfont가 SD 루트로 가던 것을 `/.fonts/<family>`로.**
- reading-progress v1(서버 없는 기기 간 교환) 펌웨어 구현: 상태 `readingProgress: 1`, GET/POST
  `/api/pocket/v1/reading`, 책을 닫을 때 XPointer 기록(메모리 부족 시 생략), 다음 열 때 "기기: N% · 이동?".
  기존 KOReader XPath 결함도 수정(text 노드 번호, 목록 뒤 문단 번호, 엔티티).
- 교차 검증(하드웨어 없음): 펌웨어가 앱 XPointer 해석 한국어 15/15·Frankenstein 114/114,
  앱이 펌웨어 XPointer 258/258(첫 실행에서 `&apos;` offset 5글자 밀림을 찾아 펌웨어 `63140410`에서 수정).
- 최종: 앱 단위 414, UI 흐름 13 + 리더 1, 두 시뮬레이터 이어 읽기, Mac 리더·실제 책·교차 검증,
  스토어 패키지 검사 통과. 펌웨어 host 483, scripts 67, `pio run` 경고 0(flash +19 KB).
  `pio check`는 패키지 미러가 멈춰 cppcheck 2.20 직접 실행으로 대체. Mac 가이드 책 시험은 6회 중 1회
  원인 미확인 실패 후 4회 연속 통과(간헐 가능성 기록).
- X3/X4에서 확인할 것: 긴 한국어 장 넘김 속도, 대체 글꼴 로딩 후 heap, 회전 텍스트 기준선, 책 닫을 때
  위치 기록 시간(`RPS Recorded … ms`)과 절전 진입, 앱과 GET/POST(LAN·직접 연결), 이동 확인 창의 버튼·방향.
- 남은 일: 앱 미리보기(host 렌더러)에 대체 글꼴 등록(지금은 앱 미리보기에서 이모지가 점선 틀),
  공개 KOSync 서버 복구 후 실제 왕복, iCloud App ID 기능 활성화, 푸시·릴리스.

## 9월 27일 2차: 서버 없는 이어 읽기와 직접 검증 (앱 `feat/reader-expansion`)

- 공개 KOSync 서버 `sync.koreader.rocks`가 HTTP 522(Cloudflare→원서버 연결 실패)로 응답하지 않음을 확인.
  과거에도 반복된 장애다. Sync 화면은 `/healthcheck`로 먼저 확인하고 장애를 장애로 안내한다.
- 서버 없는 경로: iCloud 키-값(같은 Apple ID, 기본 켬)과 리더 직접 교환(펌웨어 `readingProgress: 1`,
  계약 [READING_PROGRESS.md](READING_PROGRESS.md)). 앱 측 구현·단위 시험 완료, 펌웨어 측은 진행 중.
  iCloud KVS 엔타이틀먼트 추가 — 서명 빌드 전에 계정 소유자가 App ID의 iCloud 기능을 켜야 한다.
- 직접 검증(하드웨어 없이 가능한 범위, computer use 도구는 이 세션에 없어 XCTest로 대체):
  - `scripts/e2e_sync.sh`: 공식 컨트롤러를 따르는 로컬 KOSync 대역(`scripts/kosync_dev_server.py`)으로
    iPhone 17 Pro에서 계정 생성·장 이동·업로드 → iPad Pro 11에서 로그인(402 후 sign in)·제안·이동·같은 장 도착 통과.
  - Mac 리더 오프스크린 시험: 렌더·넘김·즉시 이동. 여기서 **넘김 직후 이동이 조용히 무시되는 버그**를 찾아 수정.
  - 실제 책(구텐베르크 EPUB3 이미지 25 MB·EPUB2, Standard Ebooks, 한국어 이모지 샘플) 가져오기·렌더·
    중간 이동·XPointer만으로 복원이 모두 같은 XPointer로 복원됨.
- 단위 411개 통과, iOS/macOS 빌드 통과. 공개 서버 왕복과 실기기는 여전히 미검증.

## 9월 27일 리더 확장 (앱, 커밋됨)

- 첫 화면이 Library다(iPhone 탭: Library · Customize reader · Reader, 넓은 화면: Library · Customize reader).
  첫 실행 시 원본 안내 책(`WelcomeBook`)을 만든다. Articles는 Library의 선반으로 옮겼고
  Reader → Files의 Articles 메뉴는 제거했다. 기사는 같은 `pd-article-<uuid>.epub`를 서재에서 읽고 리더로 보낸다.
- 리더: foliate-js 고정 커밋 부분집합(`Support/ReaderEngine`, SOURCE.json)을 WKWebView에서
  `pocket-reader://` scheme으로만 제공한다. CSP로 책 스크립트 차단, 네트워크 없음, 링크는 확인 후 브라우저.
  즉시 페이지 넘김, 탭 영역(좌/우/가운데), 키보드·페이지 넘김 리모컨, 목차, 글자 크기·글꼴·줄 간격·여백·
  Paper/White/Night, 넓은 화면 2단. Mac은 책마다 별도 창. 책은 컨트롤 숨김 상태로 열린다.
- 서재: EPUB 바이트 그대로 보관, TXT/MD(UTF-8·UTF-16·CP949)는 EPUB로 변환(Markdown `#`/`##`는 장).
  KOReader partial MD5로 중복 제거. DRM(비글꼴 암호화)은 거절. XTC는 Reader → Files 안내.
- 위치: KOReader XPointer + 전체 진행률 + CFI. `xpointer.js`는 crengine 직렬화
  (같은 이름 형제 1개면 번호 생략, 공백 텍스트 노드 제외, code point offset)를 따른다.
- KOSync: 선택형·권장. 로그인/계정 생성, Keychain에 MD5 키만, 리다이렉트 거부, 8초 debounce 업로드,
  다른 기기의 더 앞선 위치만 "이동" 제안(자동 이동 없음), 거절한 레코드는 다시 묻지 않음.
  연결된 리더가 있으면 Sync 화면에서 비밀번호를 다시 받아 CrossPoint `/api/settings`
  (`koServerUrl/koUsername/koPassword/koMatchMethod`)로 리더도 설정한다. 실기기 미검증.
- 스토어: 카테고리 Books(주)/Education(부), 메타데이터·심사 노트·개인정보(PRIVACY.md, docs/privacy)·
  공개 페이지·About·THIRD_PARTY_NOTICES 갱신. 기존 설명의 "옆 버튼 동작 저장" 문구는 UI 제거와 맞지 않아 삭제.
  App Privacy는 "수집 없음"을 유지하되 사용자 선택 KOSync 서버 해석을 제출 시 확인할 것(privacy_answers.json).
- 검증: 단위 406개 통과(iOS 26.5 iPhone 17 Pro 시뮬레이터; KOSync·식별값 47, 서재·동기화·엔진 20 포함),
  iOS/macOS 빌드, UI 흐름 13개 + 리더 UI 1개 통과(App Group이 필요한 기사 시험 때문에 ad-hoc 서명
  `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`으로 실행). 스크린샷 14장(iPhone 5, iPad 5, Mac 4) 재생성 후
  `validate_app_store.sh` 통과. 진행률은 페이지 시작 기준(foliate 페이지 끝 기준·한 페이지 섹션 NaN 문제 수정).
  실제 KOSync 서버 왕복, X3/X4 이어 읽기, 리더 KOSync 설정 전송은 미검증이다.
- 에이전트 worktree `.claude/worktrees/agent-a415f8666cd78557c`는 파일을 옮긴 뒤 남아 있다(추적 안 함).

## 9월 27일 X3 긴 EPUB 멈춤 — host 원인 규명 (펌웨어, 미커밋)

- host 하네스(실제 parser/layout/renderer, PocketSansWorld_12): 3번 섹션 layout은 빠름(43쪽).
  멈춤은 렌더링: 상태 표시줄의 한글 장 제목이 `UiCjkFont`→`prewarmSdCardFont`로 페이지 글리프 캐시를
  덮어써, X3의 grayscale 14회 strip pass마다 글리프를 SD에서 다시 읽었다(pass당 ~450 open, 페이지당 6천+).
- 수정: `FontCacheManager`가 페이지 렌더 동안 페이지 글리프 집합을 고정. host 전체 447/447, `pio run -e default`,
  strict cppcheck 통과. 새 시험 `test/gfx_host/SdFontPageCacheTest.cpp`.
- 이모지 깨짐은 글꼴에 👩/🏽/💻가 없어 대체 문자로 그려지는 것(손상 아님).
- 남은 위험: 한 장에 고유 글자 768개 초과 시 advance 캐시 overflow로 layout 중 SD 로드 급증(1,600음절에 1만 open).
  **X3 실기기 재시험 전에는 고쳤다고 주장하지 않는다.** 절차: 섹션 캐시 삭제 → 3번 섹션 → 10회 이상 앞뒤 넘김.

## 9월 27일 후속 UI / SD 관리 변경

- 상단 `Home & Sleep` 문구 제거. 화면 설정을 먼저 표시하고, 아래 Reading에는 책/아티클 글자 크기만 유지.
  버튼 매핑 UI는 제거했으며 기기의 기존 값은 보존한다. 크기 변경 시 왼쪽에 읽기 예시를 표시
  (실제 EPUB 폰트/페이지와 구분), Back to layout으로 화면 편집에 복귀.
  연결 전에도 편집하고 `Apply to reader`로만 전송. `Discard Edits…`는 확인 후
  마지막 읽어온 설정으로 되돌리며 카드 편집은 유지한다. 연결 해제 때 편집 기준을 보존한다.
- Reader의 반복 메모리 경고를 RAM/SD 사용량 막대로 대체. 상세 오류는 Troubleshooting에 유지.
  콘텐츠 준비 목록에 실제 SD 저장 경로 표시. Sync에서 SD 폴더 탐색·읽기 파일 삭제 추가.
  계약과 제한: [READER_FILES.md](READER_FILES.md).
- 새 `readerFiles: 1` API와 `totalHeap`는 아직 X3에 미설치. 기존 펌웨어에서는 RAM 여유량만
  표시하며 SD 파일 관리를 지원한다고 주장하지 않는다. 실기기 파일 삭제·업데이트는 수행하지 않았다.
- 펌웨어 host 445개, routes 11개, SDK patch 3개 통과. default 빌드 성공,
  strict cppcheck 2.11 결함 0. 앱 전체 단위 검사 339개 및 후속 집중 검사 18개 통과.
  iOS/macOS 빌드, iPhone·iPad·Mac 캡처 11장, 스토어 패키지 검사 통과.
  Mac 캡처 검사 통과(실기기 프레임 대조 1개는 입력 자료가 없어 skip).
  오프라인 글자 크기 편집·읽기 예시 표시·전송 비활성·취소/버리기 UI 검사 및 호스트 렌더러 10개 통과.
  초기 UI 검사에서 상위 접근성 ID 전파와 자동 취소 버튼 부재를 발견해 수정했다.
  설정 우선순위 재정리 후 관련 단위 검사 15개와 읽기 예시 UI 검사 1개 재통과.

## 제품 흐름과 구현

- 브라우저 공유 → 앱 Articles에 보관/검토/수정 → EPUB 준비 → 명시적 SD 전송 →
  리더 Articles에서 이어 읽기/읽음 표시/사용자 삭제. [ARTICLES.md](ARTICLES.md).
- 작성한 글과 일반 콘텐츠는 SD 파일이다. 콘텐츠와 펌웨어 전송·취소·정리를 분리했다.
  임시 파일 정리 실패 시 재시도할 대기열을 보존한다. [TRANSFERS.md](TRANSFERS.md).
- 펌웨어는 실행당 한 번 GitHub 메타데이터 확인, 최신 버전/배포일과 업데이트 동작만 표시한다.
  로컬 BIN 선택은 제거했다. 전송 완료와 설치를 구분하며 기기 설치 확인은 유지한다.
- Sync Home/Sleep 표시 구현 및 사용자 화면 확인 완료. Sync의 책 표지는 의도된 임시 표지다.
  세부 이력: [EPUB_INTEGRATION_HANDOFF.md](EPUB_INTEGRATION_HANDOFF.md).

## 이전 기록: X3 EPUB 읽기 멈춤 보고 (host 원인은 위 항목)

마지막 확인한 X3 버전은 `1.7.0-dev-main-bca376e7-wa4be8509`다. 새 Articles/transferControl 구현은 미설치다.
샘플 `/Pocket-EPUB-check-c175a49c.epub`에 대해 사용자가 다음을 확인했다.

1. 첫 본문은 표시된다. “함께 읽습니다.” 뒤 깨진 글자는 원문의 `👩🏽‍💻` 위치다.
   미지원 글리프 가능성이 있지만 리더 로그로 원인을 확정하지 않았다.
2. 여러 버튼 조작 뒤 “긴 본문 분할” 제목/본문이 표시된 상태에서 입력에 반응하지 않았다.
   사용자가 재부팅해 Sync로 복귀했다. USB 연결은 불가했고, 복귀 후 status에 crash report는 없다.
3. ZIP/XML 검사상 5개 spine/목차 항목이 있다. 세 번째 XHTML은 65,536 bytes,
   한 문단 약 30,000글자이며 ZWJ 이모지가 반복된다. 이것은 조사 단서일 뿐 원인 확정이 아니다.
4. 목차 UI 이동, 긴 문단 경계, 이어 읽기, 물리 버튼 방향의 전체 수용은 아직 통과하지 않았다.

원본 샘플은 `../pocket-daily-epub/.build/epub-samples/pocket-daily-epub-check.epub`,
SHA-256 `c175a49c25ccdd503059d8bad66619274eeb92bc343d749f753af0df1ac450cc`.
기기 캐시/진행도를 삭제하지 않았다. 다음 조사는 USB 로그를 확보하거나 짧은 문단/이모지 없는
대조 샘플로 입력·파싱·글꼴 문제를 분리한다. 재현 전후 증거 없이 고쳤다고 주장하지 않는다.

옆 버튼은 앱에서 Up turns forward → Apply 후 GET으로 `sideButtonLayout=1`을 확인했고,
재부팅 뒤에도 유지됐다. fontSize=3, frontButtonFollowOrientation=0은 그대로다.
물리 방향은 저장 readback과 별도로 확인한다. 사용자는 기존 책에서 “오른쪽 버튼이 이전 페이지로 간다”고 보고했다.
앞면 좌우 버튼인지 가로로 잡은 옆면 버튼인지, 화면 방향이 무엇인지는 확인 대기다.
옆면 설정 1만으로 앞면 버튼 오동작 원인을 단정하거나 설정을 임의로 바꾸지 않았다.

## 검증과 한계

- SD/UI 후속 변경 이전 통합 기준: 앱 전체 단위 **335/335** 통과. 렌더러 교체 후 관련 **10/10**, iOS 시험 빌드와 macOS 빌드 통과.
- 같은 이전 통합 기준: 펌웨어 전체 host **441/441**, route **11/11**, SDK 패치 **3/3**, 새 CI adapter **1/1** 통과.
  default 빌드 오류·경고 0, pinned cppcheck 2.11 직접 빌드 후 strict 검사 결함 0.
- GitHub 최근 확인 run `36226499475`는 build 성공, native tests/format/cppcheck 실패였다.
  `<cmath>`, host 포맷, native cppcheck adapter로 로컬 수정했다. 원격 CI 재실행은 푸시 후 필요하다.
- 최신 UI 스크린샷 11장과 스토어 패키지 검사 통과. iPhone UI 13개 통과.
  iPad는 공유 확장 초기 입력 대기 1회 실패 후 같은 코드 재시험 통과. 간헐 실패는 미해결이다.
  초기 순차 시험 중 새 SpringBoard crash 보고서는 없었으나, 후속 UI 시험에서는
  Xcode 결과 수집 정지와 simulator launcher Mach -308 오류가 발생했다. 재시작/재시험은
  통과했지만 개발 환경의 간헐 실패와 이전 SpringBoard crash 원인을 해결했다고 주장하지 않는다.
- X4/direct, 새 Articles 삭제·전송 취소의 물리 수용, Sync CJK 헤더의 폰트/heap,
  렌더러 내부 임시 할당의 저메모리 동작은 아직 미검증이다.

## Git과 작업 환경

- 후속 SD 관리는 펌웨어 `b818e819`, 앱 `31d21e8`, 화면 편집 개선은 앱 `af206a5`로 정리했다.
  앱 렌더러도 `b818e819`에 맞춰 재생성·출처 검증했고 관련 25개 시험과 macOS 빌드가 통과했다.
- 기능별 로컬 커밋으로 정리했다. 정확한 커밋 목록은 각 저장소 `git log`를 따른다.
  이전에 존재하던 앱 main의 로컬 17개 커밋도 푸시하지 않았다.
- 펌웨어 SDK의 `SDCardManager.h` 변경은 추적된 `scripts/storage_sdk.patch`의 적용 결과다.
  SDK 포인터나 SDK 자체 변경을 별도 커밋하지 않는다.
- 원본 백업: 앱 `.build/integration-backup-20260927-133518/`의 app/firmware/sdk.
  private 로그와 빌드 산출물은 추적하지 않는다. 새 렌더러 출처는 PIN/PROVENANCE를 따른다.
- 이 호스트는 Python LAN 접근이 차단될 수 있다. 상태 확인에 `/usr/bin/curl`을 사용한다.
  UI 시험이 이전 코드를 실행하면 별도 `.build/` derived-data 경로를 사용한다.
- 베타2 공개는 EPUB 멈춤 조사 및 수용, 원격 CI, 릴리스 체크리스트와 사용자 게시 지시 이후다.
  단순히 변경분을 정리했다는 이유로 푸시/태그하지 않는다.

[제품 후보](PRODUCT_BACKLOG.md) · [EPUB API](EPUB_ENGINE.md) ·
[펌웨어 표시 이력](../../pocket-daily-firmware/docs/SCREEN_PRESENTATION_HANDOFF.md) ·
[콘텐츠 검증 변경](../../pocket-daily-firmware/docs/CONTENT_LOAD_HANDOFF.md)
