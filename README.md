# VtuberTranslate JP→KO

> 유튜브 등에서 송출되는 일본어권 방송을 **실시간으로 듣고 한국어로 번역**해, 화면 위 반투명 자막바로 보여주는 macOS 앱.

특정 앱(브라우저 등)의 시스템 오디오를 캡처해 **온디바이스 음성인식 → 번역 → 반말 자막**을 거쳐 거의 실시간으로 자막을 띄웁니다. 기본 설정은 **완전 온디바이스**라 계정·인터넷·API 키가 필요 없습니다. (원하면 DeepL을 선택적으로 붙일 수 있음 — 아래 [프라이버시](#프라이버시--보안) 참고.)

## 기능

- 🎧 **앱별 오디오 캡처** — ScreenCaptureKit으로 선택한 앱(예: 브라우저)의 소리만 캡처
- 🎙️ **고정확 일본어 음성인식** — [FluidAudio](https://github.com/FluidInference/FluidAudio) Parakeet-TDT(일본어, CoreML/ANE 온디바이스)
- 🤫 **환각 차단(VAD)** — Silero 음성 활동 감지로 BGM·게임소리·무음 구간의 헛인식을 걸러냄
- ⚡ **실시간 스트리밍 자막** — 확정된 부분은 흰색으로 잠그고, 진행 중인 부분은 회색 꼬리로 흘려 보여주는 점진 표시. 확정 자막은 **문장 단위**로 번역해 품질↑
- 🈁 **온디바이스 번역** — Apple Translation 프레임워크(일→한). 오프라인·무료·키 불필요
- 🗣️ **대화체(반말) 변환** — 방송 말투에 맞춰 격식체를 반말로
- 🎮 **게임 용어·슬랭 사전** — `神回`→띵방, `無理ゲー`→클리어 불가 난이도, `わかりみ`→공감 등 검증된 치환(`Resources/vtuber_slang.json`)
- 📛 **멤버 이름 보정(선택)** — 홀로라이브 JP·브이스포 JP 멤버 이름/별명을 한국어 정식 표기로 (`Resources/vtuber_glossary.json`)
- 🌐 **고품질 번역(선택)** — DeepL API를 붙이면 확정 자막만 DeepL로 번역(진행 중은 온디바이스). 기본 꺼짐, 키 없으면 자동으로 온디바이스 폴백
- 🪟 **반투명 오버레이** — 모든 스페이스/전체화면 위에 떠 있는 비활성 패널

## 프라이버시 & 보안

- **기본값은 100% 온디바이스입니다.** 음성인식·번역 모두 당신의 Mac 안에서만 처리되며, 계정·로그인·텔레메트리·분석이 **전혀 없습니다.** 캡처한 오디오나 자막이 외부로 나가지 않습니다.
- **모델 다운로드:** 첫 실행 시 음성인식/VAD CoreML 모델을 HuggingFace에서, 번역 모델을 Apple에서 1회 내려받습니다(공개 모델 파일만 받음 — 당신의 데이터는 전송되지 않음).
- **DeepL은 선택이며 기본 꺼짐입니다.** 직접 켜고 본인 DeepL 키를 입력했을 때만, **확정(완성 문장) 자막 텍스트**가 HTTPS로 DeepL API(`api.deepl.com`)에 번역 요청으로 전송됩니다. 끄거나 키가 없거나 오프라인이면 온디바이스로 폴백합니다.
- **키 저장:** DeepL 키는 당신 Mac의 로컬 설정(UserDefaults)에만 저장됩니다. **이 저장소에는 어떤 키·비밀·개인정보도 포함돼 있지 않습니다.**
- **네트워크:** 위 모델 다운로드와 (선택 시) DeepL 외에 어떤 서버에도 접속하지 않습니다.

## ⚠️ 알려진 한계 (향후 업데이트 예정)

현재 버전의 한계입니다. 차차 개선할 예정이에요:

- **화자 분리(누가 말하는지 구분) 미지원** — 콜라보처럼 여러 명이 말하는 방송에서도 화자를 구분하지 않고 한 줄로 이어서 보여줍니다.
- **게임 내 음성이 섞일 수 있음** — 게임 캐릭터·NPC 대사 등 *사람 목소리 같은 소리*는 방송인 목소리와 함께 자막으로 잡힐 수 있습니다.
- **잡음이 가끔 자막으로 잡힐 수 있음** — 음성 활동 감지(VAD)로 대부분의 BGM·잡음은 걸러내지만, 목소리와 비슷한 소리는 드물게 헛인식되어 자막으로 뜰 수 있습니다.

## 설치 & 사용 (일반 사용자)

> ⚠️ **먼저 확인:** 이 앱은 **macOS 26 (Tahoe) 이상 + Apple Silicon(M1 이후) Mac**에서만 동작합니다. 그 이하 버전이나 인텔 Mac에서는 실행되지 않습니다.

1. **다운로드 & 압축 해제** — [Releases](../../releases)에서 최신 `VtuberTranslate-JP-KO.zip`을 받아 더블클릭으로 압축을 풉니다. `VtuberTranslate JP→KO` 앱이 나옵니다(보통 **다운로드** 폴더). 원하면 **응용 프로그램** 폴더로 옮겨도 됩니다.

2. **첫 실행 — 잠금 해제 (중요, 한 번만)** — 무료 개인 개발 앱이라 **Apple 공증(notarization)이 없어** 그냥 더블클릭하면 macOS가 "확인되지 않은 개발자" 또는 "손상되었다"며 막습니다. 아래로 풀어주세요:
   - **터미널**(응용 프로그램 → 유틸리티)을 열고, 아래를 입력하되 **맨 끝에 띄어쓰기 한 칸**을 둡니다(아직 Enter 누르지 마세요):
     ```bash
     xattr -dr com.apple.quarantine 
     ```
   - 이어서 **다운로드한 앱을 터미널 창 안으로 드래그**하면 앱 경로가 자동으로 채워집니다. → **Enter**.
   - 앱이 **다운로드 폴더에 있든 응용 프로그램에 있든** 상관없이 동작합니다.
   - 이제 앱을 더블클릭하면 열립니다. *(이후로는 그냥 열려요.)*

3. **화면 기록 권한** — 앱에서 음원 앱을 고르고 **시작**을 누르면 *화면 기록* 권한을 요청합니다. **허용**한 뒤, 안내가 뜨면 앱을 한 번 재시작하세요. (소리만 캡처하지만 macOS가 시스템 오디오 캡처에 이 권한을 요구합니다 — 영상은 저장·전송되지 않습니다.)

4. **모델 다운로드 (처음 1회만)** — 첫 사용 시 음성인식 모델(수백 MB)을 자동으로 내려받습니다. **인터넷 필요**, 1~2분 정도. 이후엔 오프라인으로도 동작합니다.

5. **사용**
   - 위쪽 **음원 앱**에서 방송을 보는 앱(예: 크롬/사파리)을 선택
   - **시작** 클릭 → 방송을 틀면 화면 위 자막바에 한국어 자막이 흘러나옵니다
   - 자막바는 드래그로 위치를 옮길 수 있어요

6. **설정 (선택)**
   - **멤버 이름 보정** — 홀로라이브/브이스포 멤버 이름을 한국어 정식 표기로(켜면 이름용 모델을 추가로 받음)
   - **DeepL 고품질 번역** — 본인 DeepL 키가 있으면 입력 시 확정 자막을 더 자연스럽게 번역. 없으면 그냥 두면 온디바이스로 동작

**요약 — 일반 사용자가 할 일:** ① zip 받기 → ② 터미널 한 줄로 잠금 풀기 → ③ 화면 기록 허용 → ④ (자동) 모델 다운로드 → ⑤ 앱 선택 후 시작. 끝.

## 요구 사항

- macOS 26 (Tahoe) 이상 · Apple Silicon
- (소스 빌드 시) Xcode 26 이상(Swift 6.3+), [XcodeGen](https://github.com/yonsm/XcodeGen) — `brew install xcodegen`
- 음성인식은 [FluidAudio](https://github.com/FluidInference/FluidAudio)(SwiftPM, MIT)로 동작하며 첫 사용 시 CoreML 모델(수백 MB)을 자동 다운로드. "멤버 이름 보정"을 켜면 CTC 모델을 추가로 받음.

> 신규 번역 프레임워크가 macOS 26 전용이라 그 이하에서는 동작하지 않습니다.

## 개발자: 소스에서 빌드

```bash
# 1) 로컬 서명 인증서 생성 (화면 기록 권한이 매번 다시 뜨는 걸 방지)
./scripts/create-signing-cert.sh

# 2) Xcode 프로젝트 생성 (project.yml → .xcodeproj)
xcodegen generate

# 3) 빌드
xcodebuild -project VtuberTranslate.xcodeproj -scheme VtuberTranslate \
  -configuration Debug -destination 'platform=macOS' build

# 4) 실행 (또는 Xcode에서 ⌘R)
open ~/Library/Developer/Xcode/DerivedData/VtuberTranslate-*/Build/Products/Debug/VtuberTranslate.app
```

자체 서명 인증서가 싫다면 `project.yml`의 `CODE_SIGN_IDENTITY`를 `"-"`(ad-hoc)로 바꿔도 빌드는 됩니다. 단, macOS가 실행 때마다 화면 기록 권한을 다시 물을 수 있습니다.

### 권한

처음 **시작**을 누르면 **화면 기록** 권한을 묻습니다 — ScreenCaptureKit 오디오 캡처에 필요 (허용 후 재시작이 필요할 수 있음).

## 아키텍처

```
ScreenCaptureKit ─▶ Silero VAD ─▶ Parakeet-TDT(STT) ─▶ 글로서리/슬랭 ─▶ 번역 ─▶ 반투명 오버레이
   (앱 오디오)       (발화 게이트)     (온디바이스 CoreML)     (치환)     (온디바이스 / 선택 DeepL)  (NSPanel)
```

| 레이어 | 파일 |
|---|---|
| 오디오 캡처 | `Sources/Audio/SystemAudioCapture.swift` |
| 음성 인식 (프로토콜) | `Sources/Speech/SpeechRecognizing.swift` |
| 음성 인식 (Parakeet+VAD) | `Sources/Speech/FluidParakeetJaRecognizer.swift` |
| 번역 (프로토콜) | `Sources/Translation/Translating.swift` |
| 번역 (Apple 온디바이스) | `Sources/Translation/AppleTranslator.swift` |
| 번역 (DeepL, 선택) | `Sources/Translation/DeepLTranslator.swift` |
| 글로서리 / 슬랭 / 반말 변환 | `Sources/Pipeline/GlossaryCorrector.swift`, `ConversationalStyle.swift` |
| 오케스트레이션 | `Sources/Pipeline/SubtitlePipeline.swift` |
| 오버레이 UI | `Sources/UI/OverlayPanel.swift`, `SubtitleView.swift` |

음성인식(`SpeechRecognizing`)·번역(`Translating`)이 프로토콜로 추상화돼 있어 엔진을 교체·확장할 수 있습니다.

## 사전(글로서리/슬랭) 커스터마이즈

- **멤버 이름:** `Resources/vtuber_glossary.json`에 방송인 이름/별명을 추가. "멤버 이름 보정"을 켜면 번역 직전 일본어 표기가 한국어 정식 표기로 치환됩니다.
- **게임 용어·슬랭:** `Resources/vtuber_slang.json`에 `{ "jp": ..., "ko": ... }`로 추가(항상 적용). 흔한 단어의 부분문자열은 일상 문장을 깨뜨리니 피하세요.

```json
{ "jp": "兎田ぺこら", "ko": "우사다 페코라", "aliases_jp": ["ぺこら"], "kind": "name", "group": "Hololive JP" }
```

## 로드맵 / 기술 노트

받아쓰기 속도·정확도 연구 노트는 [`docs/ASR_RESEARCH.md`](docs/ASR_RESEARCH.md) 참고.

## 라이선스

[MIT](LICENSE)
