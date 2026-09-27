# 서버 없는 이어 읽기 — 기기 간 진행도 교환

결정일: 2026-09-27. KOReader 공개 서버(`sync.koreader.rocks`)는 과거와 현재(2026-09-27 확인, HTTP 522)
반복적으로 응답하지 않는다. 서버가 없어도 이어 읽기가 되도록 두 경로를 둔다. 세 경로 모두
[READER_EXPANSION.md](READER_EXPANSION.md)의 KOSync v1 레코드 형식을 공유한다.

| 경로 | 대상 | 전송 | 필요 조건 |
| --- | --- | --- | --- |
| iCloud 키-값 저장소 | 같은 Apple ID의 iPhone·iPad·Mac | Apple iCloud (개발자 서버 없음) | iCloud 로그인, 설정에서 켬(기본 켬) |
| 리더 직접 교환 | 앱 ↔ X3/X4 | 기존 Sync 연결(LAN/직접 연결) | 펌웨어 `readingProgress: 1` |
| KOReader sync | 앱·X3/X4·KOReader 기기 | 사용자가 고른 KOSync 서버 | 계정 |

공통 규칙: 다른 기기의 더 앞선 위치만 제안하고 페이지를 자동으로 옮기지 않는다.
문서 식별은 KOReader partial MD5(파일명 모드 선택 가능), 위치는 XPointer + 페이지 시작 기준 진행률.

## iCloud 키-값 레코드

- `NSUbiquitousKeyValueStore`, 키 `kosync.v1.<document>`, 값은 사전
  `{progress, percentage, device, device_id, timestamp}`. 책 파일·제목은 저장하지 않는다.
- 1 MB·1024키 한도: 최근 갱신 순으로 최대 800권을 유지하고 오래된 키부터 지운다.
- iCloud 계정이 없거나 꺼져 있으면 조용히 건너뛴다. 사용자는 Library → Sync에서 끌 수 있다.
- 엔타이틀먼트 `com.apple.developer.ubiquity-kvstore-identifier`. 계정 소유자가 App ID의 iCloud
  기능을 켜야 서명 빌드에서 동작한다(스토어 제출 전 확인).

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

### 펌웨어 구현과의 차이 (2026-09-27, 펌웨어 `d9a8e0f5`)

- 펌웨어 XPointer는 항상 `[1]`과 `text()[N].off`를 쓰고, 문단 시작은 요소까지만, 장 시작은
  `/body/DocFragment[N]/body`다. 앱 파서는 둘 다 허용한다.
- GET은 chunked 응답이며 메모리 부족 시 503, 식별 불일치·전송 중 409를 준다. 앱은 조용히 건너뛴다.
  `progress`가 null이면 `updated`는 0이다. 앱은 XPointer 없는 항목을 제안하지 않는다.
- POST는 partial MD5와 파일명 식별값 모두를 받는다. `filenameDocument`는 빈 문자열일 수 있다.
- 교차 검증: 펌웨어가 앱 XPointer를 해석(한국어 15/15, Frankenstein 114/114 동일 글자),
  앱이 펌웨어 XPointer 258개를 해석(`MacTests` `testFirmwareXPointersResolveToTheSameText`).
  첫 실행에서 펌웨어가 `&apos;`를 6글자로 세어 이후 offset이 5글자 밀리는 버그를 찾아 펌웨어에서 수정했다.
