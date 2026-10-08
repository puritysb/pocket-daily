# IA 구현 및 검증 보고

갱신일: 2026-10-09. 날짜별 기록은 아래에 이어진다. 10월 5일의 완료 판정은 [재검토](IA_UX_AUDIT.md)에서 철회했다. 그때 확인한 여섯 문제를 [개선 기준](IA_UX_REFINEMENT.md)에 따라 다시 구현했다. 이 보고는 수정된 과업 경계와 검증 증거를 구분하며, 테스트 수를 사용성 검증으로 대신하지 않는다.

## 구현 결과

앱 독서와 리더 활용은 동등한 목적지로 유지했다. 기존 독서 엔진, 원본 책 저장, 읽던 위치 계약, 연결·전송 실행권, 원자적 게시와 펌웨어 검증을 재사용했다. 세 Sol 에이전트가 편집·탐색·전송을 담당하고 루트가 과업 경계, 교차 검토와 통합 검증을 맡았다. 펌웨어 프로토콜 변경이나 자동 설치는 없다.

| 사용자 과업 | 수정한 동선과 경계 |
| --- | --- |
| Home/Sleep 꾸미기 | 선택한 화면의 미리보기·구성·변경 상태·단일 적용 행동. 카드 선택으로 부모 미리보기가 다른 대상으로 바뀌지 않는다. |
| 카드·날씨·일정 수정 | Screens의 요약 행에서 각 원본 전용 편집기를 연다. Home/Sleep 공통 사용을 명시하고, 원본 작업마다 적용 하나만 둔다. 연결도 편집기 안에서 열며, 복귀 시 입력과 부모 화면을 보존한다. |
| 기기 읽기 방식 변경 | 앱 읽기 외관과 분리. X3/X4와 세로·가로에 맞는 실제 버튼 위치에서 Previous/Next를 표시하고, 중복 대응표와 설명을 줄였다. |
| 콘텐츠 추가·작성 | 일반 책·글은 Library가 소유한다. On Reader는 실제 파일과 SD 공간, Add from Library, 기기 전용 파일 보조 진입만 제공한다. RAM·폰트 안내는 Device로 옮겼다. |
| 선택한 책 보내기 | 동일한 작업에서 무선 또는 macOS SD를 선택한다. SD는 폴더만 다시 선택하며 책은 유지한다. SD 결과와 무선 결과·대상·불확실성을 별도로 보존한다. |
| 연결·실패 복구 | 같은 Wi-Fi 찾기를 우선하고 다른 방법은 펼쳐서 선택한다. 결과 미확인 중 다른 리더가 연결돼도 작업 안에서 원래 리더에 다시 연결할 수 있다. 연결 후 자동 전송하지 않는다. |
| 진행 중 작업으로 돌아가기 | 책, 파일 가져오기, Home/Sleep, 카드/날씨, Reading, 펌웨어, 진단의 실제 소유 화면으로 이동한다. Sleep 작업을 Reading으로 잘못 여는 문제와 지난 원본 편집기가 다시 열리는 문제를 막았다. |
| 리더 상태 확인 | Mac Overview의 사이드바 메뉴 반복을 제거하고 현재 리더·연결·진행/복구할 작업을 중심으로 구성했다. Bluetooth 페어링과 위치 교환 확인을 구분한다. |

날씨 공급자 표시는 작은 보조 행에 남겼다. 카드와 지역의 로컬 저장을 리더 적용 완료로 표현하지 않는다. Settings는 현재 창에서 앱 외관과 이어 읽기 정책을 관리한다.

## 시나리오 검토

Mac의 정상 실행본에서 다음을 직접 확인했다. 사용자의 서재·읽던 위치·날씨 지역은 보존했다. 연결 화면을 여는 검사는 실제 검색·페어링·전송 없이 수행했다.

- Home → My cards → 연결 → 뒤로 → 닫기: 카드 원본 편집과 부모 Home의 대상·미리보기가 분리되고 복귀가 유지된다.
- Weather & calendar → 지역 임시 입력 → 연결 → 뒤로: 확정하지 않은 입력까지 유지된다. 검사 뒤 취소해 기존 지역을 유지했다.
- Reading: 모델과 방향의 버튼 그림에서 이전/다음 동작을 확인하며 중복 설명이 주 화면을 차지하지 않는다.
- Library의 선택한 책 → 보내기 → SD/Wi-Fi 전환: 책을 다시 고르지 않는다. 검사에서 만든 미전송 작업만 폐기했다.
- On Reader와 Overview: 일반 책 작성·RAM·폰트와 네 개의 중복 목적지 카드가 제거된 것을 확인했다.

교차 검토에서 복수 파일 전송의 첫 항목이 완료되면 진행·Pause·Stop이 사라지는 문제를 발견했다. 실행 중인 배치의 원래 범위를 유지하도록 수정하고, 첫 파일 완료·두 번째 파일 대기 상태를 재현하는 회귀 검사를 추가했다.

## 검증 기록

| 검사 | 결과 및 증거 |
| --- | --- |
| 전체 iOS 단위 테스트 | 529개 통과, 실패 0. `.build/ux-refinement/unit-final.xcresult` |
| 최종 전송·작업 회귀 | 배치 제어 수정 후 관련 44개 통과. `.build/ux-refinement/transfer-final.xcresult`. 전체 529개를 이 수정 뒤 다시 실행한 것으로 계산하지 않는다. |
| iOS 빌드 | 위 테스트 실행에서 앱과 테스트 대상 빌드 통과 |
| macOS 최종 빌드 | 개발 서명·기본 샌드박스 구성 빌드 통과. `.build/ux-refinement/mac-final.log` |
| iPhone UI 흐름 | 26개 통과, 실패 0. `.build/ux-refinement/iphone-flows.xcresult` |
| iPad UI 흐름 | 카드 단일 적용, 개요, Screens/Reading 범위, 공통 원본, 책 작업 복귀, 연결 중 임시 입력 보존 6개 통과. `.build/ux-refinement/ipad-flows.xcresult` |
| Mac 검사 | 전체 실행에서 8개 통과·2개 실패·선택 샘플 1개 건너뜀. 두 실패의 테스트 호스트 문제를 보완한 뒤 해당 2개 재검증 통과. `.build/ux-refinement/mac-final.xcresult`, `mac-recheck.xcresult`. 최종 미해결 실패 없음. 펌웨어 XPointer 교차 검사 포함. |
| 스크린샷·스토어 자료 | 실제 UI 19장(폰 6·패드 7·Mac 6) 재생성 및 편집 관련 캡처 육안 확인. 전체 캡처 스크립트 통과 후 Mac 시트 캡처를 보완해 6장을 다시 생성하고 `validate_app_store.sh` 재통과. `.build/ux-refinement/screenshots.log`, `screenshots-iphone-6.9.xcresult`, `screenshots-ipad-13.xcresult`, `mac-recheck.xcresult` |
| 문서·변경 검사 | 관련 문서의 로컬 링크 존재 및 `git diff --check` 통과 |

Mac 최종 이미지 검토에서 단독 뷰 호스트가 실제 카드 시트의 제목·Close를 누락하는 것을 발견했다. 실제 ContentView에서 열린 native sheet와 부모 화면을 캡처하도록 테스트 호스트를 수정했다. 시트의 `NSWindow.toolbar` 및 오프스크린 접근성 속성을 전제한 추가 검사도 실제 동작과 맞지 않아, 실제 시트·bitmap 존재와 크기를 검사하고 제목·Close는 내보낸 이미지로 확인한다. 앱 코드는 이 캡처 수정으로 바꾸지 않았다.

Guide 독서 검사는 페이지 위치 준비 직후 snapshot을 찍어 간헐적으로 빈 첫 프레임을 검사했다. 최대 5초 동안 실제 본문 픽셀을 기다리도록 테스트만 수정했으며 기존 ink 판정 기준과 오류 전파를 유지했다. 이 검사와 카드 캡처는 `mac-recheck.xcresult`에서 모두 통과했다. Mac 전체를 한 번의 실행으로 모두 통과했다고 기록하지 않는다.

최종 정상 실행본 `.build/ia-mac-review/Build/Products/Debug/Pocket.app`을 Screens → Home에서 열어 두었다. 서재·읽던 위치·기존 카드·날씨 지역을 유지했으며 검증용 미확정 입력은 취소했다.

## 범위와 검증 한계

실제 Bluetooth 페어링, 직접 Wi-Fi 전환, 물리 리더와의 파일 전송, 마운트한 SD 카드의 권한·복사, 펌웨어 설치 및 물리 패널 표시는 별도 하드웨어 수용 대상이다. SD 테스트는 임시 폴더와 모의 실패를 사용해 원본 바이트, 충돌 보호, 부분 완료, 중복 실행, 취소와 재시작 복구를 검증했다. 기기 버튼 매핑은 형제 펌웨어 계약을 유지한다.

이 검토는 합의된 IA 및 사용자 시나리오와 구현의 대조다. 실제 사용자 대상 사용성 실험, 장시간 성능 측정 또는 macOS Space 영속 복원을 검증했다고 주장하지 않는다.

전체 책의 자동 양방향 동기화, 여러 리더 동시 관리, 계정, 앱의 책별 외관 예외와 기기 라이브 화면 캡처는 후속 범위다. 복수 책 작업 계층 지원을 복수 선택 UI 구현으로 표현하지 않는다. 커밋·푸시·배포·App Store 제출은 수행하지 않았다.

## 2026-10-08 사용자 시나리오 평가·개선 루프

Mac QA 렌더(`testRendersUserFlowStates`, `testRendersReaderTasksAndButtonMappings`)와 새 iPhone 투어(`UITests/PocketQATourTests`: 리더 없는 첫 실행, 데모 동반 기능)를 캡처해 화면 단위로 평가하고, 고친 뒤 같은 시나리오로 다시 평가했다. 투어 캡처 이름은 `qa-tour-`로 시작하므로 스토어 캡처에 섞이지 않는다.

| 발견 | 개선 |
| --- | --- |
| Mac/iPad 개요의 미연결 상태가 카드 하나와 따로 떨어진 'Edit Home offline' 버튼뿐이었다 | 처음 연결하는 경우 호환 범위와 리더 쪽 절차(Sync → Same Wi-Fi)를 카드에 표시하고, 오프라인 편집을 Connect 옆 보조 행동으로 옮겼다 |
| Device의 'Continue Reading settings'가 제목처럼 보여 눌러지는 행동인지 알기 어려웠다 | 톱니 아이콘과 말줄임표를 붙인 버튼으로 바꿨다 |
| 책 보내기 시트와 화면 편집의 연결 절차 안에 'Try demo'가 있어 진행 중인 작업을 버리고 데모로 갈 수 있었다 | 작업 안의 연결에서는 데모를 숨긴다. Device와 일반 연결 화면에는 남긴다 |
| 보내기 시트의 연결 단계에서 아무것도 진행되지 않을 때도 'Cancel connection'이라고 표시됐다 | 'Back to transfer'로 바꿨다. 진행 중인 시도는 기존처럼 먼저 중단한다 |
| 데모 보내기 시트에 '고유 ID 없음' 경고가 나타났다 | 데모에서는 표시하지 않는다 |
| iPhone 서재 헤더의 부제와 연결 상태가 +/Settings에 밀려 두 줄로 깨졌다 | 제목 줄에 행동 버튼을 두고 부제·상태가 전체 폭을 쓰게 했다 |
| iPhone의 Screens/Reading 미리보기가 약 100pt 폭이라 내용을 판단하기 어려웠다 | 좁은 화면에서 미리보기를 누르면 편집을 벗어나지 않고 전체 크기 시트로 본다 |
| 데모 On Reader가 비어 있어 기기 보관함이 무엇을 보여 주는지 알 수 없었다 | 예시임을 밝힌 파일 세 개를 보여 준다. 기기에서 읽은 값이 아니며 행동 버튼은 없다 |
| `--ui-test-fresh-library` 실행마다 이전 실행의 준비 사본이 'Paused' 책 전송으로 복구돼 하단 작업 막대가 누적됐다 | DEBUG의 fresh-library 실행에서는 준비 사본과 작업 기록도 임시 폴더를 쓴다. 정식 경로는 바뀌지 않는다 |

검증: iOS 단위 테스트 530개 통과(`.build/ux-loop3/unit.xcresult`). iPhone 투어 2개 통과(`iphone-tour3.xcresult`). Mac QA 렌더 4개 통과(`mac-qa.xcresult`, `mac-qa2.xcresult`). macOS 빌드와 서명된 Debug 빌드 통과. iPhone UI 흐름은 전체 실행에서 32개 통과, 1개(`testSystemShareExtensionSavesTextIntoAppLibrary`)는 실패 후 단독 재실행에서 통과. iPad Pro 13 UI 흐름은 30개 통과, 같은 공유 확장 테스트 1개가 단독 재실행에서도 실패했다. iOS 27 iPad 공유 시트에서 Pocket Daily를 고른 뒤 확장 화면이 10초 안에 나타나지 않는다. 이번 변경은 공유 확장을 건드리지 않았지만 이전 커밋에서 같은 실패를 재현하지는 않았다. iPad Pro 11 세로 화면은 상단 부동 탭 막대를 쓰는데 UI 테스트 도우미가 하단 탭 막대만 인식해 흐름 테스트 대상이 아니다. 스토어 캡처 19장을 캡처 전용 모드로 다시 만들었고 `validate_app_store.sh`가 통과했다. 실제 리더·무선·SD 동작은 이번 루프에서 확인하지 않았다.

## 2026-10-09 인계 검토와 커밋 전 검증

위 UX 변경을 검토하고, 캡처 중심 투어와 별도로 `PocketFlowTests`에 데모 예시 3개·전송 차단, 작은 미리보기 확대/닫기 후 상태 유지, 편집 연결에서 데모 진입 차단을 명시적으로 검증하는 단언을 추가했다. `xcodegen generate`로 새 투어 파일의 프로젝트 등록을 확인했다. 앱/펌웨어 통신 계약은 변경하지 않았다.

공유 실패를 재현한 iPhone 녹화에는 탭 이후에도 시스템 공유 시트가 남아 있었고 확장 프로세스 실행 기록이 없었다. 바깥 셀 대신 그 안의 실제 `activityImageView`를 탭하도록 테스트를 보완한 뒤 iPhone과 iPad에서 확장 입력·저장·서재 반영까지 통과했다. 최초 iPad 실행은 시스템 공유 시트 자체가 비어 있었으므로 그 시작 문제까지 해결했다고 보지는 않는다. 실패를 건너뛰거나 제한 시간을 늘리지는 않았다.

검증 결과는 `.build/handoff-review/`에 보관한다.

| 검사 | 결과와 근거 |
| --- | --- |
| iPhone 17 Pro Max, iOS 26.5 | `iphone.xcresult`: 단위 530개, 일반 UI 흐름 25개, QA 투어 2개 통과. 공유 1개 실패는 아래 재검증으로 구분 |
| 보완한 iPhone 회귀 검사 | `iphone-regression.xcresult`: 데모/확대 미리보기와 편집 연결 2개 통과 |
| 수정 후 iPhone 공유 | `iphone-share-final.xcresult`: 시스템 공유 → 확장 저장 → 서재 확인 1개 통과 |
| iPad Pro 13, iOS 27 | `ipad-final.xcresult`: 데모, 책 전송 연결 복귀, 편집 연결 복귀, 수정 후 공유 4개 통과 |
| macOS | `mac-build.log`, `mac.xcresult`: 빌드 및 10개 테스트 통과. 외부 EPUB 샘플 폴더가 필요한 1개만 건너뜀 |
| 스토어 자산 | `screenshots-final.log`: 스크립트로 iPhone 6장·iPad 7장·Mac 6장 재생성, 화면 확인 및 소스 패키지 검사 통과 |
| 저장소 | 문서 로컬 링크, `git diff --check` 통과. `main`과 기본 checkout만 있으며 stash와 정리할 별도 worktree/브랜치는 없음 |

UI 검사는 최종적으로 순차 실행했다. 병행 실행에서 테스트 러너 시작이 대기한 두 실행은 중단한 뒤 다시 수행했으며 성공 근거로 세지 않았다. 실제 Bluetooth/Wi-Fi/SD 및 TestFlight 검증, 푸시와 App Store 제출은 수행하지 않았다.

## 2026-10-09 디자인 시스템 정비

[디자인 시스템](DESIGN_SYSTEM.md)과 `Sources/PocketDesign.swift`를 추가해 제목, 아이콘 칸, 행동 영역, 간격과 카드 규격을 공통화했다. Mac의 반복 창 제목을 숨기고 본문 헤더가 제목 표시줄 영역까지 사용하도록 했다. 창 조작 버튼에는 여유를 남기며, 실제 창에서 상단 추가 메뉴가 눌리는 것도 확인했다. 서재의 장식용 부제를 제거하고 서재·편집 화면의 왼쪽 기준선을 맞췄다. 사이드바와 공통 카드의 아이콘은 고정 칸에 배치하고 작은 화면의 아이콘 행동은 44pt 영역을 유지한다.

큰 글자 캡처에서 책 격자의 제목과 iPad 사이드바 이름이 잘리는 것을 확인해 보완했다. 접근성 크기에서는 서재가 제목 전체를 보여 주는 한 열 가로 행으로, iPad 내비게이션이 탭으로 바뀐다. 기본 글자 크기의 격자와 사이드바는 유지한다. `PocketScreenshotTests/testCaptureAccessibleLibrary`가 추가·설정의 접근 가능 여부와 추가 메뉴를 검사하며, QA 이미지는 스토어 세트에서 제외한다.

검증 자료는 `.build/design-system/`에 있다.

| 검사 | 결과 |
| --- | --- |
| 플랫폼 빌드 | `ios-build.log`, `mac-final-build.log` 통과. 접근성 보완 뒤의 iOS 코드는 아래 UI 테스트에서 다시 빌드 |
| iPhone 기능 흐름 | `iphone-flows.xcresult`: 개요, 설정 외관, 화면/읽기 범위, 데모/미리보기, 기사 빈 상태, 편집 미리보기 6개 통과 |
| Mac QA | `mac-qa.xcresult`: 어두운 화면, 사용자 흐름 렌더, 같은 창 읽기 복귀 3개 통과. 왼쪽 정렬 보완 뒤 `mac-dark-final.xcresult` 1개 통과 |
| 최종 접근성 레이아웃 | `iphone-accessible-layout.xcresult`, `ipad-accessible-layout.xcresult`: 가장 큰 접근성 글자 크기에서 각 1개 통과. 캡처로 책 제목 전체 표시와 iPad 탭 배치 확인 |
| 스토어 캡처 | `screenshots.log`: 기본 글자 크기의 iPhone 6장, iPad 7장, Mac 6장 생성 및 패키지 검증 통과. 밝은/어두운 화면의 여백·정렬을 확인 |
| 실제 실행 창 | Apple Development로 서명된 설치 앱을 교체하고 빌드와 실행 파일 해시 일치 확인. 중복 제목 제거, 창 조작 영역, 추가 메뉴와 저장된 읽기 편집 진입 확인 |

오프스크린 Mac 캡처는 native 제목 표시줄을 포함하지 않으므로 실제 실행 창에서도 별도로 확인했다. 이 작업은 앱 UI 정비이며 새로운 기기 연결·전송 계약이나 실제 하드웨어 동작을 검증한 것은 아니다.


## 2026-10-09 My Reader 내비게이션 단순화

Library와 My Reader를 주 목적지로 두고, My Reader 첫 화면에 기기 상태·저장된 편집·전송 작업·관측한 파일을 합쳤다. Reader settings는 기기 카드에서, Manage reader는 Reader options 메뉴에서 연다. Reader settings 안에서 Home screen, Sleep screen, Reading preferences를 선택한다. 독립적인 Reading 메뉴를 제거해 Library의 앱 독서와 기기 설정을 구분했다.

연결되지 않아도 같은 경로로 설정을 편집하며 연결은 적용 단계에서 연다. 같은 창에서 돌아오면 선택과 초안을 유지한다. Continue editing은 미적용 변경이 있는 마지막 범위를 우선하며, 그 범위가 깨끗하면 실제 변경이 남은 범위를 연다. 원본 편집기·선택한 책 작업의 복귀와 명시적 적용 경계는 유지한다.

첫 접근성 캡처에서 보관함 추가 버튼의 글자가 잘게 줄바꿈되고 고정 미리보기/적용 바가 편집 영역을 가렸다. 보관함 제목/버튼은 폭에 따라 세로로 배치하고, 접근성 크기의 설정은 전체 스크롤과 Show preview를 사용하도록 보완했다. 방향 선택도 글자가 커지는 메뉴로 전환했다. 데모에서 큰 글자로 설정 변경·미리보기·취소를 실제로 수행하는 검사를 추가했다.

검증 근거는 `.build/reader-ia/`에 보관한다.

| 검사 | 결과와 근거 |
| --- | --- |
| 핵심 단위/오프라인 UI | `iphone-core-v2.xcresult`: 프로필 병합·설정 전송·작업 소유 단위 21개와 UI 4개 통과 |
| 편집·복귀 회귀 | `iphone-flows.xcresult`: 공통 원본, 부모 범위, 연결 복귀, 책 작업, 미리보기 등 UI 7개 통과 |
| 초기 Mac QA | `mac-qa.xcresult`: 어두운 화면과 사용자 상태 렌더 2개 통과 |
| 최종 iPhone 회귀 | `iphone-final.xcresult`: 단위 32개, 미연결 탐색·범위/초안 복귀 UI 2개 통과. Sleep 초안 우선 복귀와 XTC 안내 문구 수정 포함 |
| 최종 iPad 회귀 | `ipad-final.xcresult`: 같은 미연결/복귀 UI 2개 통과, iPad Pro 13 (M5), iOS 26.5 |
| 캡처·접근성 | `capture-iphone.xcresult`, `capture-ipad.xcresult`: 각각 캡처 UI 4개 통과. 큰 글자에서 편집/방향 변경/확대 미리보기/취소 검증 및 이미지 확인 |
| 최종 Mac | `mac-shipping-final.log` 서명된 샌드박스 빌드 통과. `capture-mac.xcresult` 10개 통과, 외부 EPUB 샘플이 필요한 1개 건너뜀. 밝은/어두운 설정 및 데모 보관함 이미지 확인 |
| 스토어 자료 | `screenshots-final.log`: 스크립트 전체 통과, iPhone 6장·iPad 7장·Mac 6장. `validate_app_store.sh`, 문서 로컬 링크, `git diff --check` 통과 |
| 실행 앱·저장소 | 설치 앱과 최종 빌드 실행 파일의 SHA-256 일치, 코드 서명 검사 통과. 실제 Mac 창의 설정 범위/관리 메뉴/뒤로 가기 확인, My Reader에서 실행 중. `main`과 기본 checkout만 있으며 stash 없음 |


여러 기기의 등록 목록이나 동시 연결을 구현한 것은 아니다. 기존 단일 활성 Wi-Fi 세션과 Bluetooth 기억 기기 계약을 유지하며, 물리 기기·무선·SD 전송과 App Store 제출은 이 변경의 검증 범위에 포함하지 않는다.
