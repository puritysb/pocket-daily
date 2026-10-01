# 앱 리더 확장 — 결정과 설계

결정일: 2026-09-27. 사용자 결정으로 Pocket Daily의 제품 정체성을 바꾼다.
**Pocket Daily는 집중형 전자책 리더 앱이며, 동시에 X3/X4 리더의 컴패니언이다.**
X3/X4 컴패니언 기능은 유지·확장하며 폐기하지 않는다. 아직 사용자에게 배포된 앱이
없으므로 기존 구현을 새 방향에 맞춰 재정렬한다.

## 결정

1. 제품 정체성: 하드웨어 없이도 동작하는 계정 없는 집중형 리더 + X3/X4 컴패니언.
   `AGENTS.md`의 Product identity가 기준이다.
2. 이어 읽기: **서버 없이** iCloud 키-값(같은 Apple ID)과 연결된 리더 직접 교환으로 한다
   ([READING_PROGRESS.md](READING_PROGRESS.md)). 2026-09-27 사용자 결정으로 KOReader 동기화(KOSync)
   연동은 이번 버전에서 제외하고 사용자에게 노출하지 않는다. 구현 이력은 git(`761de09` 이전 커밋)에 있다.
3. 폰 렌더러: [foliate-js](https://github.com/johnfactotum/foliate-js)(MIT)를
   고정 커밋으로 번들하고 WKWebView에서 실행한다. 펌웨어 EPUB 엔진은 폰 렌더러로 쓰지 않는다.
4. 위치 형식: KOReader XPointer(`/body/DocFragment[N]/body/…/text()[m].offset`)와
   전체 진행률(percentage)을 공통 위치로 쓴다. 기기(X3/X4)와 앱이 같은 형식을 쓰며, KOReader와도 호환되는 형식이다.
5. Android: 지금 구현하지 않는다. 계약(위치·동기화·서재·전송)은 플랫폼 중립으로 문서화하고,
   렌더러는 Android WebView에서 재사용할 수 있는 foliate-js를 택했다.

## 렌더러 선택 근거

| 기준 | foliate-js + WKWebView | Readium Swift | 펌웨어 엔진(host) |
| --- | --- | --- | --- |
| 라이선스 | MIT | BSD-3 | MIT |
| Android 재사용 | 같은 JS 코드 | 별도 Kotlin 툴킷 | NDK 재빌드 |
| 폰 타이포그래피·접근성 | WebKit 텍스트, VoiceOver | WebKit, 성숙 | 1비트 비트맵, 없음 |
| 의존성 | JS 파일 번들, 빌드 단계 없음 | SPM 다수 | 이미 있는 xcframework 확장 |
| 위험 | 라이브러리 API 비안정(고정 커밋으로 관리) | 무거움 | 현재 긴 섹션 멈춤 조사 중 |

펌웨어 EPUB 엔진의 host 빌드는 기기 재현·회귀 시험과 향후 "기기 화면 미리보기" 용도로 둔다.

### foliate-js 번들 규칙

- 위치: `Support/ReaderEngine/foliate-js/`. 출처 커밋은 `Support/ReaderEngine/SOURCE.json`.
- EPUB 경로에 필요한 모듈만 포함한다. PDF.js·MOBI·FB2·CBZ·OPDS·TTS·사전 모듈은 제외한다.
- 책의 스크립트는 실행하지 않는다. 엔진 페이지는 CSP로 `'self'` 외 스크립트를 막고,
  WKWebView는 네트워크를 쓰지 않는다. 책 파일은 앱 전용 URL scheme으로만 제공한다.
- 업데이트는 커밋 고정·diff 검토·리더 시험 후에만 한다.

## 위치와 동기화 계약

### 문서 식별

- 기본: KOReader partial MD5. 파일 오프셋 `0, 1024, 4096, …, 1024 << 20`에서 최대
  1024바이트씩 읽어 MD5. 오프셋이 파일 크기 이상이면 중단한다. 펌웨어
  `lib/KOReaderSync/KOReaderDocumentId.cpp`와 KOReader `util.partialMD5`와 같다.
- 앱이 기기로 보낸 책은 바이트가 같으므로 식별값이 자동으로 일치한다.
  앱은 서재에 넣은 파일을 수정하지 않는다.

### 진행도 레코드

```json
{"document":"<32 hex>","progress":"/body/DocFragment[3]/body/p[12]/text().40",
 "percentage":0.4312,"device":"Pocket Daily iPhone","device_id":"<uuid hex>"}
```

- `DocFragment[N]`: spine 순서의 1-based 번호(비선형 항목 포함).
- 요소 번호는 같은 이름 형제 중 1-based. 같은 이름이 하나뿐이면 번호를 생략한다(읽을 때는 둘 다 허용).
- `text()[m]`: 공백만 있는 텍스트 노드를 제외한 1-based 번호. 하나뿐이면 생략.
- `.offset`: 텍스트 노드 안의 Unicode code point 위치(UTF-16 아님).
- `percentage`: 0~1 전체 진행률, **현재 페이지 시작** 기준(KOReader와 같음). foliate의 relocate
  `fraction`은 페이지 끝 기준이고 한 페이지짜리 섹션에서 NaN이 되므로 쓰지 않고, renderer의 섹션 내
  위치와 섹션 크기 비율로 계산한다. XPointer를 해석할 수 없으면 percentage로 이동한다.

### 이어 읽기 규칙

- 책을 열 때 원격 진행도를 조회한다. 다른 기기의 기록이고 위치 차이가 의미 있으면
  **자동 이동하지 않고** "X3에서 43%까지 읽음 · 이동" 제안을 표시한다.
  기기 시계가 신뢰할 수 없으므로 시간만으로 이기는 쪽을 정하지 않는다.
- 페이지를 넘긴 뒤 잠시 멈추거나, 책을 닫거나, 앱이 백그라운드로 가면 업로드한다.
- 실패는 읽기를 방해하지 않고 설정 화면과 책 화면의 작은 상태로만 알린다.
- 비밀번호 MD5 키는 Keychain에만 둔다. 로그·진단에 서버 응답 본문이나 키를 남기지 않는다.

### 기기 직접 교환

reading-progress v1로 구현했다([READING_PROGRESS.md](READING_PROGRESS.md), 펌웨어 `reading-progress-v1.md`).

## 앱 구조

- `Sources/Library/`: 서재 레코드, 가져오기(파일·Articles·직접 작성), 문서 식별, 서재 화면.
- `Sources/Reading/`: 렌더러 브리지(WKWebView), 읽기 화면, 모양 설정, 위치 저장.
- `Sources/Sync/`: 위치 레코드, iCloud·리더 교환, 이어 읽기 제안.
- 최상위 화면: Library(첫 화면) · Reader. Reader 아래에 Connection(연결·펌웨어·Bluetooth) · Screens · Files가
  온다(아래 "기기 중심 구조" 참고). 넓은 화면은 사이드바의 Library 아래 Books·Articles, Reader 아래 세 항목으로
  이동한다. iPhone은 Library·Reader 두 탭이고, Reader 탭 위쪽에서 페이지를 고른다.
  서재 제목 메뉴에서 Books·Articles를 전환한다.
- 책은 모든 플랫폼에서 같은 앱 창의 읽기 화면으로 열린다. Library로 돌아오면 기존 분류와 스크롤 위치가 유지된다.
  Appearance·Continue Reading은 Settings 한 곳에 있다: 사이드바 아래 Settings, iPhone은 서재 머리의
  톱니, macOS는 Settings 창(⌘,). 리더의 Bluetooth 페어링은 Reader → Connection에 있다.
- 서재의 책은 "리더로 보내기"로 기존 전송 대기열을 사용한다.
- 데모 모드는 기기 기능에만 적용된다. 서재·읽기는 실제 기능이며 기기를 바꾸지 않는다.
  처음 실행하면 원본 안내 책 한 권을 서재에 만든다.

## 기기 중심 구조 — 2026-10-01 결정

기기는 화면 두 개(Screens, Device)로 나뉜 기능 묶음이 아니라 하나의 대상이다. 앱은 기기 없이 완결되고,
기기가 있으면 그 기기 아래에서 설정·파일·위치를 다룬다.

- 이름은 제품명이 아니라 **Reader**다. 앱은 특정 제품을 공식 지원하는 것이 아니라 Pocket Daily 또는 호환
  CrossPoint 기반 펌웨어를 쓰는 리더를 지원한다. 모델명(X3/X4)은 연결된 리더가 스스로 알려 줄 때만
  상태에 붙는다("X4 · Same Wi-Fi"). 연결 전에는 "Reader · Not connected"이고, Connection 카드에 호환 범위를
  한 줄로 밝힌다. Screens의 X3/X4 선택은 기기 정체가 아니라 "Preview" 크기다.
- 사이드바 Reader 아래 Connection → Screens → Files 순서. Connection 행이 상태 점과 상태를 함께 보여 준다.
  연결이 먼저, 화면 설정이 다음이다. Screens는 별도 페이지로 둔다: 미리보기를 고정한 긴 편집기라
  연결·펌웨어 카드와 섞으면 둘 다 불편하고, 편집·미리보기는 연결 없이 되며 Apply만 연결을 요구한다.
- 화면은 원시 `/api/status` 필드 대신 기기 스냅샷(`DeviceSnapshot`: 계열·보고된 모델·연결·기능 집합)을 본다.
  기능 집합은 `screens`·`files`·`readingPositions`·`firmwareUpdate`·`bluetoothSync`이고, 현재 CrossPoint
  계열(X3/X4) 어댑터가 상태 응답과 BLE `CAP`을 이 집합으로 바꾼다. 다른 펌웨어 계열은 어댑터와 하위 항목
  목록만 더한다. 계약은 플랫폼 중립으로 두어 Android도 같은 구조를 쓴다.
- 연결 상태는 앱 전체가 공유한다: 사이드바 Connection 행, iPhone Library 머리의 상태 표시, Reader 탭 머리.
- 같은 Wi-Fi 자동 재연결: 마지막 리더가 마지막 주소에서 같은 기기 ID로 응답하면(리더에서 Sync → Same
  Wi-Fi가 열려 있으면) 앱이 세션을 연다. 그 주소 하나만 묻고, 네트워크를 바꾸거나 훑지 않는다. 사용자가
  End session하면 리더가 한 번 응답하지 않을 때까지 다시 붙지 않는다. Direct connection은 계속 명시적이다.
  Settings에서 끌 수 있다.

단계:

1. 구조 개편, 기기 스냅샷과 기능 집합, 공유 상태 표시, 같은 Wi-Fi 자동 재연결 (앱만).
2. 연결 중이면 서재에서 바로 보내기, 책별 "기기에 있음" 배지와 필터, 책별 기기 위치 표시.
   리더 파일 목록이 서재와 대조할 식별값(부분 MD5)을 주지 않으면 펌웨어 계약 변경이 필요하다.
3. 리더 → 서재 가져오기(파일 다운로드 계약), 두 번째 기기 계열.

2단계 구현(2026-10-01, 앱만): 연결되면 앱은 리더 레인이 비었을 때 한 번(그리고 전송·삭제 뒤마다)
`/` 와 `/Articles` 파일 목록과 `/api/pocket/v1/reading`(최근 EPUB 10권, 부분 MD5·진행률)을 읽어
`ReaderInventory`로 둔다. 서재는 이를 `ReaderShelf`로 맞춘다: 지문이 있으면 지문, 없으면 파일 이름과 크기
(앱은 서재 파일을 이름·바이트 그대로 보낸다). 책 타일에 "On reader · 43%", Books 아래 "Only on your reader"
목록, 연결 중이면 책 메뉴 "Send to reader"가 Files를 거치지 않고 바로 보낸다. 세션이 끝나도 목록은
"Seen on X4 …"로 남는다. 목록은 이름 기준이라 하위 폴더의 책은 최근 읽은 책일 때만 보인다.

3단계 계약(펌웨어 `docs/reader-files.md` "Reader file download", PR #12): `readerFiles: 2`가
`GET /api/pocket/v1/files/content?deviceID&path&size&offset`을 연다. 한 번에 한 조각(Same Wi-Fi ≤ 4 KiB,
Direct ≤ 1 KiB), 받은 만큼 offset을 늘린다. 503은 0.5 s부터 4 s까지 두 배로 늘려 같은 offset 재시도, 409는
0부터 한 번만 다시, 416·크기 불일치는 실패. 합이 `size`와 같고, 리더가 지문을 알려 준 책은 부분 MD5도
같아야 서재에 넣는다. EPUB만 "Add to Library"를 보인다(TXT·MD는 가져오면 EPUB로 바뀌어 다시 맞지 않는다).
앱 쪽은 구현·단위 시험 완료, 펌웨어 구현은 대기 중이라 실기기 검증 전이다. `readerFiles` 검사는 모두 `>= 1`이다.

## 구현 상태 (2026-09-27, 미커밋)

- 1단계 완료(로컬 검증): Library 첫 화면, 안내 책, EPUB/TXT/MD 가져오기(CP949 포함), 중복 제거, 리더
  (탭·키보드·목차·모양·2단·앱 내 읽기), 위치 저장·복원, Articles를 서재에서 읽기.
- 2단계: iCloud·리더 직접 교환(서버 없음). KOSync 연동은 이번 버전에서 제외.
- 3단계 진행: 스토어 메타데이터·심사 노트·개인정보·공개 페이지·스크린샷 구성 변경.
- 남음: X3/X4에서 직접 교환 왕복 검증, iCloud 서명 빌드 확인,
  하이라이트·단어 저장, 책 검색, VoiceOver 읽기 점검, Android.

## 단계와 완료 기준

1. 정체성·문서 재정렬, 서재·리더 MVP(EPUB, TXT/MD는 EPUB로 변환해 읽기), 로컬 진행도.
2. iCloud·리더 직접 교환과 이어 읽기 제안.
3. 스토어 메타데이터·개인정보·심사 노트·스크린샷 갱신(바이너리에 있는 기능만).
4. 기기 직접 진행도 교환(펌웨어 계약), iCloud 기기 간 서재, 하이라이트·단어 저장.
5. Android.

완료로 주장하려면 단위 시험(식별값·XPointer·API 오류)과 iOS/macOS 빌드, 리더 UI 시험,
iCloud·리더 교환 결과를 구분해 기록한다. 실기기 X3/X4와의 이어 읽기는 실기기 결과로만 주장한다.

## Articles inbox — 2026-09-28

Articles now supports local RSS 2.0 / Atom subscriptions, offline text, independent
read/saved states, source filters, and explicit existing EPUB preparation. It refreshes
on foreground activation and user request; email inbox integration, library-content
cloud sync and scheduled background delivery are outside this version. See
[ARTICLES.md](ARTICLES.md) for retention, parsing and unchanged firmware contracts.
