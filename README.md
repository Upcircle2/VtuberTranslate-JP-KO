# VtuberTranslate

> 유튜브 등에서 송출되는 일본/영어권 방송을 **실시간으로 듣고 번역**해, 화면 위 반투명 자막바로 보여주는 macOS 앱.

특정 앱(브라우저 등)의 시스템 오디오를 캡처해 **온디바이스 음성인식 → 온디바이스 번역**을 거쳐 거의 실시간으로 자막을 띄웁니다. 전부 Apple 공식 프레임워크 기반이라 API 키·인터넷·계정이 필요 없습니다.

## 기능

- 🎧 **앱별 오디오 캡처** — ScreenCaptureKit으로 선택한 앱(예: 브라우저)의 소리만 캡처
- 🎙️ **음성인식 2종 엔진** — Apple SpeechAnalyzer(기본) / [FluidAudio](https://github.com/FluidInference/FluidAudio) Parakeet-ja(정확·일본어, +멤버 이름 부스팅). 설정에서 전환. 전부 온디바이스
- ⚡ **실시간 스트리밍 자막** — 확정된 부분은 흰색으로 잠그고, 진행 중인 부분은 회색 꼬리로 흘려 보여주는 점진 표시
- 🈁 **온디바이스 번역** — Apple Translation 프레임워크(일→한 등). 오프라인·무료·API키 불필요
- 🗣️ **대화체(반말) 변환** — 방송 말투에 맞춰 격식체를 반말로
- 📛 **VTuber 고유명사 사전** — 홀로라이브 JP·브이스포 JP 멤버 이름/별명을 정확히 출력 (`Resources/vtuber_glossary.json`)
- 🪟 **반투명 오버레이** — 모든 스페이스/전체화면 위에 떠 있는 비활성 패널

## 요구 사항

- macOS 26 (Tahoe) 이상
- Xcode 26 이상 (Swift 6.3+)
- Apple Silicon
- [XcodeGen](https://github.com/yonsm/XcodeGen) — `brew install xcodegen`
- (선택) **Parakeet-ja 음성인식 엔진**은 [FluidAudio](https://github.com/FluidInference/FluidAudio)(SwiftPM, MIT)를 통해 동작하며, 첫 사용 시 CoreML 모델(수백 MB)을 HuggingFace에서 자동 다운로드함. "멤버 이름 부스팅"을 켜면 CTC 모델을 추가로 받음. Apple 엔진만 쓰면 불필요.

> 신규 음성인식(SpeechAnalyzer / SpeechTranscriber)·번역 프레임워크가 macOS 26 전용이라 그 이하에서는 동작하지 않습니다.

## 빌드 & 실행

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

자체 서명 인증서가 싫다면 `project.yml`의 `CODE_SIGN_IDENTITY`를 `"-"`(ad-hoc)로 바꿔도 빌드는 됩니다. 단, 이 경우 macOS가 실행 때마다 화면 기록 권한을 다시 물을 수 있습니다.

### 권한

처음 **시작**을 누르면 두 가지 권한을 묻습니다:
- **화면 기록** — ScreenCaptureKit 오디오 캡처에 필요 (허용 후 재시작이 필요할 수 있음)
- **음성 인식** — 받아쓰기에 필요

## 아키텍처

```
ScreenCaptureKit ─▶ SpeechAnalyzer/SpeechTranscriber ─▶ Translation ─▶ 반투명 오버레이
   (앱 오디오)          (온디바이스 STT, 스트리밍)         (온디바이스)        (NSPanel)
```

| 레이어 | 파일 |
|---|---|
| 오디오 캡처 | `Sources/Audio/SystemAudioCapture.swift` |
| 음성 인식 (프로토콜) | `Sources/Speech/SpeechRecognizing.swift` |
| 음성 인식 (Apple 구현) | `Sources/Speech/AppleSpeechRecognizer.swift` |
| 번역 (프로토콜/구현) | `Sources/Translation/Translating.swift`, `AppleTranslator.swift` |
| 고유명사 사전 / 반말 변환 | `Sources/Pipeline/GlossaryCorrector.swift`, `ConversationalStyle.swift` |
| 오케스트레이션 | `Sources/Pipeline/SubtitlePipeline.swift` |
| 오버레이 UI | `Sources/UI/OverlayPanel.swift`, `SubtitleView.swift` |

음성인식(`SpeechRecognizing`)·번역(`Translating`)이 프로토콜로 추상화돼 있어, 추후 클라우드/스트리밍 엔진으로 교체할 수 있습니다.

## 사전(글로서리) 커스터마이즈

`Resources/vtuber_glossary.json`을 편집해 자주 보는 방송인 이름/별명/용어를 추가하세요. 번역 직전에 일본어 표기가 한국어 정식 표기로 치환됩니다.

```json
{
  "version": 1,
  "entries": [
    { "jp": "兎田ぺこら", "ko": "우사다 페코라", "aliases_jp": ["ぺこら", "ぺこ"], "aliases_ko": ["페코"], "kind": "name", "group": "Hololive JP" }
  ]
}
```

## 로드맵 / 기술 노트

받아쓰기 속도·정확도 향상 연구와 향후 계획은 [`docs/ASR_RESEARCH.md`](docs/ASR_RESEARCH.md) 참고.

## 라이선스

[MIT](LICENSE)
