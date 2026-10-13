# 현재 인수인계 — 2026-10-13

이 문서는 최신 인수인계 하나만 담는다. 새 인수인계를 쓸 때 이전 내용은
`docs/history/`로 옮기고 이 파일을 교체한다(약 150줄 이하). 지속되는 결정과
계약은 [PROJECT_MEMORY.md](PROJECT_MEMORY.md)에 있다. 2026-10-13까지의 날짜별
기록: [history/CURRENT_HANDOFF-to-2026-10-13.md](history/CURRENT_HANDOFF-to-2026-10-13.md).

## 현재 상태

- 앱 `efef528`, 펌웨어 `95be13f6` — 두 저장소 모두 `origin/main`에 반영됨.
  1차 기능 구현은 갖췄지만 출시 승인 상태는 아니다.
- 범위: Mac/X3 Same Wi-Fi 중심. 사용자 우선순위(2026-10-12)는 X4보다 X3와 앱의
  현재 기능·사용성 마감이다. 신규 백로그 기능·출시 작업은 지시가 있을 때만.
- X3 설치 펌웨어: `0.1.0-dev-main-e6eb88d5-ble-standby-wdc00da92`
  (개발 `ble_standby` 빌드, firmware run `20261013T125844-4d5717`).
- Mac 설치 앱: `~/Applications/Pocket Daily.app` = 서명된 sandboxed Debug 빌드.
  최근 onboarding 빌드는 `.build/onboarding-mac/Build/Products/Debug/Pocket.app`.
  일반 앱은 닫아 두어 리더 단독 동작을 방해하지 않게 했다.

## 최근 통과한 검증 (2026-10-13)

- 짧은 onboarding 실패/복구 aggregate **PASS**:
  `.build/interface-runs/20261013T131302-494933/report.json`,
  physical firmware run `20261013T131358-21d2ed`.
  - BLE 잘못된 네트워크 rollback, 10개 파일/인터페이스, 양방향 이어 읽기 2왕복
    (캡처 5), 화면·짧은 sleep/wake 캡처 14, 원래 상태 복원 2건.
  - Mac 회귀 139 PASS / 0 fail / 0 skip. iOS device SDK 빌드·패키지 검증 통과.
    시뮬레이터·X4·장시간 시험은 실행하지 않았다.
  - 재실행: `python3 scripts/verify_reader_interface.py --onboarding`
    (Mac/X3 강제, 펌웨어 `--x3-only`는 다른/미확인 모델을 기기 변경 전에 거절).
- 이 회차의 실제 수정:
  - 앱: 취소된 BLE 권한 요청이 늦은 radio callback을 무시, 거부/radio 상실 시
    소유권 해제, 재시도는 radio 초기화를 기다림. Wi-Fi 폼 수정 시 이전 결과 제거,
    제출한 비밀번호 삭제. 온라인 X3를 Wi-Fi에서 내리기 전 Bluetooth 준비 확인.
    단일 Wi-Fi 명령의 결과를 90초 관찰(자격 증명 재전송 없음).
  - 펌웨어: 첫 설치 reset이 `/.pocket`을 보관한 뒤 capture ticket 쓰기가 폴더를
    다시 만들지 않던 문제(HTTP 409). HAL로 디렉터리 생성 + missing-parent 회귀,
    mkdir 제거 시 실패하는 negative control(`.build/onboarding-capture-mutation.log`).
  - 짧은 책 위치 시험은 고정 5% 오차 대신 정확한 문단 문자를 확인한다
    (실측 page-start 0.4167이 예전 0.48±0.05 가정을 벗어남).
- 그 직전(같은 날) 통과한 것:
  - 초기화된 X3 + 새 Mac 앱의 BLE 첫 연결: 자동 검색 → 시스템 페어링 코드 →
    키체인 자동 채우기(사용자 승인) → BLE로 Wi-Fi 전달 → LAN 자동 발견 → Welcome
    EPUB 전송. 증거: 펌웨어 `build/first-ble-onboarding/`.
  - 일반 앱을 닫은 상태에서 OK를 누른 채 깨우면 cue를 건너뛰고 같은 본문으로
    복귀함을 사용자가 확인. 두 번째 시도는 cue가 먼저 끝남 → 패널 BUSY 중 입력은
    미확정.
  - 실제 EPUB(Frankenstein fixture, SHA-256 `d09a9d94…eb0`) import→전송→다운로드
    →재import 바이트 일치, Wi-Fi 실제 단절 2회 복구, timer deep sleep 복귀.

## 하지 말 것

- 리더나 Mac 앱을 다시 reset하거나 완료된 자격 증명 흐름을 반복하지 않는다.
  기존 reset 보관본이 남아 있다.
- 완료된 검증을 다시 하자고 사용자에게 요청하지 않는다. 작은 후속 수정은 단위
  테스트로 확인하고 다음 실행에서 드러나게 둔다.
- 실패한 원래 aggregate 보고서를 수정하지 않는다(오프라인 재감사로 PASS 처리한
  회차는 원본 실패 기록을 그대로 둔다).
- 테스트 중 `pkill -x Pocket`을 하지 않는다(테스트 호스트도 Pocket).

## 남은 일 — 사용자/하드웨어/결정이 필요한 것

- X4 실기기 수용, 물리 iPhone 확대(전송·standby·이어 읽기), 물리 리더 2대 동시 연결.
- iCloud 실기기 간 이어 읽기, BLE-only 위치 수락.
- 광학 패널 품질, 패널 BUSY 중 버튼 입력, 이미지가 많은 EPUB.
- 밤샘/배터리 단독 standby·전류 측정, 대기 중 케이블 분리 시 첫 BLE 실패의 원인
  (재탐색 복구로 3/3 통과했지만 최초 RF 미수신 원인은 미확정).
- 공유기 재부팅·단절 중 DHCP 변경 시 전송.
- 실제 OS 거부 대화상자, 첫 부팅의 Read offline/Library 물리 버튼(주입 시험과 별개).
- 펌웨어 `pocket-v0.1.0` 태그 및 릴리스(CI 이미지의 X3 짧은 확인 후).
- Same Wi-Fi에서 설치 전 Back 단계 제거(STA용 session end 제안, 펌웨어 필요).
- 출시: 새 IPA/PKG export(2026-10-09 export 이후 변경 포함), App Store Connect 레코드,
  업로드 토큰, 심사 연락처, TestFlight, 실기기 심사 영상 — 계정 소유자 작업.

## 남은 일 — 이 저장소에서 바로 할 수 있는 것

- 0.x 이전 펌웨어 호환 분기와 "on older firmware" 문구 제거(2026-10-03 사용자 결정).
- `NearbySyncProtocolTests`의 Mac 대상 확장(sandbox loopback/공유 radio fixture 정리 필요).
- 현지화(`.xcstrings`)와 Icon Composer 레이어 아이콘은 미착수 — 제품 결정 후.

## 참고

- 실행 절차: [DEVELOPER_PIPELINE.md](DEVELOPER_PIPELINE.md),
  [READER_INTERFACE_VALIDATION.md](READER_INTERFACE_VALIDATION.md).
- 연결 수용 기준: [CONNECTIVITY_VALIDATION.md](CONNECTIVITY_VALIDATION.md).
- 첫 사용 범위: [READER_FIRST_USE.md](READER_FIRST_USE.md).
- 펌웨어 쪽 인수인계: `../pocket-daily-firmware/docs/PROJECT_MEMORY.md`.
