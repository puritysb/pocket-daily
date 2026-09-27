# 현재 통합 상태

기준: 2026-09-27. 이 세션이 앱/펌웨어 정리를 전담하고 다른 세션은 편집·커밋·기기 작업을 중단했다.
**로컬 통합 검사는 통과했지만, X3 긴 EPUB 읽기에서 멈춤이 보고돼 실기기 수용은 실패/조사 중이다.**
푸시·태그·GitHub 릴리스·스토어 제출은 하지 않았다.

## 제품 흐름과 구현

- 브라우저 공유 → 앱 Articles에 보관/검토/수정 → EPUB 준비 → 명시적 SD 전송 →
  리더 Articles에서 이어 읽기/읽음 표시/사용자 삭제. [ARTICLES.md](ARTICLES.md).
- 작성한 글과 일반 콘텐츠는 SD 파일이다. 콘텐츠와 펌웨어 전송·취소·정리를 분리했다.
  임시 파일 정리 실패 시 재시도할 대기열을 보존한다. [TRANSFERS.md](TRANSFERS.md).
- 펌웨어는 실행당 한 번 GitHub 메타데이터 확인, 최신 버전/배포일과 업데이트 동작만 표시한다.
  로컬 BIN 선택은 제거했다. 전송 완료와 설치를 구분하며 기기 설치 확인은 유지한다.
- Sync Home/Sleep 표시 구현 및 사용자 화면 확인 완료. Sync의 책 표지는 의도된 임시 표지다.
  세부 이력: [EPUB_INTEGRATION_HANDOFF.md](EPUB_INTEGRATION_HANDOFF.md).

## 지금 가장 먼저 해결할 문제: EPUB 읽기

현재 X3는 `1.7.0-dev-main-bca376e7-wa4be8509`다. 새 Articles/transferControl 구현은 미설치다.
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
물리 방향은 저장 readback과 별도로 확인한다.

## 검증과 한계

- 앱 최종 전체 단위 **335/335** 통과. 렌더러 교체 후 관련 **10/10**, iOS 시험 빌드와 macOS 빌드 통과.
- 펌웨어 전체 host **441/441**, route **11/11**, SDK 패치 **3/3**, 새 CI adapter **1/1** 통과.
  default 빌드 오류·경고 0, pinned cppcheck 2.11 직접 빌드 후 strict 검사 결함 0.
- GitHub 최근 확인 run `36226499475`는 build 성공, native tests/format/cppcheck 실패였다.
  `<cmath>`, host 포맷, native cppcheck adapter로 로컬 수정했다. 원격 CI 재실행은 푸시 후 필요하다.
- 최신 UI 스크린샷 11장과 스토어 패키지 검사 통과. iPhone UI 13개 통과.
  iPad는 공유 확장 초기 입력 대기 1회 실패 후 같은 코드 재시험 통과. 간헐 실패는 미해결이다.
  순차 시험 중 새 SpringBoard crash 보고서는 없었으며, 이전 crash를 해결했다고 주장하지 않는다.
- X4/direct, 새 Articles 삭제·전송 취소의 물리 수용, Sync CJK 헤더의 폰트/heap,
  렌더러 내부 임시 할당의 저메모리 동작은 아직 미검증이다.

## Git과 작업 환경

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
