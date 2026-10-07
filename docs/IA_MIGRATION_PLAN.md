# Pocket Daily IA 전환 계획

작성일: 2026-10-05. 상태: 전환 설계 확정. 아래는 전환 시작 시의 근거와 계획이다. 상세 결정은 [IA 구현 설계](IA_FINAL_DESIGN.md), 수행 결과는 [구현 보고](IA_IMPLEMENTATION_REPORT.md)를 기준으로 한다.

[제품 IA](PRODUCT_IA.md)와 [화면 및 작업 명세](PRODUCT_UX_SPEC.md)를 기존 SwiftUI 앱에 단계적으로 적용한다. 독서·저장·통신 계약을 유지하면서 사용자가 시작한 작업을 끝까지 이어 주는 구조를 만든다. 이 문서는 과거 펌웨어 및 스튜디오 개발 이력인 `IMPLEMENTATION_PLAN.md`와 구별되는 새 IA 전환 계획이다.

## 전환 시작 시 코드에서 확인한 근거

2026-10-05 작업 트리의 소스와 테스트를 읽어 작성했다. 기존 미커밋 UI·연결 변경을 포함한 상태이며, 이번 명세 작업에서 앱 빌드나 실기기 테스트를 새로 수행한 것은 아니다.

| 새 IA의 책임 | 기존 코드 | 활용 방침과 필요한 차이 |
| --- | --- | --- |
| 서재와 콘텐츠 원본 | [BookLibrary](../Sources/Library/BookLibrary.swift), [LibraryModel](../Sources/Library/LibraryModel.swift) | 저장 형식, 책 ID, 동일 바이트 보관 유지. 화면 이동 책임을 넣지 않음 |
| 앱 읽기와 외관 | [ReaderSession](../Sources/Reading/ReaderSession.swift), [ReaderAppearance](../Sources/Reading/ReaderAppearance.swift) | 기존 엔진과 전체 책 기본값 활용. 기기 설정과 데이터 모델을 합치지 않음 |
| 이어 읽기 | [ReadingSync](../Sources/Sync/ReadingSync.swift), [ReaderBluetoothLink](../Sources/Sync/ReaderBluetoothLink.swift) | 위치 교환과 이동 제안 재사용. 파일 전송 완료와 분리해 표시 |
| 연결과 기기 상태 | [DeviceSnapshot](../Sources/Core/DeviceSnapshot.swift), [NearbySyncController](../Sources/NearbySyncController.swift) | 지원 기능 판단과 연결 구현 활용. 내비게이션 항목은 기능 모델에서 분리 |
| 작업 실행과 취소 | [ReaderWorkLane](../Sources/Core/DeviceCore.swift), [PocketModel](../Sources/PocketModel.swift) | 기존 작업 소유권과 종료 대기 유지. 새 흐름에서 별도 통신 실행 큐를 만들지 않음 |
| 파일 전송 | [CrossPointClient](../Sources/CrossPointClient.swift), PocketModel의 준비·게시·복구 | 전송 계약 유지. 종류별 전체 큐 실행에 선택한 ID 집합 실행 경로 추가 |
| 기기 보관함 | [ReaderShelf](../Sources/Library/ReaderShelf.swift), [ReaderFileDownload](../Sources/Library/ReaderFileDownload.swift) | 목록과 서재 매칭 활용. 파일명·크기 매칭을 검증된 바이트 일치로 과장하지 않음 |
| 기기 편집 초안 | [ProfileMerge와 ProfileEditStore](../Sources/Studio/ProfileMerge.swift) | 변경 범위, 저장, 병합 유지. 새 화면 수명과 대상 기기 확인에 맞게 연결 |
| 편집 UI와 미리보기 | [ProfileStudioView](../Sources/Studio/ProfileStudioView.swift), [LayoutPreviewModel](../Sources/Studio/LayoutPreviewModel.swift), [HostRendererBridge](../Sources/Studio/HostRendererBridge.swift) | 렌더링 재사용. 화면별 조정 항목과 공통 적용 영역 분리 |
| 카드 | [ContentDraftStore](../Sources/Studio/ContentDraftStore.swift), [ContentDeployment](../Sources/Studio/ContentDeployment.swift) | 초안 복구·세대 충돌·배포 결과 유지. 공통 내용 편집의 사용 위치 안내 추가 |
| 날씨와 일정 | [GlanceSettings](../Sources/Glance/GlanceSettings.swift), [CalendarSource](../Sources/Glance/CalendarSource.swift) | 원본 데이터와 캐시 활용. 특정 캘린더 선택은 신규 저장·조회 동작 필요 |
| 펌웨어 | [FirmwareImageValidator](../Sources/FirmwareImageValidator.swift), [FirmwareGuidance](../Sources/Core/FirmwareGuidance.swift), PocketModel | 검증·명시적 전달·설치 후 확인 활용. 내 리더 관리 흐름으로 재배치 |
| 앱의 화면 구성 | [ContentView](../Sources/ContentView.swift), [LibraryView](../Sources/Library/LibraryView.swift), [AppSettingsView](../Sources/AppSettingsView.swift) | 새 IA에 맞춰 전환. 기존 저장 키와 독서 진입 동작 보존 |

전환 시작 시 `LibraryView.prepare`는 준비 후 Files로 이동하거나 `sendPreparedFiles(kind: .content)`를 호출한다. 이 함수는 해당 종류의 대기 파일 전체를 순회한다. 따라서 새 화면에서 ‘이 책 보내기’라고 표시하는 것만으로는 명세를 충족하지 못한다.

전환 시작 시 `DeviceSnapshot`에는 기능 정보와 함께 `DeviceSection` 및 가족별 메뉴 목록이 들어 있다. 메뉴 재편은 탐색 경로 모델의 책임으로 옮기고, 지원 기능과 기기 상태는 기존 정보를 기반으로 표시한다. `DeviceMirror`, `DeviceSnapshot`, `PocketModel` 외에 독립적인 연결 상태 저장소를 추가하지 않는다.

전환 시작 시 `ProfileEditorState`는 편집 View 파일 안에 있지만 초안과 범위별 병합을 담당한다. 상태를 별도 파일로 추출하더라도 동작과 저장 형식을 먼저 유지한다. 당시 초안 스냅샷에는 기기 ID가 없으므로 기기에 묶인 초안과 범용 오프라인 초안을 어떻게 구별할지 편집 단계에서 보완해야 한다.

## 설계할 최소한의 경계

새 기능은 세 책임으로 나눈다. 타입 이름은 구현 시 조정할 수 있지만 책임은 유지한다.

| 책임 | 보유하는 정보 | 보유하지 않는 정보 |
| --- | --- | --- |
| 화면 이동 | 목적지, 출발한 서재 상태, 어떤 작업을 보고 있는지 | Bluetooth·HTTP 상태의 별도 사본 |
| 사용자 작업 | 목적, 선택한 콘텐츠, 대상, 단계, 책별 결과 | 별도의 업로드 엔진이나 독립 연결 세션 |
| 기존 실행 계층 | 연결, 기기 식별, 작업 직렬화, 게시·복구·설치 확인 | 어떤 탭으로 돌아갈지와 화면 문구 배치 |

`PocketModel`은 초기에 기존 실행 계층의 창구로 유지한다. 새 UI가 필요한 좁은 명령과 결과를 먼저 제공하고, 실제 변경 과정에서 책임이 분명해진 부분부터 추출한다. 전체 파일 재배치나 패키지 분할을 첫 단계의 선행 조건으로 만들지 않는다.

작업 진행 정보는 앱이 소유하고 창은 작업 ID를 표시한다. 같은 작업을 여러 번 열어도 전송을 다시 만들지 않는다. macOS의 창별 복귀 경로는 창에 두고, 창이 사라져도 진행 중 작업을 새로 찾을 수 있게 한다. 새 창 자동 생성이나 다른 데스크탑 이동은 하지 않는다.

## 책 보내기 작업의 데이터와 명령

| 값 | 역할 |
| --- | --- |
| 작업 ID | 반복 클릭, 재표시, 재실행 복구에서 같은 작업 식별 |
| 선택한 책 ID 목록 | 사용자 선택의 고정된 범위 |
| 준비된 전송 ID 목록 | 실제 전송 항목과 정확히 연결. 준비 API가 결과로 반환 |
| 대상 기기 | 알려진 기기 ID와 표시 이름. 모르는 신원은 모른다고 유지 |
| 현재 단계 | 준비·연결 필요·연결 중·준비 완료·전송·확인·중지·부분 완료·완료 |
| 책별 결과 | 미전송, 실행 중, 확인 필요, 저장 확인, 실패와 복구 이유 |
| 변경 시점과 저장 버전 | 재시작 복구와 저장 형식 이행 |

작업 기록에는 비밀번호나 페어링 비밀을 넣지 않는다. 원본 책 바이트와 상세 전송 상태는 기존 저장소가 소유한다. 작업 기록은 해당 ID와 사용자에게 필요한 결과를 참조한다.

필요한 명령은 작업 생성, 선택한 책 준비, 연결 요청, 선택한 ID 전송, 중지, 결과 확인, 남은 항목 재시도, 작업 버리기다. 준비가 일부 실패하면 성공한 준비 항목을 보존하고 사용자 선택 없이 전송하지 않는다.

기존 ‘종류별 모두 보내기’는 명시적인 일괄 보내기 용도로만 남긴다. 새 책 보내기는 불변의 ID 목록을 전달하며 실행 중 큐에 추가된 항목을 포함하지 않는다. 중지·재시도·삭제도 같은 ID 범위를 사용해야 한다. 대상 기기 확인, 게시 결과 조회, 임시 파일 정리를 우회하는 경로를 추가하지 않는다.

완료된 준비 파일은 기존 구현에서 정리되므로 작업 기록은 확인된 완료 결과를 독립적으로 남겨야 한다. 기록과 전송 저장소 사이에서 앱이 종료될 수 있으므로, 게시 확인 전후의 기록 순서를 정의하고 불일치 복구를 테스트한다. 확실한 결과가 없으면 확인 필요 상태로 복구하며 성공으로 추정하지 않는다.

기존 준비 파일에는 작업 ID가 없을 수 있다. 이를 새로 선택한 책 작업에 자동 합치지 않고 ‘기존 준비 항목’으로 유지한다. 화면 초안, 카드 초안, 책 ID, 읽던 위치, 페어링은 UI 전환을 위해 초기화하지 않는다.

## 구현 단계와 종료 조건

### 단계 1 선택한 책 보내기

구현 범위는 작업 모델, 준비 결과의 ID 반환, 선택한 ID 전송·중지·복구 경로, 서재 진입점과 작업 시트다. 기존 연결 화면의 동작을 재사용해 시트 안에서 연결한다. 전송 진행은 시트를 닫아도 다시 찾을 수 있게 한다.

종료 조건은 [화면 명세](PRODUCT_UX_SPEC.md)의 B01부터 B15까지다. 복수 선택 UI가 없는 첫 구현에서는 단일 책 흐름을 실제 UI로 검증하고, 복수 항목의 부분 완료는 실행 계층에서 검증해 그 차이를 보고한다. 화면 전체 개편 전에 이 흐름이 앱에서 끝까지 동작해야 한다.

### 단계 2 내 리더와 탐색 구조

내 리더 첫 화면을 만들고 기기 보관함·화면 꾸미기·읽기 방식·기기 관리를 연결한다. 좁은 화면과 넓은 화면은 같은 목적지 모델을 사용한다. 단계 1의 작업 시트는 같은 진입점과 실행 계층을 유지한다.

미등록·미연결·위치 교환만 가능·파일 전송 가능·작업 중·실패 상태를 표로 렌더링하고 검증한다. 현재 파일 보관함의 관측 시점을 표시하며 기기 미연결 상태를 모든 기능의 사용 불가로 취급하지 않는다. 새 진입점이 완성된 목적지의 이전 중복 메뉴를 제거한다.

### 단계 3 화면 꾸미기와 읽기 방식

기존 초안 저장과 병합을 유지하면서 화면별 컨트롤과 공통 미리보기·적용 영역을 분리한다. 바로 조절할 수 있는 값은 해당 화면 안에서 조정한다. 화면 이동, 재연결, 앱 재실행 후 초안을 유지하고 작업 범위 밖의 값을 보내지 않는다.

Home·Sleep·Reading 각각의 필드 소속, 기기 식별과 초안 이행, 카드 및 날씨·일정의 적용 범위를 먼저 확정한다. 읽기 방향·버튼 매핑·본문 옵션은 X3/X4 및 펌웨어 계약과 대조한 기능 표를 추가한다. 지원 범위 확인이 없는 컨트롤을 새로 활성화하지 않는다.

### 단계 4 기기 관리와 전체 정리

업데이트 진행과 문제 해결을 새 기기 관리 화면에 연결하고, 앱 설정에는 앱 외관·이어 읽기 정책·권한·도움말을 남긴다. 기존 전송과 설치 안전 조건은 유지한다. 날씨 표시와 공급자 표기는 해당 요구사항을 확인한 뒤 조정한다.

완성된 흐름의 중복 상태와 오래된 화면을 제거하고 스크린샷·지원 문서를 갱신한다. 장기간 두 UI를 함께 유지하거나 같은 설정을 두 저장소에 독립적으로 쓰지 않는다.

## 검증 계획

기존 테스트는 행동을 보존하는 회귀 기준으로 사용한다. 메뉴 이름과 이동 방식이 바뀌는 UI 테스트는 새 과업에 맞게 수정하되, 기존 검증을 단순히 삭제하지 않는다.

| 변경 | 기존 검증 활용 | 새 검증 |
| --- | --- | --- |
| 선택한 ID 전송 | [TransferSeparationTests](../Tests/TransferSeparationTests.swift), [DeviceCoreTests](../Tests/DeviceCoreTests.swift) | 무관한 책·펌웨어 제외, 고정된 배치, 부분 완료, 취소 후 소유권 |
| 작업 복구 | 기존 게시 확인·준비 파일 복구 테스트 | 작업 저장 실패·재실행·완료 파일 정리 사이의 불일치 |
| 연결과 작업 시트 | [DeviceSnapshotTests](../Tests/DeviceSnapshotTests.swift), [PocketFlowTests](../UITests/PocketFlowTests.swift) | 연결 후 명시적 보내기, 선택·출발점 유지, 시트 재표시 |
| 편집 화면 전환 | [ProfileMergeTests](../Tests/ProfileMergeTests.swift), [ReaderLayoutSendTests](../Tests/ReaderLayoutSendTests.swift) | 편집 대상별 적용, 기기 변경, 저장한 초안 이행 |
| 기기 보관함 | [ReaderShelfTests](../Tests/ReaderShelfTests.swift) | 관측 시점, 대상 전환, 지원되지 않는 가져오기 안내 |
| 독서와 이어 읽기 영향 | [ReadingSyncTests](../Tests/ReadingSyncTests.swift), [ReaderEngineTests](../Tests/ReaderEngineTests.swift) | 동선 변경 후 원래 책과 위치 유지 |

Swift 변경은 관련 테스트와 양 플랫폼 빌드로 검증한다. 소스 파일 추가·이동 시 XcodeGen으로 프로젝트를 재생성한다. UI 변경은 실제 앱 스크린샷을 다시 만들고 패키지 검증을 수행한다. 읽기 위치 계약을 수정한다면 펌웨어 XPointer 교차 검사도 수행한다.

실제 Bluetooth 페어링, 직접 Wi-Fi 연결, 같은 네트워크 전송, SD 복사, 기기 설치 확인은 별도의 하드웨어 수용 항목이다. 이 계획의 작성이나 모의 응답 테스트 통과를 실기기 검증으로 표시하지 않는다.

## 범위와 완료 보고

이 전환에서는 계정·클라우드 백엔드·전체 책 파일의 자동 양방향 동기화·기기 라이브 화면 캡처를 추가하지 않는다. 프로토콜 변경이 필요한 항목은 앱 UI 개선과 구별해 펌웨어 변경 및 양쪽 검증을 함께 계획한다.

각 단계는 바뀐 사용자 행동, 유지한 기반, 테스트 증거, 미완료 하드웨어 검증을 보고한다. 제품 IA 전체 구현 완료와 첫 시나리오 완료를 구분한다. 2026-10-05 사용자 지시에 따라 전송 실행·셸과 작업 UI·편집과 공통 내용을 Sol 에이전트 세 개가 구현했고, 통합 및 검증 결과는 [구현 보고](IA_IMPLEMENTATION_REPORT.md)에 기록한다.
