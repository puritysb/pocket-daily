# 서버 없는 이어 읽기 — 기기 간 진행도 교환

결정일: 2026-09-27. 이어 읽기는 서버 없이 두 경로로만 한다(KOReader 동기화는 이번 버전 제외,
사용자에게 노출하지 않음). 두 경로는 같은 위치 레코드(`PositionRecord`: document, progress(XPointer),
percentage, device, device_id, timestamp)를 쓴다.

| 경로 | 대상 | 전송 | 필요 조건 |
| --- | --- | --- | --- |
| iCloud 키-값 저장소 | 같은 Apple ID의 iPhone·iPad·Mac | Apple iCloud (개발자 서버 없음) | iCloud 로그인, 설정에서 켬(기본 켬) |
| 리더 직접 교환 | 앱 ↔ X3/X4 | 기존 Sync 연결(LAN/직접 연결) | 펌웨어 `readingProgress: 1` |
| 리더 Bluetooth 교환 | 앱 ↔ 페어링한 X3/X4 | 본딩된 Nearby Sync BLE(백그라운드 가능) | 상태 `CAP`에 `READ1` |

공통 규칙: 더 최근에 읽었다는 근거가 있으면 다시 읽는 앞부분도 제안한다.
근거가 없는 구형 리더는 더 앞선 진행도만 제안하며, 페이지는 자동으로 옮기지 않는다.
문서 식별은 partial MD5(리더도 같은 값), 위치는 XPointer + 페이지 시작 기준 진행률.

## 설정 화면

Settings는 Appearance → Continue Reading → Reader connection 순서의 단일 화면이다.
iPhone은 서재 상단의 아이콘과 Settings 레이블로, iPad·Mac은 사이드바에서 연다
(Mac은 ⌘,도 지원). 모든 플랫폼에서 현재 창에 붙는 시트로 열며 별도 Settings 창은 만들지 않는다.
화면 모드 선택과 실제 테마는 같은 바인딩으로 갱신한다. Continue Reading에서 Apple 기기와 X3/X4의 위치 공유를 바로 켜고 끈다.
로그인 필요, 마지막 교환, 교환 오류와 수동 교환은 해당 설정 옆에 표시하고,
파일 일치·개인정보·연결 방식의 상세 설명은 기본 접힌 Sync & connection guide에 둔다.
페이지 이동 전 확인 원칙은 항상 표시한다. 동기화 동작과 기본값은 바꾸지 않는다.

## iCloud 키-값 레코드

- `NSUbiquitousKeyValueStore`, 키 `position.v2.<document>.<device_id>`(기기마다 한 레코드), 값은 사전
  `{progress, percentage, device, device_id, timestamp}`. 책 파일·제목은 저장하지 않는다.
  한 기기가 앞부분을 읽어도 다른 기기의 레코드를 덮어쓰지 않는다.
- 1 MB·1024키 한도: 최근 갱신 순으로 최대 800개를 유지하고 오래된 키부터 지운다.
- 다른 기기에서 값이 바뀌면(`didChangeExternallyNotification`) 열린 책이 제안을 다시 확인한다.
- iCloud 계정이 없거나 꺼져 있으면 조용히 건너뛴다. 사용자는 Settings → Continue Reading에서 끌 수 있다.
- 엔타이틀먼트 `com.apple.developer.ubiquity-kvstore-identifier`. 계정 소유자가 App ID의 iCloud
  기능을 켜야 서명 빌드에서 동작한다(스토어 제출 전 확인).

## 제안 규칙

1. 이 기기에서 마지막으로 읽은 뒤 다른 기기가 더 최근에 읽은 곳(앞이든 뒤든, 다시 읽기 포함) → "마지막으로 읽은 곳".
2. 없으면 다른 기기가 더 멀리 읽은 곳 → "더 멀리 읽은 곳".
3. 0.4% 이내 차이, 이 기기 자신의 레코드, 이미 닫은 제안은 제외. 페이지는 묻지 않고 옮기지 않는다.
- 리더는 신뢰할 시계가 없어, 교환에서 위치가 바뀐 것을 처음 본 시각을 그 위치의 시각으로 쓴다.
- 같은 책 식별값이 필요하다: 기기마다 같은 파일(서재의 Share book file). TXT/MD 변환은 내용 기반
  식별자와 고정 시각으로 기기마다 같은 EPUB 바이트를 만든다(파일명이 같을 때).

## 리더 직접 교환 (reading-progress v1)

펌웨어 계약 원본은 형제 저장소 `docs/reading-progress-v1.md`이며 이 절과 같아야 한다.

- `/api/status`에 `readingProgress: 1`을 광고한다. 없으면 앱은 이 경로를 쓰지 않는다.
- `GET /api/pocket/v1/reading?deviceID=<id>` →
  ```json
  {"v":1,"offerVersion":2,"deviceID":"<id>","books":[{"path":"/Books/a.epub","document":"<32 hex>",
   "filenameDocument":"<32 hex>","progress":"/body/DocFragment[3]/body/p[12]/text().0",
   "percentage":0.43,"updated":1790000000,"seq":17}]}
  ```
  최근 읽은 EPUB 최대 10권. `progress`는 책을 닫을 때 리더가 계산해 둔 XPointer(없으면 null),
  `percentage`는 0~1 페이지 시작 기준, `updated`는 신뢰할 시계가 없으면 0, `seq`는 리더 내 기록 번호(현재 기록이 아니면 0)다. 손상 시 초기화될 수 있어 시간 순서로 정렬하지 않는다.
  응답 8 KiB 이하.
- `POST /api/pocket/v1/reading`
  `{"deviceID":"<id>","document":"<32 hex>","progress":"<xpointer>","percentage":0.5,"device":"Pocket Daily iPhone"}`
  → 리더는 해당 책의 대기 위치로만 저장(`{"ok":true,"state":"pending"}`)하고, 다음에 그 책을 열 때
  "Pocket Daily iPhone: 50% · 이동?"을 묻는다. 모르는 문서는 404, 형식 오류는 400.
  현재 진행도를 즉시 바꾸지 않는다.
- 앱: 연결 후 목록을 받아 서재와 문서 식별값으로 맞추고, 리더의 위치를 기기별 후보로 저장한다
  (책을 열 때 제안). 아래 관찰 순서 규칙에 따라 대기 위치를 보낸다. 설정 "연결 시 리더와 위치 교환"(기본 켬).
  교환은 수신·송신이 모두 끝난 뒤에만 "마지막 교환"으로 기록하고, 실패는 이유를 보여 준다.
  같은 연결에서 실패하면 10·20초 뒤 최대 3회 재시도하며, "Exchange positions now"로 즉시 다시 할 수 있다.
- 자동 교환(2026-09-29): 연결하지 않아도, 전에 연결한 리더(같은 deviceID)가 마지막 주소에서
  1.5초 안에 응답하면 조용히 교환한다. 시점은 앱 실행·활성화, 책을 연 직후(30초 간격 제한),
  책을 떠날 때(간격 제한 없음). 주소 스캔·Wi-Fi 변경·화면 표시는 하지 않고, 받은 위치가 있으면
  열린 책이 제안을 다시 확인한다. 연결된 세션이면 같은 시점에 즉시 다시 교환한다.

### 펌웨어 구현과의 차이 (2026-09-27, 펌웨어 `d9a8e0f5`)

- 펌웨어 XPointer는 항상 `[1]`과 `text()[N].off`를 쓰고, 문단 시작은 요소까지만, 장 시작은
  `/body/DocFragment[N]/body`다. 앱 파서는 둘 다 허용한다.
- GET은 chunked 응답이며 메모리 부족 시 503, 식별 불일치·전송 중 409를 준다. 앱은 조용히 건너뛴다.
  `progress`가 null이면 `updated`는 0이다. 앱은 XPointer 없는 항목을 제안하지 않는다.
- POST는 partial MD5와 파일명 식별값 모두를 받는다. `filenameDocument`는 빈 문자열일 수 있다.
- 교차 검증: 펌웨어가 앱 XPointer를 해석(한국어 15/15, Frankenstein 114/114 동일 글자),
  앱이 펌웨어 XPointer 258개를 해석(`MacTests` `testFirmwareXPointersResolveToTheSameText`).
  첫 실행에서 펌웨어가 `&apos;`를 6글자로 세어 이후 offset이 5글자 밀리는 버그를 찾아 펌웨어에서 수정했다.
- 정확한 페이지 위치(2026-09-29, 펌웨어 `feat/exact-page-offsets`, 섹션 캐시 v133): 리더는 페이지
  첫 글자의 장 텍스트 offset을 기록해 그 글자를 가리키는 XPointer를 만들고, 받은 XPointer는 그 글자가
  있는 페이지로 연다(이전: 문단 안 비례 추정). 앱 교차 검증은 430/430(기존 258 + offset 172).

## 앱 작업 수명 보강 — 2026-09-29

조용한 위치 교환도 PocketModel의 작업 토큰과 연결 세대를 사용한다. 화면의 작업 표시를
켜지 않는 낮은 우선순위 작업이며, 사용자가 연결/전송 등을 요청하면 취소 후 기존 I/O가
끝날 때까지 기다린다. 데모 진입·직접 연결 준비·백그라운드 진입도 이를 취소한다.
probe/위치 읽기/각 제안 쓰기 후 소유권을 재확인해 오래된 결과를 적용하지 않는다.
iOS 활성화에서는 foreground 상태 복원을 먼저 처리한 뒤 위치 교환을 요청한다.
이 HTTP 작업 수명 보강은 리더 위치 payload를 변경하지 않았다.

## 리더 Bluetooth 교환 (reading-sync-ble-v1, 2026-09-29)

펌웨어 계약 원본은 형제 저장소 `docs/reading-sync-ble-v1.md`다. 같은 목록·오퍼 JSON을 본딩된
Nearby Sync 서비스로 나른다. 하드웨어 검증 전이다.

- 페어링: Device → Reading sync over Bluetooth → Pair Reader, 또는 Connect Directly. 리더는
  Pocket Daily → Sync 메뉴에서 **Direct connection**을 골라야 BLE 광고를 시작한다(Sync 메뉴 자체는
  광고하지 않는다).
- 리더는 본딩을 2개까지 저장하고(`CONFIG_BT_NIMBLE_MAX_BONDS 2`) 세 번째 기기가 페어링하면 가장 오래된 것을
  지운다. 펌웨어 재설치로 NVS가 지워져도 같다. 이때 Apple 기기는 옛 키로 `CBError.peerRemovedPairingInformation`을
  받으며, 앱은 시스템 Bluetooth 설정에서 `Pocket-…`를 Forget This Device한 뒤 다시 페어링하라고 안내한다.
- 기억: Connect Directly(Nearby Sync)에서 인증된 연결(암호화 상태 읽기 + 이벤트 구독)이 되면 앱은
  주변기기 식별자와 상태의 `ID`, `MODEL`만 UserDefaults `readerLink.remembered.v1`에 저장한다.
  패스키·핫스팟 정보는 저장하지 않는다. 페어링한 리더가 없으면 Bluetooth를 켜지 않는다(권한 창 없음).
- 링크(`Sources/Sync/ReaderBluetoothLink.swift`): 스캔하지 않고 기억한 주변기기에 대기 `connect`만
  걸어 둔다. iOS는 복원 식별자 `PocketReaderReadingSync`와 `UIBackgroundModes: bluetooth-central`로
  리더의 교환 창(책 닫기·깨우기 45초, 잠들기 20초)에 백그라운드 연결·상태 복원을 요청한다.
  실행 여부와 시간은 OS가 결정하며 매번 전달되거나 강제 종료 후 자동 복구된다고 보장하지 않는다.
  macOS는 앱이 실행 중일 때만 한다.
- 순서: 서비스·특성 탐색 → 이벤트 구독 + 상태 읽기 → `ID`가 기억한 값과 같고 `CAP`에 `READ1`이
  있어야 한다(아니면 조용히 끊음) → `READ_LIST` → `D` 조각을 seq로 모아(순서 뒤섞임·중복 허용,
  같은 seq에 다른 내용·빈 seq·8 KiB 초과는 거부) `END`의 길이와 CRC-32(IEEE)가 맞을 때만
  `ReaderReadingList`로 해석(`path` 없음) → 서재를 불러와(비어 있으면 load) HTTP 교환과 같은
  `ReadingSync.exchange` 규칙으로 병합 → 이 기기가 더 앞선 책만 최대 10개 `OFFER` + `W`
  조각(≤180바이트, UTF-8 경계에서 자름, 응답 있는 쓰기)으로 보낸다. 본문은 HTTP POST와 같은
  JSON(`CrossPointClient.readingOfferBody`). `OK`를 받아야 다음 오퍼, `ERR UNKNOWN_DOCUMENT`는
  HTTP 404처럼 건너뛰고, 다른 `ERR`은 교환 실패다 → `exchangeFinished` → 끊고 다시 대기.
- 시간 제한: 준비 15초, 레코드 사이 10초, 연결 전체 60초. 끝나면 60초 쉬었다가 대기 연결을 다시
  건다(리더의 가장 긴 창보다 길어 한 창에 한 번 교환). iOS는 이 타이머를 백그라운드 작업으로
  잡고, 시스템이 시간을 먼저 끝내면 그때 바로 다시 건다.
- 보고: 목록을 병합하기 시작한 뒤의 실패와 목록 자체의 오류(`ERR`, CRC·형식)는 설정의 "마지막
  교환 실패"에 남고, 받은 위치는 유지된다. 다른 리더·구 펌웨어·응답 없음은 조용히 넘어간다.
- 물러섬: Connect Directly가 스캔·연결 중이면(`NearbySyncController.ownsBluetooth`) 진행 중인 교환을
  끊고 대기 연결도 취소한다. 데모 모드와 "Your X3/X4 reader" 끄기도 같다. 페이지는 절대 옮기지 않는다.

### 2026-09-30 통합 점검

- 앱 `c22df41`, 펌웨어 `ee188fe7`에서 각각 `codex/ble-sync-review` 후보를 준비했다.
  이 변경은 기존 `feat/ble-reading-sync` 이력을 포함한다. main 병합·배포 상태는
  GitHub PR·릴리스에서 확인하며, 실기 검증 완료를 의미하지 않는다.
- `END`가 `READ_LIST` 쓰기 완료보다 먼저 와도 양쪽 완료 전에는 다음 `OFFER`를 쓰지 않는다.
  전송 성공 수는 실제 저장 `OK`에만 증가한다. timeout/forget/UNKNOWN_DOCUMENT는 성공으로 세지 않는다.
- 앱 시작 전에 데모 상태를 구독하고, 데모 변경과 Nearby Sync의 라디오 점유를 동기적으로 반영한다.
  SwiftUI의 다음 화면 갱신까지 자동 연결 취소가 지연되지 않는다.
- HTTP 조용한 교환·사용자 작업·취소 I/O 정리 동안 기존 작업 소유권 publisher로 BLE를 중단한다.
  따라서 서로 다른 전송이 공유 병합 상태를 동시에 덮어쓰지 않는다.
- 복원된 연결 중 기억한 리더가 아닌 것은 취소한다. reading-sync.log에는 원시 상태/기기 ID를 남기지 않는다.
- 펌웨어는 부족한 힙에서 창을 건너뛴다. 현재 후보의 96/40 KiB 시작 조건 때문에 과거 83 KB Home
  사례는 동기화되지 않을 수 있다. 실기에서 창 열림과 실제 lists/offers 완료를 각각 확인해야 한다.
- iOS 백그라운드 정책 근거: [Apple Core Bluetooth](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html).
  실기 체크리스트와 전체 판정은 펌웨어 `docs/ble-sync-review-2026-09-30.md`에 모았다.

## 관찰 순서와 Bluetooth 상태 — 2026-10-05

- 리더 목록의 `offerVersion:2`가 있을 때 앱은 제안에 `readerSeq`를 넣는다.
  펌웨어는 저장 시점과 책을 다시 여는 시점에 그 번호가 일치하는지 확인한다.
  바뀌었으면 HTTP 409 / BLE `STALE_POSITION`으로 거절하거나 대기 제안을 버린다.
- 앱은 리더·책별 번호, XPointer, 최초 관찰 시각과 마지막 전달 표식을 최대 400개 보관한다.
  리더 위치가 그대로이고 그 관찰 이후 앱에서 읽었거나, 신뢰할 리더 시계보다 앱 기록이
  최신이면 앞부분 다시 읽기도 제안한다. 처음 보는 시계 없는 리더에는 기존의 더 멀리 읽기
  규칙만 적용한다. 새 리더 위치를 봤는데 앱의 과거 위치가 더 멀다는 이유만으로 보내지 않는다.
- 모든 선택된 제안의 전달이 확인되면 표식을 저장한다. 동일 제안은 다음 교환이나 앱 재시작
  후에도 반복하지 않으며, 실패한 교환은 재시도한다. 리더에서 제안을 거절해도 같은 제안이
  바로 되살아나지 않는다. 번호 초기화는 전역적으로 유일한 세대나 시계 보장이 아니다.
- Bluetooth 페어링 사실과 `READ1` 지원을 구분한다. Settings에는 대기/교환/오류 상태와
  마지막 완료 시각을 표시한다. HTTP 상태가 페어링한 리더와 일치할 때만 `readSync`의
  메모리·배터리·본딩 제한 이유를 보여 준다. 연결됨을 실제 교환 완료로 표시하지 않는다.
- BLE 메모리 기준과 창 길이는 변경하지 않았다. X3/X4의 백그라운드 동기화, 재연결,
  절전·Wi-Fi 전환 및 버튼 확인은 실제 기기에서 따로 검증해야 한다.
