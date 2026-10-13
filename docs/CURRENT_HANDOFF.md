# 현재 인수인계 — 2026-10-14

이 문서는 최신 인수인계 하나만 담는다. 새 인수인계를 쓸 때 이전 내용은
`docs/history/`로 옮기고 이 파일을 교체한다(약 150줄 이하). 지속되는 결정과
계약은 [PROJECT_MEMORY.md](PROJECT_MEMORY.md)에 있다. 2026-10-13까지의 기록:
[history/CURRENT_HANDOFF-to-2026-10-13.md](history/CURRENT_HANDOFF-to-2026-10-13.md).

## 현재 상태

- 앱 HEAD `005ec63`, 펌웨어 HEAD `14bf9624` + 두 저장소의 이번 회차 작업 트리 변경
  (아래, 미커밋). 펌웨어 C++ 변경은 없고 러너·문서만 바뀌었다. `freeink-sdk`의
  수정은 추적 중인 `scripts/storage_sdk.patch`와 동일하다(정상).
- 범위: Mac/X3 Same Wi-Fi 중심. 사용자 우선순위(2026-10-12)는 X4보다 X3와 앱의
  현재 기능·사용성 마감이다.
- X3 설치 펌웨어(2026-10-14, 사용자 허가로 설치): `0.1.0-dev-main-14bf9624-ble-standby-w8e68d8a9`
  (`95be13f6` 캡처 저장소 수정 포함, SHA-256 `dbe4ee91…c61d`, run `20261013T170240-a41674`).
- Mac 설치 앱: `~/Applications/Pocket Daily.app` = 이번 작업 트리의 서명된 sandboxed
  Debug 빌드(`.build/mac-signed`, 2026-10-14). 실행하지 않고 닫아 두었다.

## 이번 회차 변경 (2026-10-14)

- 0.x 이전 펌웨어 호환 제거(2026-10-03 사용자 결정):
  - "(Nearby Sync / Join a Network on older firmware)" 문구 삭제, 현재 메뉴
    Pocket Daily → Sync → Same Wi-Fi / Direct connection으로 통일.
  - 펌웨어가 더 이상 광고하지 않는 `uploadChunkBytes` 청크 업로드
    (`/upload?offset`) 경로와 필드 제거. 남은 업로드: stream(`uploadStreamPort`),
    단일 multipart + commit.
  - `sessionEnd` 없는 Direct 세션용 안내 분기 제거.
  - 유지: lineage-1(`1.0.0-*`) → 0.x 업데이트 제안(`isBeforeVersionReset`)은 그
    리더들이 0.x로 올라오는 유일한 경로. CrossPoint 안내(File Transfer → Join a
    Network)는 지원 펌웨어라 유지.
  - README, APP_STORE_REVIEW.md, appstore/review 노트·영상 체크리스트,
    CONNECTIVITY_VALIDATION, READER_FIRST_USE, TRANSFERS, CONTENT_EDITOR 갱신.
- XcodeGen 재생성 시 `PocketMac.xcscheme`가 `PocketMac.app`↔`Pocket.app`으로
  뒤집히던 문제: `project.yml`의 PocketMac에 `productName: Pocket` 추가, 재생성.
- iOS `PocketTests` 9개 실패(기존, `a8dca30` reading-first 기본값 이후 미갱신):
  `ProfileMergeTests` 4개, `HostRendererBridgeTests` 1개를 기본값과 무관한 명시적
  값으로 수정. 수정 전 HEAD worktree에서 같은 실패를 재현해 기존 실패임을 확인.

- BLE 전용 이어 읽기 자동화: `HardwareTests/ReaderContinuity.swift`의
  `bluetoothExchange`(테스트 소유 `ReaderBluetoothLink`, 격리 sync/library, 공유
  링크·LAN 감시 정지, `dev/ble-cycle?sleep=standby` → BLE 교환 → 실제 앱 BLE wake),
  러너 `--ble-continuity`(펌웨어 `dev_pipeline.py` + `check_ble_continuity` + 단위
  테스트, 앱 `verify_reader_interface.py`). 문서: 앱 DEVELOPER_PIPELINE, 펌웨어
  developer-pipeline.

## 통과한 검증 (2026-10-14)

- iOS 시뮬레이터 `PocketTests` 587개(2 skip, 0 fail), Mac `PocketMacTests` 151개
  (4 skip = 하드웨어/실 Mac opt-in, 0 fail), `validate_app_store.sh`,
  `git diff --check`. 펌웨어 host tests 935/935, `default` 빌드 경고 0.
- 물리 Mac/X3 aggregate **PASS** (작업 트리 변경 포함, 펌웨어 설치 없음):
  `python3 scripts/verify_reader_interface.py --physical-only --screen-suite --continuity-suite --real-epub --network-faults --standby`
  - aggregate `.build/interface-runs/20261013T155816-150636/report.json`,
    firmware run `20261013T155901-91d335`(실행 약 13.5분).
  - 인터페이스 10/10, 실제 Wi-Fi 단절 2건(수신 중 65536 B prefix 재개, 게시 후
    receipt 복구, 각 1회 게시), 화면·sleep/wake 캡처 14, Frankenstein 양방향
    이어 읽기 캡처 5, BLE standby 90초 후 wake(accept 2.1초), 앱 재연결 13초.
- 새 펌웨어 설치(게이트: host 935, Python 30+, cppcheck, default/standby 빌드) 후:
  - BLE 전용 이어 읽기 **PASS** `20261013T170240-a41674`(생성 EPUB, 약 9분):
    8개 leg 모두 gate open·app-wifi 복귀. 미무장 대조 lists 0/offers 0, App→X3
    BLE offer 1(2회), 수락 전 위치 불변, OCR 문단 일치, Mac Go-to 정확 위치.
    교환 지연 15–62초(재시작+standby 진입 포함), BLE 창 min heap ~62.7 KB.
  - 같은 펌웨어로 전체 회귀 재실행 **PASS** aggregate
    `.build/interface-runs/20261013T171707-939866`(firmware run
    `20261013T171736-315400`): 인터페이스 10, Wi-Fi 단절 2, 화면 14, 실제 EPUB
    HTTP 이어 읽기, BLE wake(accept 1.8초, 재연결 13.1초).

## 하지 말 것

- 리더나 Mac 앱을 reset하거나 완료된 자격 증명 흐름을 반복하지 않는다.
- 완료된 검증을 다시 하자고 사용자에게 요청하지 않는다.
- 실패한 원래 aggregate 보고서를 수정하지 않는다.
- 테스트 중 `pkill -x Pocket`을 하지 않는다(테스트 호스트도 Pocket).

## BLE 전용 시험의 경계

- 개발용 X3 standby 창만 검증했다. 책 닫기·깨우기·잠들기 전 창, X4, iPhone
  백그라운드 전달, 펌웨어 쪽 HTTP offer 카운터(추가 증거)는 아직 없다.
- 실제 EPUB(`--real-epub`)과의 BLE 전용 조합은 실행하지 않았다(HTTP 조합은 통과).

## 남은 일 — 사용자/하드웨어/결정이 필요한 것

- X4 실기기, 물리 iPhone 확대, 리더 2대 동시 연결, iCloud 실기기 간 이어 읽기.
- 광학 패널 품질, 패널 BUSY 중 버튼 입력, 이미지가 많은 EPUB.
- 밤샘/배터리 단독 standby·전류 측정, 케이블 분리 시 첫 BLE 실패 원인.
- 공유기 재부팅·DHCP 변경 중 전송, 실제 OS 거부 대화상자, 첫 부팅 물리 버튼.
- 펌웨어 `pocket-v0.1.0` 태그·릴리스, Same Wi-Fi 설치 전 Back 단계 제거.
- 출시: 새 IPA/PKG export, App Store Connect 레코드 등 계정 소유자 작업.
- 업스트림 #3813(리뷰 대기), #3814(Draft, 최종 리비전 X3 확인 필요) — 10/1 이후
  변화 없음.

## 남은 일 — 이 저장소에서 바로 할 수 있는 것

- `NearbySyncProtocolTests`의 Mac 대상 확장.
- 기존 경고 정리(`SecKeychain` deprecated, weak/strong capture, `copyBytes` 결과).
- 현지화(`.xcstrings`)와 Icon Composer 레이어 아이콘 — 제품 결정 후.

## 참고

- 실행 절차: [DEVELOPER_PIPELINE.md](DEVELOPER_PIPELINE.md),
  [READER_INTERFACE_VALIDATION.md](READER_INTERFACE_VALIDATION.md).
- 연결 수용 기준: [CONNECTIVITY_VALIDATION.md](CONNECTIVITY_VALIDATION.md).
- 펌웨어 쪽 인수인계: `../pocket-daily-firmware/docs/PROJECT_MEMORY.md`.
