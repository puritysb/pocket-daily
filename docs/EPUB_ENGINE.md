# EPUB 생성 엔진 — PD-01/04 첫 단계

2026-09-26. 구현 범위는 `Sources/Convert/`, 생성/전송 준비 시험과 Files의 글쓰기 연결이다.
네트워크 수집·HTML 파싱·PDF/DOCX 변환·이미지는 후속 작업이다.
현재 입력은 **순서가 있는 장과 일반 텍스트 문단**이다. HTML 태그를 전달해도
실행/해석하지 않고 본문 문자로 이스케이프한다.

## 앱 통합 API

```swift
let document = EPUBDocument(
    title: "오늘 읽을 기사",
    language: "ko",
    author: "작성자",
    chapters: [
        .init(title: "첫 기사", paragraphs: ["첫 문단", "둘째 문단"]),
        .init(title: "둘째 기사", paragraphs: ["기사 본문"])
    ]
)
let url = try await EPUBExporter.write(document, to: exportRoot)
// 기존 전송 준비 경로로 url을 복사한 뒤 url.deletingLastPathComponent()를 제거한다.
```

- `exportRoot`는 호출자가 정한 로컬 디렉터리다. 성공 시 새로운 UUID 하위 폴더의
  `정리한 제목-출판물UUID.epub` URL을 반환한다. 파일명의 제목은 경로 문자를 제거하고
  파일시스템의 유니코드 분해 정규화 후에도 120 UTF-8 bytes 이하로 제한한다.
  같은 제목의 다른 책도 전송 목적지에서 충돌하지 않으며
  같은 출판물 UUID를 유지하면 이름도 유지된다. 기존 파일을 덮어쓰지 않는다.
- `write`는 변환과 파일 I/O를 별도 task에서 실행하므로 UI actor에서 await할 수 있다.
  호출 task의 취소는 작업 task에 전달된다. 게시 직전까지 취소를 확인하며
  이미 반환된 파일과 폴더의 수명은 호출자가 소유한다.
- `.part`에 작성·동기화·닫기 후 같은 폴더 안에서 rename한다. 실패/취소 시 해당
  내보내기의 폴더만 제거한다. 출력 디렉터리 생성 실패 등은 Foundation 오류로,
  입력·크기 오류는 `EPUBExportError`로 전달한다. 디스크 문제로 임시 폴더 삭제까지
  실패하면 `cleanupFailed`로 알려준다.
- 반환 URL은 아직 전송 대기열에 등록되지 않은 로컬 결과다. 기존 준비 목록에
  복사한 후 재실행 보존을 검증해야 한다. 생성 완료는 전송 완료가 아니다.
- 각 장의 `sourceURL`은 선택 항목이며 출처 링크로 기록할 뿐 접근하지 않는다.
  HTTP/HTTPS, host 존재, 사용자명/암호 없음, 2048 UTF-8 bytes 이하를 요구한다.
- `identifier`와 `modified`를 보관해 재사용하면 같은 입력의 EPUB 바이트도 같다.
  새 기본값은 UUID와 현재 시각이다. 날짜는 1970년부터 9999년까지 지원한다.

## 형식과 크기 제한

- EPUB 3 OPF, XHTML nav와 NCX를 함께 쓴다. NCX의 UID는 OPF 식별자와 같다.
  spine·nav·NCX는 같은 섹션 순서를 사용한다. nav 자체는 독서 spine에 넣지 않는다.
- ZIP32, 무압축(STORE). 첫 항목은 extra field 없는 `mimetype`이며 내용은
  정확히 `application/epub+zip`. 암호화·ZIP64·data descriptor는 쓰지 않는다.
- 시스템 zlib은 CRC-32에만 사용한다. 이미 두 앱 target이 연결하는 libz이며
  새 패키지 의존성은 없다. 저장 방식이라 압축 EPUB보다 전송 크기가 크다.
- 원문 문단 총 4 MiB, 문단 수 16,384개, 입력 장/출력 섹션 각각 최대 128개.
  책 제목·작성자·장 제목은 각각 256 UTF-8 bytes 이하. 빈 장은 거절한다.
- 언어는 `und` 또는 `ko`, `en-US`, `zh-Hant-TW`처럼 2~3자 언어 + 선택적
  4자 script + 선택적 2자/3숫자 region을 지원한다. BCP 47 확장/variant는 아직 제외한다.
- 각 본문 XHTML과 nav는 **이스케이프와 wrapper 포함 64 KiB 이하**.
  문단이 들어가면 통째로 유지하고, 큰 문단은 Character(확장 자소) 경계로 나눈다.
  후속 섹션은 `장 제목 (2)`처럼 목차에 표시된다. 원문의 CRLF/CR은 LF로 정규화하고
  문단 내부 줄바꿈은 `<br />`로 보존한다. 공백만 있는 문단은 생략한다.
- XML 1.0 불허 제어문자는 거절한다. 글자 하나가 섹션 예산보다 크거나 분할 후
  섹션 수/목차 크기가 초과되면 실패하며 입력 문서를 더 작게 나누도록 안내한다.
- 이 제한은 **앱의 초기 자원 예산**이다. X3/X4에서 64 KiB가 최적이거나 모든
  폰트로 충분한 메모리가 남는다는 실측 결과는 아니다.

## 호환 근거와 검증 범위

- 표준 근거: [W3C EPUB 3.3](https://www.w3.org/TR/epub-33/).
- 펌웨어의 [ZipFile.cpp](../../pocket-daily-firmware/lib/ZipFile/ZipFile.cpp)는
  STORE를 읽으며, [ContentOpfParser.cpp](../../pocket-daily-firmware/lib/Epub/Epub/parsers/ContentOpfParser.cpp),
  [TocNcxParser.cpp](../../pocket-daily-firmware/lib/Epub/Epub/parsers/TocNcxParser.cpp),
  [TocNavParser.cpp](../../pocket-daily-firmware/lib/Epub/Epub/parsers/TocNavParser.cpp)의
  경로·manifest·spine·목차 구조에 맞춘다. 펌웨어 파일이나 캐시 형식은 변경하지 않는다.
- 자동 시험은 ZIP 중앙 디렉터리와 local header 일치, 독립 bitwise CRC 계산,
  XML 파싱, manifest/spine/nav/NCX 연결, 한글·이모지·특수문자 복원,
  정확한 크기 경계·초과·입력 오류·취소·출력 정리를 검사한다.
- 독립 Python `zipfile.testzip()`와 XML 파싱으로도 샘플을 검사한다.
  이는 **구조 검증**이며 EPUBCheck 전체 적합성 검사나 기기 읽기 시험을 대체하지 않는다.
- 실기기 수용은 미완료다. 다른 세션의 X3 확인 절차에서 샘플을 기존 파일 전송으로
  보내고, 첫 열기·각 목차 이동·한글 폰트·분할 경계·마지막 장·재열기/진행도 보존을
  확인한다. 책 제목, 펌웨어 버전, 폰트와 결과를 남긴다. X4는 별도 확인한다.

## 앱 화면과 세션 간 통합

- 앱 `047af74`에서 만든 `feat/epub-engine` worktree(`../pocket-daily-epub`)를
  `d9dcfd8`까지 fast-forward했다. Claude 중단 후 사용자의 요청으로 앱 통합과
  중단된 펌웨어 구현의 검증을 이어받았다. 커밋/푸시/릴리스는 하지 않았다.
- Files → Add → Write text to read에서 EPUB(기본) 또는 Plain text를 선택한다.
  제목이 비면 Reading을 쓰고, 빈 본문은 준비할 수 없다. EPUB은 목차와 긴 본문
  분할을 제공한다. 여러 기사의 구조화 입력은 생성 API에서 지원하며 UI는 단일 글이다.
- `ReadingDocumentPreparation.create`가 파일을 만들고,
  `PocketModel.prepareGeneratedReadingFile`이 기존 로컬 전송 대기열의 새 영수증을
  확인한다. 복사 확인 후 내보내기 폴더를 삭제한다. 자동 연결/전송은 하지 않는다.
- 실패하면 입력을 유지한다. 생성 중 취소/백그라운드 전환은 작업을 취소한다.
  대기열 복사가 시작되면 완료까지 기다려 복사 중 원본 삭제를 방지한다.
  임시 파일 삭제 실패는 재시도하며 이미 대기열에 넣은 책을 다시 생성하지 않는다.
- `project.yml`은 폴더 단위 포함이므로 변경하지 않는다. pbxproj는 XcodeGen으로
  재생성한다. 다른 세션의 main과 `.build/`는 별도로 유지한다.
- PD-01/04 전체는 완료하지 않았다. HTML/URL 가져오기, 이미지, PDF/DOCX와
  실기기 수용이 남았다. 네트워크 수집 추가 시 개인정보/스토어 문구를 검토한다.

## 2026-09-26 로컬 검증 결과

- iOS 26.5 / iPhone 17 Pro Max 시뮬레이터: 전체 `PocketTests` 300개 통과.
  그 뒤 파일명 충돌·경로·한글 정규화 시험 추가 및 보정 후 최종 EPUB 시험
  **13개 통과**. 최종 변경 후 전체 301개를 재실행한 결과로 표기하지 않는다.
- iOS 앱/시험 빌드와 최종 macOS 앱 빌드 통과. 기존 ReaderGlanceTests의 Swift 6
  캡처 경고는 이 작업에서 수정하지 않았다. 화면 코드는 변경하지 않아 새 UI
  스크린샷을 생성하지 않았다.
- XcodeGen으로 생성한 프로젝트 diff는 새 소스 3개·시험 1개의 파일 등록만 포함한다.
  generator/Xcode의 무관한 Mac scheme 변경은 포함하지 않았다.
- 독립 Python ZIP CRC·XML·manifest/spine/nav/NCX 연결 검사 통과.
  EPUBCheck는 실행하지 않았다(현재 호스트에 Java runtime 없음).
- 실기기 확인용 샘플: worktree의
  `.build/epub-samples/pocket-daily-epub-check.epub` (추적하지 않는 로컬 산출물).
  한글/영문/이모지/특수문자/출처 링크/긴 본문을 포함하며 3개 입력 장→5개 섹션,
  최대 XHTML 65,536 bytes. SHA-256:
  `c175a49c25ccdd503059d8bad66619274eeb92bc343d749f753af0df1ac450cc`.
- 위 결과는 엔진 단독 단계의 이력이다. 아래 통합 검증 결과를 우선한다.
- 실제 X3/X4 읽기는 아직 미검증이다.


## 2026-09-26 통합 검증

- 앱 기준 `d9dcfd8` + 이 worktree의 변경: 전체 `PocketTests` **314/314 통과**.
  새 생성 엔진 13개와 로컬 준비 5개를 포함한다.
- iPhone 17 Pro Max / iOS 26.5에서 새 EPUB 화면 흐름 통과: 기본 EPUB 선택,
  빈 입력 방지, 메타데이터 실패 후 본문 유지, 대기열 등록, 앱 재실행 후 보존.
- 최신 펌웨어 공유 렌더러로 host XCFramework를 다시 빌드하고 출처/바이너리
  해시를 검증해 가져왔다. source SHA-256
  `fe20e4a05c421123b9d4577a21550b2c6cd21c21311ad9bd806d75f7c9c9f470`,
  artifact SHA-256 `be64dc42a575d5b661c1f77903c0701895c213e0581798f073c6180691186d42`.
  해당 artifact를 포함한 macOS 앱 빌드 통과.
- 최신 host artifact로 `HostRendererBridgeTests` **10/10 통과**, iOS 앱 재빌드 통과.
- `scripts/capture_screenshots.sh` 성공: iPhone/iPad 각각 UI 흐름 10개와 캡처 시험,
  Mac 화면 캡처. iPhone 4장 + iPad 4장 + Mac 3장, 총 **11장**을 재생성하고
  실제 이미지를 검토했다. 스크립트 마지막 `validate_app_store.sh` 통과.
  물리 기기 캡처를 요구하는 Mac parity 시험은 입력이 없어 이번 검증 범위에서 제외한다.
- 기존 `ReaderGlanceTests` Swift 6 캡처 경고와 `HostRendererBridge.copyBytes`의
  미사용 반환값 경고는 남아 있다. 빌드/시험 실패는 없다.
- 기존 CI의 exit 127 대응(`pio pkg install -e default`)은 펌웨어 커밋
  `af70853c`에 이미 있다. 이번 로컬 cppcheck 배포 미러 오류와 별개이며,
  원격 CI 성공을 새로 검증한 것은 아니다.
