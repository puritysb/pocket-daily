# 현재 인수인계 — 2026-10-13

## 실제 EPUB과 짧은 전체 X3 검증 — 2026-10-13

- 장시간 대기·소비전력, X4, 실기기 범위 확대는 제외하고 자동 검증했다.
  재실행: `python3 scripts/verify_reader_interface.py --physical-only --screen-suite --continuity-suite --real-epub --network-faults`.
- 실제 책은 sibling의 Standard Ebooks Frankenstein fixture: 226309 B, 38개 섹션,
  원문 XHTML 유지·이미지는 1×1 대체. 원본 해시와 이 재패키징 fixture 해시는 다르다.
  이번 fixture SHA-256은 `d09a9d94bd1076edd07a9204989ed2917bef73ad28cbd855d758641fb2e5eeb0`.
  앱 import→X3 전송→다운로드→별도 보관함 재저장까지 원본 바이트 일치.
- 실제 X3 실행 `20261012T153747-86b9c6` XCTest는 750.004초 PASS:
  인터페이스 10개, 실제 전송 Wi-Fi 단절 2개, 소설 양방향 이어 읽기 2왕복,
  X3 캡처 18개(화면 13+이어 읽기 5), timer deep sleep/복귀, 원래 데이터 복원.
  두 단절은 9.017/8.993초, 각각 앱 send 1회·publication 1회;
  수신 중 단절은 65536 B부터 재개, 최종 853319 B 원본 일치.
  슬립은 Today Brief 본문과 실제 잠자기 화면의 차이 0 픽셀(헤더/푸터 제외).
- 원래 aggregate `.build/interface-runs/20261012T153718-497253/report.json`은
  기기 실행 후 기대 fixture 해시를 원본 EPUB 메타데이터 값으로 둔 검사 오류 때문에
  실패로 보존했다. 실제 파일은 Git HEAD와 일치했다. 기대 값을 고치고 실제 fixture
  해시/크기를 대조하는 회귀를 추가했다. 기기 동작을 반복하지 않고 원래 xcresult,
  실행 로그, 18개 BMP 해시, PNG OCR을 오프라인으로 다시 검사한 최종 결과:
  `.build/x3-real-epub/final-audit/report.json` PASS. 같은 폴더 `captures/`에 이미지가 있다.
  재검증 절차는 `.build/x3-real-epub/audit.py`에 보존했다. 원래 실패 기록은 수정하지 않았다.
- 추가 보완: 개발 reader-capture의 SD 파일 한도를 64 KiB→4 MiB로 확대(새 버퍼 없음).
  가로 책 화면의 OCR 자동 회전 오독은 명시적 4방향 판독으로 해결하고 각 결과를
  독립적으로 정확한 원문과 비교한다. 근사 일치나 후보 이어붙이기는 사용하지 않는다.
  `/body` 장 경계는 첫 실제 문자의 가시성을 검사한다. 다른 장·화면 밖 문단·
  부정확한 경로는 거절하는 Mac 회귀를 추가했다. 실제 shipping 이동 오류는 없었다.
- Mac 회귀 115 PASS/0 skip, 마지막 장 경계 회귀 1 PASS;
  firmware host 922, Python 최종 134 PASS; strict cppcheck 및 default/ble 빌드
  경고 0, iOS device-SDK test build, 패키지/차이 검사 PASS. 시뮬레이터 실행 없음.
- 설치 확인: `0.1.0-dev-main-e7b1ee22-ble-standby-w75bfcee3`, SHA-256
  `b78e3ff3d97336a96789605fb6c7e76a86b8433d91d4e17fe893d9e904d15480`.
  빌드·설치 증거는 firmware run `20261012T151741-3e9f50`(이후 첫 OCR 시험은 실패).
- 이 결과는 Mac↔X3 Same Wi-Fi의 현재 기능 검증이다. iCloud, BLE-only 위치 수락,
  실제 패널 광학 촬영, 이미지가 많은 EPUB 전반, 장시간 배터리, X4 및 출시 수용은
  포함하지 않는다. 사용자 기기 조작 없이 실행했으며 커밋·푸시는 하지 않았다.
  마지막에 signed Debug 일반 앱을 다시 열어 My Reader의 X3 Same Wi-Fi 연결,
  최신 파일 목록, 기존 보류 전송/설정 초안 보존을 실제 UI로 확인했다.

## X3·앱 사용성 마감 — 2026-10-12

- 사용자 우선순위: X4 실기기 검증은 후속으로 미루고 X3와 앱의 현재 기능·사용성을
  먼저 마무리한다. 신규 백로그 기능, 출시 준비, 시뮬레이터 실행은 추가하지 않는다.
- 기기 보관함에 복사 대기 이유, 받은/전체 용량, 완료 알림과 오류/알림 Dismiss를
  표시한다. 이어 읽기 제안은 좁은 화면에서 행동을 다음 줄로 내리고 버튼 폭을
  보존한다. 320pt·긴 기기 이름 및 620pt 실제 창 버튼 시험과 이미지 확인 통과.
  Share Book File의 제목 표기도 디자인 규칙에 맞췄다.
- 전체 검증 명령에 `--continuity-suite`, `--network-faults`를 연결하고,
  ReadingSync/ReaderEngine/ReaderSuggestion/ReaderDownloadOperation 회귀를 포함했다.
  명령은 `docs/READER_INTERFACE_VALIDATION.md` 첫 절에 있다.
- 첫 통합 run `20261012T142110-6a40f8`은 pause-resume 후 다운로드 admission에서
  실패했다. 원본 fileURL을 await하는 사이 리더 작업이 재개될 수 있는데 시험은
  버튼 활성 여부를 다시 보지 않았다. 실제 UI와 동일하게 canDownloadFromReader를
  기다린 직후 요청하도록 수정했다. 거절·단절을 재시도해 숨기는 변경은 없다.
- 최종 통합 `.build/interface-runs/20261012T142550-275352/report.json` PASS.
  Mac 회귀 113 PASS, firmware hardware run `20261012T142627-a28ac2`:
  인터페이스 10개, 실제 Wi-Fi 단절 복구 2개, 양방향 이어 읽기 2왕복,
  X3 화면 13개와 이어 읽기 5개 캡처, timer deep sleep/복귀 및 모든 복원 통과.
  BLE standby 후 재연결 12.444초. pause-resume 다운로드 853319 B 원본 일치.
  iOS device-SDK build-for-testing 및 패키지/차이 검사 통과.
- Mac 캡처 6장 재생성·패키지 검사 통과. 해당 전체 Mac 실행은 119 PASS/4 skip
  (`.build/screenshots/capture-reports/20261012T144114-87028/mac-16x10.json`).
  화면 검사 후 발견한 추가 문제: root crash_report.txt 및 .1/.2/.3,
  nearby_ap_log.txt가 TXT 책으로 노출됐다. ReaderShelf에서 정확한 경로만
  제외했다. 다른 폴더의 동명 책·일반 TXT와 원본 inventory는 유지한다.
  후속 shelf/inventory 9 PASS(`.build/x3-finish/shelf.xcresult`), iOS 빌드 통과.
  이 마지막 목록 필터 변경 뒤 긴 통합 무선 시험을 반복하지 않았으며,
  최종 signed Debug 앱을 실행해 실제 X3 목록에서 제외되고 Browse Files에는
  그대로 남는 것을 UI로 확인했다. X3 Same Wi-Fi 연결 상태로 앱을 열어 두었다.
- 이 결과는 현재 기능의 Mac/X3 통합 기준이다. iPhone 실기기 확대, BLE-only
  이어 읽기·iCloud, 다양한 실제 EPUB의 X3 장기 독서, 밤샘 소비전력·광학 패널
  및 X4 수용을 대신하지 않는다. 전체 환경의 검증 완료나 출시 승인이 아니다.

## 양방향 이어 읽기 자동 검증 — 실기기 통과

- `--continuity-suite`가 Mac/X3에서 전체 통과했다:
  firmware `build/dev-pipeline-runs/20261012T135615-aea4c3/report.json`.
  사용자가 Same Wi-Fi에 연결한 뒤 IP 입력 없이 앱 자동 검색으로 발견했고,
  이후 두 왕복/다섯 캡처/정리까지 기기 수동 조작 없이 완료했다(208.494초).
- 앱→X3: shipping reading exchange와 실제 X3 확인 팝업을 사용해
  Silver meadow checkpoint 11, 이어 이전 장 Amber orchard checkpoint 11을
  제안·수락했다. X3 framebuffer BMP를 저장·재독출·OCR하여 본문 일치를 확인했다.
- X3→앱: 실제 다음 페이지 넘김과 EPUB 종료가 새 위치/sequence를 기록했다.
  두 장의 checkpoint 13 본문과 저장 위치 이후 문자를 X3 캡처에서 확인했다.
  앱을 다른 장에 둔 뒤 실제 Go-to 버튼에 로컬 창 마우스 이벤트를 보내,
  제안한 정확한 XPointer 문자가 앱의 visible range 안에 들어왔음을 검사했다.
  양쪽 모두 수락 전 위치 불변, 최신 뒤 방향 제안 수락까지 통과했다.
- 원래 독서 위치·recent 순서·파일 inventory 복원, 테스트 책 제거 통과.
  다섯 X3 BMP/PNG와 앱 수락 화면은 위 run의 `macOS-hardware-1-continuity/`에
  export했고 BMP SHA-256도 대조했다. 광학 패널 촬영을 뜻하지 않는다.
- 시험 경로에서 발견한 문제를 수정했다: HTTP_ANY 미지원에 따른 개발 endpoint
  404를 명시적 POST/GET/DELETE 등록으로 해결, 실패 시 독립적인 정리 시도,
  off-screen SwiftUI AX children 부재를 실제 화면 OCR/창 이벤트로 해결했다.
  페이지 시작 비율과 목표 비율 차이, 문단 중간 페이지 시작을 고려해 검증했다.
  이번 범위에서 shipping 앱의 이어 읽기 오류는 발견하지 않았다.
- 설치 확인 버전: `0.1.0-dev-main-e7b1ee22-ble-standby-w65c15eca`.
  소스는 두 저장소 main의 미커밋 변경이다. 재실행:
  `python3 ../pocket-daily-firmware/scripts/dev_pipeline.py run --app "$PWD" --continuity-suite`.
- Mac 전체 `.build/continuity/mac-final.xcresult`: 119 PASS, opt-in 3 skip.
  ReaderSuggestionTests 단독 1 PASS; firmware XPointer 430개 본문 교차 확인.
  iOS device SDK build-for-testing 통과, 시뮬레이터 사용 없음.
  펌웨어 host 921, Python 133, strict cppcheck, default/ble_standby 빌드 통과.
- iCloud, BLE-only 이어 읽기, iPhone/X4, 다양한 실제 EPUB 및 광학 패널은 별도다.
  이번 결과는 생성 EPUB 두 왕복의 Mac/X3 HTTP 경로 검증이며 출시 승인이 아니다.

## 다운로드 완료 보장 및 실제 전송 Wi-Fi 단절 — 2026-10-12

- 다운로드 시작 불가 및 reader lane에서 실행 전 취소되는 경로가 completion
  없이 끝날 수 있음을 코드에서 확인했다. 요청별 완료를 한 번으로 보장하고
  queued/fetching/busy/saving/verifying/terminal 단계, 바이트·요청 수·오류 코드,
  실패 직전 단계와 경과 시간을 기록한다. 원래 120초 사건과의 인과관계는 아직
  확정하지 않는다. 파일명·본문·네트워크 주소·기기 ID는 진단 카운터에 없다.
- 개발 펌웨어 one-shot `dev/network-fault`와 runner `--network-faults` 추가.
  Mac 네트워크/공유기를 건드리지 않고 X3의 실제 Wi-Fi association을 해제,
  5초 뒤 저장된 네트워크로 복귀시킨다. 60초 arm 만료, 크기/실행 ID/주입 지점
  검증, 중복 arm 거부, production 제외. default 정적 RAM 증가 40B, 별도 지속 힙 없음.
- 실제 run `20261011T173129-98ca79` PASS. 설치 확인 버전
  `0.1.0-dev-main-89d8310c-ble-standby-w079b67ca`.
  수신 중: 65536B에서 끊김, 실제 offline/복귀 8979ms, 동일 prefix에서 resume.
  저장·receipt 완료 후: 성공 응답 직전 끊김, offline/복귀 9020ms.
  두 경우 모두 appSendAttempts 1, 첫 job 상태 completed, publications 1.
  사용자/하네스 재시도 없이 shipping app의 복구 경로로 완료했다.
- 853319B 원본과 다운로드를 바이트 비교했고 단절 후 다운로드는 각각
  16.38/16.26초였다. 6개 다운로드 모두 requests/bytes/terminal 증거와
  callbacks 1을 확인. 기존 인터페이스 10개 및 최종 inventory 보존 통과.
- 펌웨어 host 920, Python 131, strict cppcheck, default/ble_standby 빌드 통과.
  default RAM 69760B/flash 6396851B, standby RAM 69976B/flash 6408039B.
  Mac 다운로드 집중 테스트 10개, 전체 Mac 100 PASS/3 opt-in skip 및
  iOS device-SDK 빌드 통과. 양쪽 diff 검사 통과.
  원본 증거는 형제 `build/dev-pipeline-runs/20261011T173129-98ca79/`,
  앱 `.build/network-recovery/`에 보관. 기기/케이블 조작 요청 없음.
- 이 결과는 X3 association loss와 commit ACK loss의 수용이다. 공유기 재부팅,
  단절 중 DHCP 주소 변경, SD 물리 고장, 장시간 대기·전류, iPhone/X4는 별도다.

## 전체 회귀 점검 — BLE 원인 반복 시험 중단 후

- 시뮬레이터 없이 Mac 전체 타깃 96 PASS/3 opt-in skip, 펌웨어 host 916 PASS,
  Python 전체 130 PASS, 앱 Python 2 PASS. cppcheck 2.11, default 빌드,
  iOS device-SDK build-for-testing, App Store 소스 패키지 검증 및 양쪽 diff 검사 통과.
  iOS 테스트 실행·iPhone/X4 확대·출시 작업은 하지 않았다.
- 전체 Python 검색에서 경계 검사 실패를 발견했다. 개발 캡처에 필요한
  `RenderLock` 의존성만 명시하고 미사용 `ScreenshotUtil` include를 제거했다.
  펌웨어 `--checks`도 일부 파일만이 아닌 `scripts/test_*.py` 전체를 실행한다.
- 첫 실기기 `20261011T162812-ca3f95`: BLE 대기 후 Wi-Fi 복귀 12.448초와
  잘못된 Wi-Fi 설정의 기존 네트워크 복원 통과. pause/resume 이후 다운로드
  고정 120초 제한에서 실패했다. 시험에 시작 가능 여부 확인, 바이트 진행에
  따른 45초 정지 감지, 크기별 총 제한과 다운로드 소요 시간 기록을 추가했다.
- 최종 `20261011T163609-3fc6ac` PASS: 인터페이스 10/10, 화면 13장 픽셀·OCR,
  카드/설정/독서 기록 원상 복원, 실제 timer deep sleep/자동 복귀 통과.
  853319B 파일을 재개 후 17.061초, 취소 후 보존 확인에서 17.313초에 다시
  다운로드하여 원본과 비교했다. 첫 timeout은 재현되지 않았고 발생 원인은
  미확정이다. 단순 시간 제한 문제로 확정하거나 제품 결함 해결로 주장하지 않는다.
- 비공개 통합 결과: `.build/full-regression/summary.json`; 원본 로그·xcresult·
  캡처는 해당 폴더와 위 firmware run 폴더에 유지한다. 실물 패널 광학 품질,
  전류 측정, iCloud 실기기 간 교환 등 기존 미검증 범위는 그대로다.
  default flash 97.6% 사용. 추가 케이블 조작·펌웨어 설치·커밋·푸시는 없었다.

## 실제 광고 지연 주입·대조군 — 최초 원인은 여전히 미확정

- 후속 `20261011T151925-d3c4f6`에서 **기존 요청 유지 + 스캔 추가 방식도 실패**했다.
  실제 scan 시작 8.048초, 광고 전달 0개, connecting 20초 timeout. 펌웨어 광고
  시작 기록 106077ms, 배터리 100%, gate open, 최종 `time-up` 180021ms였다.
  이후 Mac 배경 링크는 00:22:17에 새 connect를 요청해 00:22:21에 GATT를
  열고 독서 교환을 했다(기기 connections 1/lists 1). 리더 전체 멈춤은 아니다.
  실패한 스캔을 성공으로 처리하지 않으며, 재탐색만 추가한 최초 보완은 불충분했다.
- 이를 근거로 **명령 전 한 번의 cancel → 취소 callback → scan → 동일 UUID
  광고 → 새 connect**로 수정했다. 전체 deadline 20초와 명령 1회는 유지한다.
  취소 완료 전 광고/연결 callback, 중복 광고, timeout 뒤 callback은 새 명령을
  유발하지 않는다. 단계 순서 및 늦은 Bluetooth 준비 경계까지 Mac 43개 통과.
  새 방식 `20261011T152735-7c55e9` **3/3 PASS**: scan 8.053/8.033/8.054초,
  광고 16.224/17.110/10.263초, 새 연결 17.827/18.704/11.890초,
  수락 18.122/19.026/12.207초. 매회 cancel 요청·취소 callback·광고 후 connect
  각 1회, 명령 1회, Wi-Fi 포함 재연결 30.275/31.380/25.290초.
  각 `app-wifi`/연결 1회/READ_LIST 0회, EPUB 2856B 비교·삭제·idle 복귀 통과.
  minFree 64440/64432/64512B, minBlock 55284B, 배터리 100%·비충전.
  이 결과는 재현된 지연의 새 복구 경로 수용이며, 최초 케이블 사건의 RF 미수신
  원인이 완전히 확정됐다는 의미는 아니다. 연결 요청이 성립하지 않는 구간에
  대한 복구 결함과, 첫 광고를 못 받은 외부/무선 원인은 분리한다.
- 최종 일반 대기 `20261011T153650-823ed8` **PASS**. 광고 지연 0/start 85ms로
  one-shot fault 잔류 없음, BLE 연결 1.235초/수락 1.523초, Wi-Fi 포함 13.296초,
  standby 99725ms/light sleep 81076ms, `app-wifi`/연결 1회/READ_LIST 0회.
  minFree 64456B/minBlock 55284B, 충전 확인 true·배터리 100%, EPUB 2856B
  비교·삭제·idle 복귀 통과. 최종 iOS device-SDK build-for-testing 및 diff 검사 통과.
  실험 중 추가 케이블 조작은 요청하지 않았다. 실제 iPhone/X4·무선 패킷 수신
  원인 규명·장시간 전류 측정은 미검증이며 커밋/푸시는 하지 않았다.

- 개발용 `--delayed-advertising`을 구현했다. 앱 callback을 가짜로 지연시키지 않고
  X3의 BLE startup/advertiser를 standby wait + 16초까지 보류한다. 배터리·버튼·
  time-up 복구는 유지하며, production에는 없고 다음 일반 대기에 남지 않는다.
  실제 스캔/동일 기기 광고/연결/인증/명령 1회/수락의 순서와 20초 제한을
  앱·runner에서 검사한다. `--wake-control`은 시험 scheduler에서 재탐색만 제거한다.
- 설치 확인: `0.1.0-dev-main-5610af50-ble-standby-w244dc28a`.
  전체 host 916개, 검증기 35개, 관련 Mac 43개 통과. default/ble_standby 빌드
  오류·경고 0과 strict cppcheck 통과. iOS는 device SDK 빌드이며 실기기 실행 아님.
- 첫 실제 복구 `20261011T150000-193aa5` **PASS**. 광고 시작 106088ms,
  앱 wake 기준 scan 8.096초 → 동일 기기 광고 13.214초 → 연결 14.020초 →
  인증 14.261초 → 명령 수락 14.321초. Wi-Fi 포함 재연결 25.749초,
  `app-wifi`/BLE 연결 1회, EPUB 2856B 왕복·삭제·idle 복귀 통과.
  OS도 high scan 만료/low scan 전환 뒤 앱 `CBMsgIdScan`, 광고 1개 전달,
  연결 후 stop scan을 기록했다. 테스트 callback만 흉내 낸 결과가 아니다.
- 대조군 `20261011T151143-ca5c59`도 **2/2 연결 성공**. 같은 106초 광고 지연,
  재탐색 없음, 연결 15.125/14.707초, 수락 15.441/14.994초, 파일 검증 통과.
  따라서 이번 실험은 재탐색 경로 동작을 증명하지만, 재탐색 부재가 최초 실패의
  근본 원인이라는 가설을 증명하지 않는다. 최초 RF 수신 실패/광고 상태의 원인은
  당시 관측 부족으로 미확정이다. 성공한 대조군을 실패 재현으로 포장하지 않는다.
- 최초 로그의 `locked: 1`은 Bluetooth scan request 필드이며 Mac 잠금 증거로
  사용할 수 없다. 잠금 원인 추정은 철회한다. 일반 standby에서도 wake 단계
  기록을 수집하도록 변경했다. 별도로 Bluetooth 준비가 늦으면 8초 timer가
  connecting 이전에 소진되던 경계 조건을 수정·단위 검증했다. 이는 최초 실패의
  원인이 아니다(당시 Bluetooth 준비는 즉시 완료).

## 케이블 분리 실패 조사·연결 복구 보완 — 3회 통과, 인과 검증 미완료

- 첫 실패의 macOS Bluetooth 로그에서 pending connect의 고빈도 탐색이 만료된 뒤
  낮은 빈도(480/48)로 전환되고 앱의 20초 제한으로 취소된 것을 확인했다.
  기기 기록은 390초 동안 gate open/연결 0회 후 `time-up` 복구였다.
  배터리 보호·크래시 증거는 없으며, 케이블 분리 자체와의 인과관계는 미확정이다.
  당시 scan request의 locked 필드는 실제 Mac 잠금 증거가 아니다(위 정정 참고).
- foreground `ReaderWakeConnector`가 8초 뒤에도 connecting이면 기존 pending
  연결을 유지하면서 해당 서비스만 제한적으로 탐색하도록 보완했다. 전체 제한
  20초는 그대로이며 다른 기기 선택·재페어링·connect/명령 재전송은 없다.
  연결·취소·실패·timeout에 탐색을 종료한다. 배경 독서 링크는 여전히 스캔하지 않는다.
- 관련 Mac 테스트 41개 및 iOS device-SDK build-for-testing 통과.
- 수정 앱의 같은 조건 재시험 `20261011T142042-2bbce1` **PASS**. 사용자가
  시작 전 연결/대기 marker 후 분리를 확인했다(비공개 power confirmation).
  300초 요청/312186ms 실제 standby, light sleep 253857ms, 배터리 100%·비충전,
  `app-wifi`/연결 1회/READ_LIST 0회, 앱 재연결 13.724초. minFree 64476B,
  minBlock 55284B, 목록 18건, EPUB 2856B 비교·삭제·idle 복귀 통과.
  재탐색 fallback 실행 증거는 확보하지 못했다. 정상 경로 통과만으로 변경의
  인과적 효과나 최초 간헐 실패의 완전 해결을 주장하지 않는다.
- 추가 실행 `20261011T143106-f648e6` **2/2 PASS**. 첫 회차 대기 marker 뒤
  사용자가 케이블 분리를 확인했고 두 번째는 계속 분리된 상태에서 시작했다.
  300초 대기 각각 재연결 13.001/13.450초, standby 309596/311885ms,
  light sleep 252097/253841ms, 배터리 100%·비충전. 각 `app-wifi`, BLE 연결 1회,
  READ_LIST 0회, 목록 18건과 EPUB 2856B 비교·삭제·idle 복귀 통과.
  minFree 64440/64428B, minBlock 모두 55284B. 총 수정 후 3/3이며
  대기 중 분리 2회, 처음부터 배터리 단독 1회다. 자동 time-up 복구가 아니다.
- 이 회차들에서는 최초 connecting timeout이 재현되지 않았다. 현재 판정은
  동일 조건 회귀 통과 + 연결 지연 복구 보완이며, 원인 확정/완전 해결은 아니다.
  후속 증거는 실제 지연 시 서비스 재탐색 실행과 동일 대상 광고·연결 관측이다.
  장시간 배터리 단독/밤샘, 전류 측정, 물리 iPhone/X4는 이번 검증 범위 밖이다.
  기기 펌웨어 재설치는 하지 않았다. 변경은 아직 커밋/푸시하지 않았다.

## 물리 케이블 분리·배터리 시험 — 2026-10-11 결과

- 사용자 요청으로 대기 중 케이블 분리 후 BLE 재연결과 배터리 단독 대기를
  검증했다. 추가한 `--battery-only`는 앱과 runner 양쪽에서 비충전 체크포인트와
  배터리 10% 초과를 요구한다. 첫 `POCKET_STANDBY_READY` 후 사용자가 케이블을
  분리했다고 명시적으로 확인했으며, 확인 기록은 첫 실행의 비공개
  `physical-power-confirmation.json`에 있다. 초기 충전 정보는 직전 trial의
  기록이지 새로운 실시간 전력 측정은 아니다.
- 첫 시험 `build/dev-pipeline-runs/20261011T135258-8e4f7e/report.json` **FAIL**.
  300초 앱 무통신 대기 후 BLE connecting 단계 timeout. 기기의 해당 run은
  배터리 100%, `chargingAtCheckpoint:false`, BLE connections 0, gate open,
  minFree 64560B/minBlock 55284B, standby 390024ms/light sleep 324210ms,
  종료 `time-up`을 기록했다. 390초 복구 제한으로 스스로 Same Wi-Fi에 복귀해
  실패 기록을 회수했다. crashReportAvailable false. 자동 복귀를 BLE wake
  성공으로 계산하지 않는다. 예정했던 두 회차 중 첫 실패로 pipeline이 중단돼
  두 번째 회차는 실행되지 않았다.
- 케이블을 계속 뺀 상태의 별도 300초 시험
  `build/dev-pipeline-runs/20261011T140115-d05c3d/report.json`은 **PASS**.
  배터리 100%, 비충전, standby 311678ms/light sleep 253735ms,
  `app-wifi` 종료/BLE 연결 1회/READ_LIST 0회, 앱 재연결 13.210초.
  minFree 64484B/minBlock 55284B, 목록 18건, EPUB 2856바이트 왕복 비교·삭제·
  전송 idle 복귀 통과. 사용자 추가 조작/펌웨어 재설치 없이 자동 완료했다.
- 결론: 처음부터 케이블이 빠진 상태에서의 5분 대기·BLE 복귀는 통과했다.
  대기 중 케이블 분리 시험의 첫 BLE 연결 실패는 미해결이다. 두 조건 각 1회의
  결과로 USB 분리 자체가 원인이라고 단정하지 않는다. 다음 조사는 해당
  전환 조건의 재현과 BLE 연결 전 단계 관측이며, 단순 timeout 확대나
  저배터리 기준 완화를 해결책으로 간주하지 않는다. 밤샘·전류 측정은 미검증.
- 검증기 Python 32 tests와 Mac/iOS device-SDK build-for-testing 통과.
  시뮬레이터 및 물리 iPhone 실행 없음. 원인은 저배터리로 단정할 수 없으며
  BLE 연결 성립 전 단계의 실패로 좁혀졌다. 펌웨어 수정/해결을 주장하지 않는다.

## 커밋 후 X3 반복 대기·깨우기 3회 완료 — 2026-10-11

- 자동 IP 검색 변경을 앱 `fb0629a`, 펌웨어 도구 `5d512c56`으로 각각
  `origin/main`에 푸시한 뒤 기본 enrollment로 실행했다.
  `python3 ../pocket-daily-firmware/scripts/dev_pipeline.py run --app "$PWD" --standby --cycles 3`
- 형제 `build/dev-pipeline-runs/20261011T122403-b8cecb/report.json`: **3/3 PASS**.
  매회 90초 앱 무통신 대기 후 기존 앱 Connect/BLE wake로 복귀.
  재연결 13.007 / 13.246 / 14.573초, 실제 standby 99.623 / 99.585 / 99.703초,
  light sleep 81.025 / 80.746 / 80.750초. 매회 `app-wifi` 종료,
  BLE 연결 1회/READ_LIST 0회, 자동 앱 통신 중단 증거 통과.
- 각 회차 파일 목록 18건, 생성 EPUB 2852 / 2856 / 2856바이트 왕복 동일성,
  테스트 파일 삭제·전송 idle 복귀 통과. BLE 최소 free heap은
  64452 / 64444 / 64432B, 최소 최대 연속 블록은 모두 55284B로 기준 충족.
  세 번의 샘플만으로 장기 메모리 누수 부재를 주장하지 않는다.
- 배터리 25 / 25 / 26%, 모두 충전 확인 true. 사용자 기기 조작·시뮬레이터·
  펌웨어 재설치 없이 완료했고 수정이 필요한 실패는 없었다.
  배터리 단독/밤샘 대기, 물리 케이블 분리·임계값 통과, 소비전류 측정,
  실제 양방향 독서 위치 제안 수락은 여전히 별도 미검증이다.
- `CONNECTIVITY_VALIDATION.md`의 과거 설치 기준을 역사적 기록으로 표시하고
  충전 확인 시 5% 초과라는 현재 조건을 반영했다.

## Wi-Fi 변경 후 IP 입력 없는 검색 — 2026-10-11

- 이전 IP가 응답하지 않거나 다른 기기이면 펌웨어 runner가 실제 Mac Debug 앱의
  Connect 경로(Bonjour/현재 LAN 검색/기존 bond BLE wake)로 등록된 리더를 찾는다.
  앱 admission에서 신원·STA·개발 펌웨어를 검사하고 runner가 HTTP 신원/버전을
  다시 확인한 뒤 host만 원자적으로 갱신한다. 실패 시 enrollment는 보존된다.
- 자동화 변경은 `HardwareTests/ReaderHardwareTests.swift`와 형제 저장소의
  `scripts/dev_pipeline.py`, `scripts/test_dev_pipeline.py`에 있다. 기기 펌웨어나
  shipping 앱의 통신 구현 변경/재설치는 필요하지 않았다.
- 첫 실기기 PASS: 형제 `build/dev-pipeline-runs/20261011T121552-cbe0f1/report.json`.
  앱과 runner 양쪽에 이전 네트워크 주소를 넣은 별도 비공개 설정으로 시작,
  실제 앱 검색 24.696초 후 현재 X3 발견. 사용자의 IP 입력 없이 신원 확인,
  목록 18건, 생성 EPUB 2856바이트 왕복 비교/삭제/전송 idle 복귀까지 통과.
  시험 중 공유기 자체를 전환한 것은 아니며, 이미 바뀐 네트워크에서 오래된
  주소와 캐시로 시작하는 복구 경로를 검증했다.
- 최종 실기기 PASS: 형제 `build/dev-pipeline-runs/20261011T121809-dab6d8/report.json`.
  오래된 주소에서 재검색한 뒤 `--standby`까지 자동 연속 실행. 요청 대기 90초,
  실제 standby 101,676ms / light sleep 82,657ms, `app-wifi` 종료, BLE 연결 1회,
  READ_LIST 0회, 앱 재연결 18.975초. 생성 EPUB 2852바이트 왕복 비교·삭제와
  파일 목록 18건·전송 idle 복귀 PASS. 배터리 24%, 충전 확인 true.
  정상 설정을 훼손하지 않도록 별도 비공개 설정을 사용했으며, 새 host 저장도
  확인했다. 다음 실행은 기본 enrollment 설정으로 IP 인자 없이 수행하면 된다.
- Python 개발 도구 31 tests PASS (`.build/rediscovery-python-final.log`).
  주소 재할당/누락·다른 신원/오래된 결과/중복 결과/timeout/실패 시 설정 보존과
  새 주소를 다음 실제 앱 검증 단계에 넘기는 흐름을 검사한다.
  iOS device SDK build-for-testing PASS (`.build/rediscovery-ios-final.log`).
  시뮬레이터 및 물리 iPhone 실행은 하지 않았다.
- 최초 enrollment와 OS 권한/bond는 필요하다. 리더가 새 Wi-Fi를 모르면 앱의
  Wi-Fi 설정으로 먼저 저장해야 한다. 전원 꺼짐/deep sleep/BLE 저전력 차단,
  AP isolation 등 통신 불가 상황까지 자동 복구된다고 주장하지 않는다.

## X3 30분 무통신 대기·BLE 깨우기 완료 — 2026-10-11 20:30 KST

- 실제 Mac/X3 PASS: 형제 저장소
  `build/dev-pipeline-runs/20261011T105840-d292e9/report.json`.
  실행: `python3 ../pocket-daily-firmware/scripts/dev_pipeline.py run --app "$PWD" --standby --standby-seconds 1800`.
  새 Wi-Fi에서 기존 리더 신원을 확인하고 로컬 시험 설정을 갱신했다.
- 앱 LAN monitoring과 자동 BLE 독서 교환을 중단한 채 1800초 기다린 뒤
  정상 Connect 경로로 깨웠다. 사용자 리더 조작 없이 대기→깨우기→LAN 복귀,
  파일 목록과 생성 EPUB 2856바이트 왕복 원본 비교·삭제·전송 상태 복귀 통과.
- 기기 실측: standby 1,807,465ms, light sleep 1,472,430ms/63,766회,
  BLE 연결 1회, READ_LIST 0회, 종료 `app-wifi`, gate `open`.
  앱 재연결 12.223초. 마지막 체크포인트 배터리 19%, 충전 확인 true.
  최소 free heap 64,504B, 최대 연속 블록의 최솟값 55,284B,
  framebuffer 52,272B 회수 확인. 대기 중 앱 교환 시각 불변·phase off도 검사했다.
  단일 30분 시험이며 밤샘·소비전류·물리 케이블 분리 시험으로 확대 해석하지 않는다.
- 이전 실패 당시 사용자가 충전 케이블이 빠져 있었다고 확인했고 마지막
  보존된 배터리 샘플은 10%였다. 비충전 BLE 허용 조건은 **10% 초과**이므로
  배터리 보호에 따른 deep sleep이 가장 유력하다. 당시 종료 사유 기록이 없어
  역사적 원인을 확정하지 않는다. 보호 기준은 변경하지 않았다.
- 개선: 펌웨어의 저배터리 종료를 `time-up`과 구분한 `low-battery`로 기록하고,
  개발 체크포인트에 충전 여부·요청별 복구 제한을 보존한다. 앱 진단과 BLE
  깨우기 실패 안내에는 충전 후 전원 버튼으로 한 번 깨우는 복구 방법을 추가했다.
  시험 시간 90..1800초, 복구는 요청 시간+90초. 단기 기록·잘못된 복구 제한·
  자동 교환 중단 증거 누락은 장시간 시험 PASS가 될 수 없다.
- 설치 펌웨어: `0.1.0-dev-main-c2290a4a-ble-standby-w7d1b869f`, SHA-256
  `77a296f88ec8c6b43d65abb099ecd49861e065538d8c3319864a5c67f1db3ba5`.
  host renderer `build/apple-host-1so4z9xs` 반영. 펌웨어 915 host tests,
  runner 16 tests, 라우트/업로드, cppcheck, default/ble_standby 빌드 통과.
  변경 함수 스택 64/176/208바이트.
- Mac 회귀는 `.build/long-standby-regression.xcresult`와
  `.build/long-standby-resume-regression.xcresult`를 중복 없이 합산해 84 PASS.
  초기 EPUB 샘플 skip은 환경변수를 지정한 재시험으로 해소했다. 파일 목록·
  다운로드 3개 테스트 클래스도 `verify_reader_interface.py`에 추가했다.
  iOS 기기 SDK 앱 빌드 및 공유 시험 코드 build-for-testing 성공
  (`.build/long-standby-ios-harness-confirm.log`). 시뮬레이터/물리 iPhone 실행 없음.
  기존 URLProtocol Sendable 등 컴파일 경고는 이번 수정 범위 밖이다.
- 테스트 실행 파일과 SHA가 같은 sandboxed Mac 앱을 서명 검증 후
  `/Users/puritysb/Applications/Pocket Daily.app`에 설치·실행했다. 실제 UI에서
  Same Wi-Fi 연결, 최신 목록, 저장 편집, 기존 일시정지 작업 보존을 확인했다.
  이전 앱은 `.build/app-backups/long-standby-20261011/`에 보존했다.
- 중단 이력: `20261011T070704-572970`은 매분 BLE 교환 때문에 진정한 무통신
  시험이 아님을 발견해 중단했고, 일반 앱으로 자동 복귀했다.
  `20261011T071654-83efd0`은 사용자의 Mac 잠자기 요청으로 약 5분에 중단했다.
  둘 다 장시간 PASS로 인용하지 않는다. 최신 기준은 위 완료 실행이다.
- 커밋 정리: 펌웨어 변경을 `99e3d6a7`에 고정하고 host renderer를
  `build/apple-host-r7ve89gq`로 재생성·반영했다. 장시간 실기기 검증 당시의
  설치 아티팩트와 원래 기록은 위에 그대로 보존한다. SDK 자동 적용분은
  `scripts/storage_sdk.patch`와 일치함을 확인한 뒤 역적용해 서브모듈을 정리했다.
  최종 렌더러 반영 후 `.build/long-standby-commit-regression.xcresult`에서
  Mac 84개 전부 재통과했고 iOS 기기 SDK 빌드도 통과했다.
  iPhone/X4 확대와 출시 준비는 사용자 지시대로 보류한다.

## X3 실제 화면·독서·잠자기 자동 검증 — 2026-10-11

- 최종 전체 PASS: 형제 저장소
  `build/dev-pipeline-runs/20261011T011839-f8c099/report.json`.
  실행: `python3 ../pocket-daily-firmware/scripts/dev_pipeline.py run --app "$PWD" --build-firmware ble_standby --flash --standby --interface-suite --screen-suite`.
  실제 Mac/X3만 사용했고 시뮬레이터는 실행하지 않았다.
- 인터페이스 10개, 실제 화면 13장(Home/Brief 8, 카드 3, EPUB 본문 1,
  실제 잠자기 1)을 통과했다. 개발 펌웨어가 렌더 완료 후 framebuffer를 SD BMP로
  저장하고, 앱이 회수해 디스크에서 다시 읽고 SHA-256·픽셀·로컬 Vision OCR로
  검증한다. XCTest 첨부파일은 같은 실행의 `macOS-hardware-1-screens/`에 있다.
- 카드 A→B→A는 전송한 128×96 이미지와 정확히 일치하고, 복원 차이 0이다.
  앱이 만든 EPUB을 실제 기기 reader에서 열어 세 문단을 OCR로 확인한 뒤 자동
  Same Wi-Fi 복귀한다. 실제 deep sleep은 같은 실행 번호의 타이머 진입/기상
  기록과 잠자기 캡처를 함께 요구한다. 기존 카드·프로파일·독서 목록·파일 보존,
  테스트 EPUB/캡처 삭제까지 통과했다.
- X3 BLE 배터리 기준은 충전 전류가 확인될 때만 5% 초과, 그 외 10% 초과다.
  BQ27220 읽기 실패·0/음수 전류는 완화하지 않는다. 대기 중 USB 상태 변경과
  60초 주기에 재검사한다. 실제 9%에서 90초 대기 후 앱 BLE 깨우기 및 LAN 복귀
  통과(12.876초), 자동 light sleep 누적 65.897초. 물리 케이블 분리 시험이나
  소비전류 측정은 하지 않았다. 조건 전환은 결정적 테스트로 검증했다.
- 이번에 수정한 검증기 문제: 흰 여백 이미지 탐색의 긴 main-actor 점유를 ink
  선검사로 해소했고, 재부팅에 따라 커지는 `/agentdeck.log`의 크기만 파일 복원
  비교에서 제외했다. 로그 존재 여부와 다른 모든 파일의 경로/크기는 계속 검사한다.
  실패 시 복원 단계도 각각 실행하고 원래 오류와 복원 오류를 모두 보존한다.
- 펌웨어 호스트 914개, 파이프라인/라우트/업로드 검사, cppcheck, default 및
  ble_standby 빌드 통과. Mac 이미지/보존 검사 6개, iOS 기기 SDK 빌드 통과.
  iOS 빌드는 실기기 실행 증거가 아니다.
- 설치 버전: `8925b142-ble-standby-w3f7e719b`, SHA-256
  `41ad9276c0240b221e9628764fd4f04ba62a04b1cebd1f3ef7ecbee4784d36bf`.
  하드웨어 시험은 host renderer `apple-host-ezx0ib2o` 기준이다. 최종 코드 정리 후
  동일 제품 소스를 펌웨어 `c2290a4a`에 고정한 `apple-host-phhli1gk`를 재생성·반영했다.
  최종 Mac 앱을 서명 확인 후 설치·실행했고 X3 Same Wi-Fi 연결과 보관함,
  저장된 편집, 기존 일시정지 작업 보존을 실제 UI에서 확인했다.
- 경계: framebuffer 검사는 광학 잔상·패널 손상 측정이 아니다. EPUB 첫 fixture
  페이지를 검사하며 모든 책/글꼴/방향/페이지 넘김이나 물리 버튼까지 보장하지 않는다.
  iPhone/X4 범위 확대와 출시 준비는 사용자 지시로 보류한다.

## 최종 코드 정리 — 2026-10-11

- 10:50 KST 최종 앱 재실행 후 Connect는 성공하지 않았다. 실제 앱 로그는
  BLE `connecting` 단계 시간 초과이며 LAN에서도 리더를 찾지 못했다. 당시
  물리 화면·전원 상태는 관찰하지 못해 원인을 확정하지 않았다. 위의 자동
  실기기 PASS와 별개인 마지막 연결 관찰이며, 최신 앱 재연결 성공으로 인용하지 않는다.
- 펌웨어: 저장소 접근 수정 `b1f27f79`, X3 연결·자동 검증 `c2290a4a`를 main에
  fast-forward 반영했다. 외부 SDK 수정은 `scripts/storage_sdk.patch`로 재현하며
  서브모듈에 별도 커밋을 만들지 않는다. 로컬 `.agents/`는 보존하되 추적하지 않는다.
- 앱: Wi-Fi 설정, BLE, 파일 목록과 화면 검사 단위 테스트를 Mac 타깃 및
  `verify_reader_interface.py --physical-only`에 연결했다. Mac 테스트 83개 전부
  통과했고 테스트의 main-actor 격리 경고도 수정했다. 시뮬레이터 실행은 없다.
- 아래 항목은 이전 단계의 시험 이력이다. 당시 미커밋/실패/보류 표기는 해당
  시점의 기록이며 현재 기준은 위의 최종 자동 검증과 코드 정리 항목이다.

## 현재 Wi-Fi 이름 자동 채우기 — 2026-10-10

- 사용자 지시: 이후 검증은 시뮬레이터를 사용하지 않고 실제 Mac/iPhone/리더에서
  수행한다. iPhone 캡처 4개는 완료됐으나 iPad 캡처가 정체돼 중단하고 해당
  시뮬레이터를 종료했다. 이 실행을 전체 스크린샷 갱신 완료로 인용하지 않는다.
- Reader Wi-Fi의 Use Current Wi-Fi 버튼에서만 현재 SSID 조회/위치 권한을
  요청한다. Mac은 CoreWLAN, iOS/iPadOS는 NEHotspotNetwork.fetchCurrent와
  Access Wi-Fi Information을 사용한다. iOS는 Precise Location 승인이 필요하지만
  좌표를 읽거나 위치 업데이트를 시작하지 않는다. 거부/조회 실패 시 수동 입력을
  유지하고 취소된 조회는 화면에 값을 쓰지 않는다. 다른 SSID로 채우면 기존 비밀번호를 지운다.
- 서명된 sandboxed Mac 앱을 설치해 실제 현재 SSID 자동 채우기를 확인했다.
  sandbox/location entitlement 유지도 확인했다. iOS 관련 10개 단위 테스트와
  권한 팝업 없이 폼을 여는 UI 테스트 1개 통과:
  `.build/tests/Logs/Test/Test-Pocket-2026.10.10_23-15-25-+0900.xcresult`.
- Apple Wi-Fi Infrastructure의 일반 고객 배포는 EU 계정 + EU 내 기기로 제한된다.
  Accessory Transport Extension은 iOS 전용이다. 한국/전 플랫폼 자동 비밀번호
  공유로 설명하거나 노출하지 않는다. Mac의 공개 CWKeychainFindWiFiPassword는
  실제 sandboxed 앱에서 인증 UI 비활성 시 -25293, 허용 시 성공(0, 비밀번호 존재)을
  확인했다. 현재 네트워크에 한해 Use Current Wi-Fi에서 호출하고, 실패 시 수동
  입력을 제공한다. 값 자체는 진단에 기록하지 않았다. 증거:
  `.build/current-wifi-password-{probe,prompt}.xcresult`.
  2026-10-11 실제 설치 앱에서도 자동 채우기 완료 안내, 마스킹된 SecureField와
  활성화된 Save and Connect를 확인했다. 추가 전송 없이 Done으로 폼을 닫았다.
  macOS 인증 창은 사용자 직접 승인 영역이며 보안 도구로 조작하지 않는다.
  비밀번호는 SecureField에만 채우고 전송은 별도 Save and Connect로 시작한다.
  근거와 범위: [READER_WIFI_SETUP.md](READER_WIFI_SETUP.md).
- 사용자가 App ID/개발 프로파일 갱신을 승인했고, 실제 iPhone 서명 빌드는
  새 wifi-info 권한으로 성공했다. 배포 프로파일/IPA는 별도 재검증이 필요하다.
  첫 iPhone UI 시험은 iOS 자동화 모드 초기화 시간 초과로 중단돼 조회 성공으로
  간주하지 않는다. `.build/current-wifi-iphone-physical.xcresult`.
  2026-10-11 사용자가 SBiPhone을 잠금 해제한 뒤 물리 기기 UI 재시험은 통과했다
  (1개, 실패 0): `.build/current-wifi-iphone-retry-20261011.xcresult`.
  현재 SSID 채우기, 비밀번호 미입력 상태에서 전송 불가, Done 닫기를 확인했다.
  이 시험은 iPhone에서 리더로 실제 전송한 증거와 구분한다.
  최종 코드의 sandboxed Mac 빌드 및 generic iOS 기기용 서명 빌드, App Store
  source validator는 통과했다. `.build/current-wifi-mac-final.log`,
  `.build/current-wifi-device-final-generic.log`, `.build/current-wifi-store-final.log`.
- 사용자가 새 Wi-Fi 비밀번호를 입력한 뒤 X3의 동일 기기 ID와 `saved` 결과를
  확인했다. 새 네트워크에서 앱 연결·inventory·EPUB 왕복 원본 비교·시험 파일
  정리까지 통과했다. 형제 저장소 증거:
  `build/dev-pipeline-runs/20261010T144635-5e64f9/report.json`.

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
- 디자인 마감 당시 서명 IPA·Mac PKG 생성과 검증은 완료했으나 아래 후속 수정은
  포함하지 않는다. 출시 전에는 실제
  iPhone/X4 전송·복구·이어 읽기 수용 시험, TestFlight, 심사 연락처/앱 레코드/업로드/
  실기기 영상 확인이 필요하다. 최신 export 증거는 `appstore/submission.json`에 있다.
- 기준 확인: 과거 테스트 수를 최신 HEAD 재검증으로 인용하지 않는다. 이번 제목
  변경과 후속 실기기 확인 결과는 아래에 기록한다. 계정·출시 작업은 수행하지 않았다.

## 앱에서 리더 Wi-Fi 설정 — 2026-10-09

- My Reader → More → Manage Reader → Set Up Reader Wi-Fi에서 SSID/비밀번호를
  입력한다. 공개 CoreBluetooth와 기존 페어링을 사용하며 Apple 기기 네트워크는
  변경하지 않는다. 연결된 Same Wi-Fi에서 BLE 설정으로 전환할 수 있다.
  최초 페어링의 기기 확인은 필요하다. [계약과 제약](READER_WIFI_SETUP.md).
- 앱은 비밀번호를 저장/로그하지 않는다. 펌웨어는 연결 성공 후에만 기존 SD
  저장소를 교체하며 실패하면 기존 네트워크로 복귀한다. SD 저장소는 암호화가
  아닌 기존 난독화 방식이다. 개인정보 문서와 심사 노트를 함께 갱신했다.
- X3 설치본 `8925b142-ble-standby-wa68589c8`, SHA-256
  `407ec692b4a984c1b49bacdb96feab78d851ba502e2665a90e58988ef4cf1303`.
  실제 앱 → BLE 자격 증명 전달 → 존재하지 않는 SSID 실패 → 기존 Wi-Fi 복귀와
  일치하는 결과 확인, 이후 inventory/EPUB 왕복·삭제가 통과했다.
  증거: 형제 저장소 `build/dev-pipeline-runs/20261009T142853-910223/report.json`.
- 펌웨어 host 909개, 비밀번호 삭제 누락 변이 검출, strict cppcheck와 기본/standby
  빌드 통과. 앱 Wi-Fi/Wake 최종 11개, iPhone 입력 UI 테스트, Mac 테스트 10개
  통과(별도 2개 skipped). iOS 및 sandboxed Mac 빌드를 완료했다.
- 스크린샷 캡처의 첫 시뮬레이터 실행 정체를 종료하고 플랫폼별 기본 캡처와
  Articles 캡처를 분리 재실행했다. 최종 19장과 App Store source validator 통과.
  캡처 요약: `.build/screenshots/capture-reports/20261009T144050-65705/`,
  Articles 결과: `.build/wifi-articles-{iphone,ipad}.xcresult`.
- 새 Mac 앱을 `~/Applications/Pocket Daily.app`에 설치·실행하고 X3 Same Wi-Fi
  연결과 입력 시트를 확인했다. 이후 올바른 새 SSID의 연결/저장 및 Mac/X3
  왕복 전송도 위 2026-10-10 기록처럼 통과했다. 물리 iPhone/X4 전송 검증 및
  새 IPA/PKG export·심사 업로드는 남아 있다.
  공개 API 검토는 Apple의 심사 승인을 의미하지 않는다.

## 인터페이스 전수 검토와 자동 검증 — 2026-10-09

- 깨우기 수정 검증(23:04 KST): SDK의 `CONFIG_PM_SLP_DISABLE_GPIO=1`은 자동
  light sleep에서 GPIO를 비활성화하는데, X3 대기는 SD를 마운트한 채 유지하고
  버튼을 폴링했다. SD 공급 GPIO13·chip select·입력 pull을 보존하지 않는 충돌을
  형제 저장소 `HalPowerManager::beginBleStandby()`의 `gpio_sleep_sel_dis()`로
  수정했다. 절전 진입 전 유효 GPIO의 기존 설정을 보존하며 실패하면 진입을 거부한다.
  기본 deep sleep의 명시적 전원 차단은 유지된다. 개발 시험은 SD 중간 체크포인트를
  남기고, 앱은 BLE timeout 단계와 실패를 보존한다.
  설치본 `8925b142-ble-standby-w79b237a9`, SHA-256
  `6588fb6ca7de031f06132f2e243976fae76697993973d7cee246bab7aac90f75`.
  Mac/X3 2회 모두 90초 대기 요청, 실제 83,058 / 82,120 ms standby 후
  `app-wifi` 종료와 동일 기기 Wi-Fi 복귀(20.61 / 13.12초), 읽기 위치 목록 교환
  각 2회, EPUB 2,856 B 전송·다운로드 원본 비교·시험 파일 삭제가 통과했다.
  배터리 99%, 최소 free 61,280 B / block 53,236 B; 전류/장시간 배터리 수명은 미측정.
  증거: 형제 저장소 `build/dev-pipeline-runs/20261009T135746-4d33d3/report.json`.
  새 검증기는 실제 standby >=60초를 요구하며 두 기존 결과도 재검증했다.
  펌웨어 host 898개, 파이프라인 Python 22개, strict cppcheck와 두 환경의 무경고
  빌드가 통과했다. 중간 기록을 저장하지 않는 변이는 새 회귀 테스트에서 실패했다.
  수 시간 대기, 물리 iPhone/X4 검증 완료를 뜻하지 않는다.
  최종 Mac 서명 빌드를 `~/Applications/Pocket Daily.app`에 새 번들로 설치하고
  서명과 빌드 산출물의 바이트 일치를 검증했다. 실행 후 X3 Same Wi-Fi 자동 연결과
  fresh inventory를 UI에서 확인했다. 최종 앱 수정은 iOS 관련 7개 테스트를
  재실행해 통과했으며, 앞선 전체 관련 104개 통과와 구분한다.
  아래는 수정 전 실패 이력이다.

- 깨우기 원인 추적(22:33–22:40 KST, 수정 전): 설치된 `w5467c36a`로
  개발 파이프라인을 다시 실행해 초기 LAN 연결은 성공했으나 BLE wake/LAN 복귀가
  시간 초과했다. 실패 보고서는 형제 저장소의
  `build/dev-pipeline-runs/20261009T133345-0f2cb8/report.json`이며 2회 중 첫 회에서
  중단했다. 180초 복귀 제한 후에도 등록 주소와 현재 /24에서 동일 ID가 응답하지
  않아 기기의 cycle 결과는 아직 회수하지 못했다. 재요청·펌웨어 설치는 하지 않았다.
  진단 빌드의 실제 Connect는 `connecting` 단계에서 시간 초과(22:40:11)했다.
  이는 `START_WIFI`를 보내기 전 실패이며, 대기 중 멈춤/깊은 절전/전원 상태의
  구분은 아직 불가능하다. USB 연결을 요청했으며 현재 USB serial 포트는 없다.
  앱은 실패 단계별 오류, 식별자 없는 제한된 로컬 로그, 하드웨어 보고서의
  `wakeFailure`를 추가했다. 원래 오류를 버리는 진단 결함을 보완했을 뿐,
  장치 깨우기 원인이 해결됐다는 뜻은 아니다. 기존 시험은 재부팅 후 대기하므로
  재부팅 없는 실사용 이력의 검증도 별도로 필요하다.
  사용자는 대기 이미지가 그대로이며 USB 연결이 불가능하다고 답했다. 짧은 전원
  버튼 후 Same Wi-Fi 복귀를 요청했으며, 당시 다음 작업은 새 mutation 전에 기존
  run `88288109`의 `/api/pocket/v1/dev/ble-cycle` 결과를 읽는 것이다.
  진단 수정 검증: Mac 서명 빌드와 iOS simulator 빌드 성공, iOS의
  `ReaderWakeConnectorTests` 5개 + `NearbySyncProtocolTests` 99개 통과
  (`.build/wake-diagnostics/ios-regression-tests.log`). 앞선 Mac 테스트 선택은
  해당 타깃에 클래스가 없어 0개 실행됐으므로 검증 근거에서 제외한다.
- 후속 실제 사용 점검(22:17 KST): 단일 실행 앱의 Connect가 BLE 깨우기 단계에
  들어간 뒤 리더 미발견으로 종료됐다. 등록 주소의 `/api/status`도 3초 시간 초과.
  Bluetooth 마지막 교환은 UI상 6시간 전, inventory는 5시간 전 캐시였다.
  약 20초의 BLE 시도는 connector 제한과 일치하지만 앱이 원래 오류를 버려
  정확한 실패 단계는 확인되지 않았다. 기기 화면·배터리·실제 절전 상태는 미확인.
  이전 제어된 standby 통과를 장시간 일상 깨우기 신뢰성으로 확대하지 않는다.
  로컬 증거: `.build/wake-diagnostics/latest.json`.
  사용자 전원 버튼·Same Wi-Fi 복귀 후 다른 IP에서 동일 ID/`w5467c36a`를 확인했고
  앱의 명시적 탐색도 연결과 새 inventory 갱신에 성공했다. 부팅 후 기록은
  `software restart`, `lastTrigger=wake`, `lastGate=low-memory`, opened=0/skipped=1,
  free=84,112 B/block=61,428 B였다(진입 최소 free=98,304 B).
  게이트 순서상 해당 시점에는 설정·bond·배터리 >10% 조건을 통과했지만 정확한
  잔량은 API에 없다. 이 새 부팅 기록으로 이전 대기 중 실패 원인을 확정하지 않는다.
- 반복 실행: `python3 scripts/verify_reader_interface.py --standby --screenshots`.
  [검증표와 전제 조건](READER_INTERFACE_VALIDATION.md)에 기능별 실기기/단위 시험과
  아직 입증하지 않은 항목을 구분했다. 초기 권한·페어링·Same Wi-Fi 후 시험 중
  사용자 버튼 조작은 필요하지 않다. 일반 앱 종료는 에이전트가 처리했다.
- 앱 보관함은 `/Books`도 읽고 FAT 경로 대소문자 차이를 합친다. 누락 폴더의 404와
  통신 오류를 구분하며, 일부 폴더 실패나 페이지 한도 도달을 정상 완료로 숨기지 않는다.
- SD 용량 조회 503의 원인은 SDK의 USB 블록 장치 의존이었다. 형제 저장소의
  `scripts/storage_sdk.patch`와 실제 SDK 헤더 회귀 시험으로 SPI 경로를 고쳤다.
  호스트 897개, cppcheck, default/ble_standby 무경고 빌드, SDK 패치 4개 시험 통과.
  호스트 시험은 SDK 헤더의 격리 사본에 검토된 패치를 적용하므로 로컬 SDK의
  선행 패치에 의존하지 않는다. 기존 구현을 되살린 사본에서는 회귀 시험이 실패했다.
- X3에 `ble-standby-w5467c36a` 설치 확인. 이미지 6,407,472바이트, SHA-256
  `7ccb9d22627cf8c0067dd6580869f48e673bfb6200171bec2cde288fb548b567`.
  형제 저장소 `build/dev-pipeline-runs/20261009T072250-084222/report.json` 통과:
  BLE 재연결 12.68초, SD 용량 10.82초, 설정/프로필 원복, 책·기사 전송/다운로드,
  실제 앱 독서·위치 복원, 중단/재개/폐기, 폴더 복사, 기존 파일 목록 보존 10항목.
- 최종 검증 묶음: `.build/interface-runs/20261009T073304-335479/`.
  앱 단위 시험 549개 통과/물리 opt-in 1개 건너뜀. Mac 독서 3개 및 별도 한글·장편
  EPUB 표본 시험 1개 통과; 펌웨어 XPointer 교차 검증 포함.
  독립된 빈 라이브러리에 다운로드를 저장하는 조건으로 실기기 10항목을 다시 통과했다
  (`20261009T073721-bf036a`, BLE 재연결 12.97초, SD 용량 11.10초).
- iPhone UI 36개 통과/건너뜀 0, 캡처 6장 생성. 최초 통합 실행의 UI 제한은
  40분이었으므로 이 완료 결과를 보존하고 iPad/Mac 구간을 별도 자동 실행으로
  이어갔다 (`.build/interface-ui-continuation.log`). 최초 `report.json`의 중단
  이력은 보존한다. 실행기 기본 UI 제한은 60분으로 변경했으며 캡처별 결과 JSON을
  별도 보존하고, 중단 시 임시 결과 묶음도 삭제하지 않도록 보완했다.
- iPad 전체 UI는 최초 34/36 통과. 연결 버튼을 전체 화면 대신 모달 창 기준으로
  판정하고, 오프라인 초안 시험의 외부 탐색을 격리한 뒤 실패 2개 재검증은 모두 통과했다.
  초안 생성 직후·연결 창 복귀 직후에도 값을 확인하도록 시험을 강화했다.
  최초 실패 결과와 후속 결과를 별도 보존한다 (`ipad-13-ui-summary.json`,
  `ipad-targeted-final-summary.json`). Xcode의 실패 진단 수집은 600초 시간 초과했으며,
  후속 실행에서는 부가 진단 수집만 중단/비활성화했다. 시험 판정은 건너뛰지 않았다.
- Mac 화면/독서 묶음은 10개 통과/선택 시험 2개 건너뜀, 캡처 6장 생성 및 패키지
  검증 통과 (`mac-ui-results/mac-16x10.json`). 한글·장편 표본은 위 별도 시험으로 확인했다.
- 서명된 최신 Mac 앱을 새 번들로 설치·실행했다. 기존 설치본의 테스트 플러그인
  잔재 때문에 단순 덮어쓰기는 서명 검증에 실패해, 기존 번들을 검증 폴더로 보관하고
  새로 복사했다. 최종 코드 서명 검증 통과 및 빌드와 실행 파일·Debug dylib 바이트 일치.
  `installed-app.json`에 두 해시를 보존했다. 실행 화면에서 X3 Same Wi-Fi 자동 재연결,
  `Reader · No active transfer`, `289 MB used / 15 GB`, `/Books` 가져오기 가능을 확인했다.
- 최종 정리: `completion.json`에 별도 실행 결과를 합쳤다. 최초 통합 실행을 통과로
  바꾸지 않았다. 수정한 UI 시험 2개는 iPhone에서도 통과했다. iPad 캡처는 최초
  묶음에서 개별 통과한 `PocketScreenshotTests` 4개의 첨부로 7장을 생성했다.
  다른 프로젝트 UI 시험과 겹쳐 지연된 중복 캡처 실행은 중단 이력으로 보존했다.
  최종 iPhone 6·iPad 7·Mac 6장, 총 19장 및 패키지 검증 통과.
- 물리 SBiPhone은 개발 도구에서 `unavailable`로 확인됐다. 물리 X4·iPhone의 확장
  시험, Direct 연결과 iCloud 다기기 수용을 이 결과로 대신하지 않는다. 계정·출시
  작업과 추가 커밋·푸시는 수행하지 않았다.

## 앞선 수정: 전송 화면과 앱 상태 — 2026-10-09 (X3 설치·검증 완료)

- 사용자가 전송 종료 후 리더의 Content transfer 화면이 남는 것을 확인했다.
  이전의 연결·파일 바이트 검증은 화면 복귀 수용 시험을 포함하지 않았다.
- 펌웨어의 콘텐츠 Saved/Removed 결과를 5초 후 닫고 Sync 바탕 화면으로 복귀하게
  수정했다. Paused/Failed 및 펌웨어 결과는 유지한다. optional `transferState` v1을
  상태 API에 추가했으며 앱은 기존 15초 heartbeat로 받은 단계를 표시한다.
  자체 작업 중에는 이전 상태를 숨긴다. 계약은 [TRANSFERS.md](TRANSFERS.md).
- 호스트 895개, 앱 상태 시험 12개, 펌웨어 cppcheck 및 default 빌드 통과.
  경계 조건을 고의로 바꾼 사본에서 관련 시험이 실패하는 것도 확인했다.
- 새 앱과 기존 X3의 연결·2,856바이트 EPUB 왕복은 통과했다
  (`20261009T063916-dbbce8`). 자동 복귀는 설치 펌웨어 미지원으로 명시했다.
  수정 앱을 설치·실행했으며 빌드와 실행 파일 해시는 일치한다.
- 설치 후보: `ble-standby-we19d4702`, 형제 저장소
  `build/transfer-feedback-candidate/update.bin`, SHA-256
  `234ee892ec6eb53ac02fbdc43388495d9811d7c9b99a45474b282be5f38d862d`.
  default와 ble_standby 빌드 모두 경고·오류 없이 통과했다. 기존 미커밋 펌웨어
  개발 기반을 유지한 후보이며 다른 작업의 변경을 제거하거나 커밋하지 않았다.
- iPhone/iPad/Mac 화면 시험 및 스크린샷 19장 재생성, 스토어 소스 검증 통과
  (`.build/transfer-state-screenshots.log`).
- 사용자 승인 후 위 후보를 X3에 설치·재부팅했고 정확한 버전 일치를 확인했다.
  `20261009T065715-2ce1a5/report.json` 전체 통과: 2,856바이트 EPUB 왕복·정리,
  전송 표시 `idle` 복귀와 앱의 새 heartbeat 수신, BLE standby 후 13.79초 재연결.
  이는 Mac/X3 API·앱 검증이며 리더 화면을 카메라로 관찰한 증거는 아니다.
- 앞서 생성한 배포본은 이 추가 수정을 포함하지 않는다. 최신 배포본 재생성과
  별도 iPhone/X4 수용 시험은 남아 있다. 이번 앱·펌웨어 수정은 아직 미커밋이다.

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
