# 서버 없는 이어 읽기 — 기기 간 진행도 교환

결정일: 2026-09-27. 이어 읽기는 서버 없이 두 경로로만 한다(KOReader 동기화는 이번 버전 제외,
사용자에게 노출하지 않음). 두 경로는 같은 위치 레코드(`PositionRecord`: document, progress(XPointer),
percentage, device, device_id, timestamp)를 쓴다.

| 경로 | 대상 | 전송 | 필요 조건 |
| --- | --- | --- | --- |
| iCloud 키-값 저장소 | 같은 Apple ID의 iPhone·iPad·Mac | Apple iCloud (개발자 서버 없음) | iCloud 로그인, 설정에서 켬(기본 켬) |
| 리더 직접 교환 | 앱 ↔ X3/X4 | 기존 Sync 연결(LAN/직접 연결) | 펌웨어 `readingProgress: 1` |

공통 규칙: 다른 기기의 더 앞선 위치만 제안하고 페이지를 자동으로 옮기지 않는다.
문서 식별은 partial MD5(리더도 같은 값), 위치는 XPointer + 페이지 시작 기준 진행률.

## iCloud 키-값 레코드

- `NSUbiquitousKeyValueStore`, 키 `position.v2.<document>.<device_id>`(기기마다 한 레코드), 값은 사전
  `{progress, percentage, device, device_id, timestamp}`. 책 파일·제목은 저장하지 않는다.
  한 기기가 앞부분을 읽어도 다른 기기의 레코드를 덮어쓰지 않는다.
- 1 MB·1024키 한도: 최근 갱신 순으로 최대 800개를 유지하고 오래된 키부터 지운다.
- 다른 기기에서 값이 바뀌면(`didChangeExternallyNotification`) 열린 책이 제안을 다시 확인한다.
- iCloud 계정이 없거나 꺼져 있으면 조용히 건너뛴다. 사용자는 Library → Library options → Continue Reading에서 끌 수 있다.
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
  {"v":1,"deviceID":"<id>","books":[{"path":"/Books/a.epub","document":"<32 hex>",
   "filenameDocument":"<32 hex>","progress":"/body/DocFragment[3]/body/p[12]/text().0",
   "percentage":0.43,"updated":1790000000,"seq":17}]}
  ```
  최근 읽은 EPUB 최대 10권. `progress`는 책을 닫을 때 리더가 계산해 둔 XPointer(없으면 null),
  `percentage`는 0~1 페이지 시작 기준, `updated`는 신뢰할 시계가 없으면 0, `seq`는 기기 단조 증가값.
  응답 8 KiB 이하.
- `POST /api/pocket/v1/reading`
  `{"deviceID":"<id>","document":"<32 hex>","progress":"<xpointer>","percentage":0.5,"device":"Pocket Daily iPhone"}`
  → 리더는 해당 책의 대기 위치로만 저장(`{"ok":true,"state":"pending"}`)하고, 다음에 그 책을 열 때
  "Pocket Daily iPhone: 50% · 이동?"을 묻는다. 모르는 문서는 404, 형식 오류는 400.
  현재 진행도를 즉시 바꾸지 않는다.
- 앱: 연결 후 목록을 받아 서재와 문서 식별값으로 맞추고, 리더의 위치를 기기별 후보로 저장한다
  (책을 열 때 제안). 앱이 더 앞선 책은 대기 위치로 보낸다. 설정 "연결 시 리더와 위치 교환"(기본 켬).
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
BLE·Wi-Fi 계약과 리더 위치 payload는 변경하지 않았다.
