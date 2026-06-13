# VtuberTranslateApp — STT(받아쓰기) 속도·정확도 극대화 연구 보고서

작성일: 2026-06-13
대상: macOS 26.5(Tahoe) · Xcode 26.5 · Swift 6.3 · Apple Silicon · SwiftUI
파이프라인: ScreenCaptureKit(앱 오디오) → Apple SpeechAnalyzer + SpeechTranscriber(온디바이스 STT) → Apple Translation(일→한) → 반투명 오버레이 자막
이번 초점: STT 자체의 (1) 지연(latency-to-first-token / latency-to-stable-token) 최소화, (2) 정확도(일본어 슬랭/고유명사) 향상

---

## 0. 한 문단 요약 (Headline)

우리 앱의 가장 큰 손실은 엔진이 아니라 **우리 코드가 Apple이 이미 주는 구조(`result.isFinal` 확정/볼라타일 분리, `audioTimeRange`, `finalize(through:)`)를 전부 버리고 있다는 점**이다. `AppleSpeechRecognizer.swift`는 `result.isFinal`을 무시하고 매 volatile마다 전체 라인을 onUpdate로 흘려, 자막이 조각으로 리셋되고 번역 펌프가 같은 문장을 수십 번 재번역해 깜빡인다. 검증 결과 **contextualStrings hotword 바이어싱은 우리가 쓰는 SpeechTranscriber에서 작동하지 않고**(Apple 엔지니어 명시, refuted), `.frequentFinalization`은 SpeechTranscriber에 존재하지 않으며(SDK 확인, refuted), kotoba-whisper/Parakeet-ja의 "Apple보다 정확" 주장은 입증되지 않았다(uncertain/refuted). 반면 **`finalize(through:)`로 latency-to-stable을 직접 제어하는 API는 실재함이 확정(confirmed)**됐다. 따라서 로드맵은 (A) Apple 네이티브 확정/볼라타일 분리 + finalize 펌프 + 번역 디바운스 + 후처리 사전교정 + 자체 RMS VAD라는 **온디바이스·저비용 quickWins/mediumTerm을 먼저** 깔고, (B) 엔진 교체(WhisperKit·sherpa·dual-engine)는 "Apple 일본어가 실측에서 부족할 때만" 가는 R&D 트랙으로 둔다. 신규 아키텍처로는 **ja→ko가 SOV→SOV 동어순이라는 점을 이용한 confirmed-prefix 증분 번역(공동 재배치 파이프라인)**이 가장 구현가능·고효과다.

---

## 1. 우리 코드의 확정 병목 (실측 기반)

| # | 위치 | 병목 | 효과 |
|---|------|------|------|
| B1 | `AppleSpeechRecognizer.swift:51-54` | `result.isFinal` 무시. 모든 result.text를 통째 onUpdate. SpeechTranscriber는 비-중첩 구간별 final + 교체형 volatile tail을 주는데 이를 단일 noisy 라인으로 붕괴 → 자막 조각 리셋·번역 문맥 깨짐 | **자막 flicker의 근원** |
| B2 | `SubtitlePipeline.swift:101-122` | volatile 매 tick마다 `pendingSource=line; pumpTranslation()`. 부분문자열 갱신을 못 걸러 같은 문장을 반복 번역 → liveTranslation 깜빡, latency-to-stable-translation 증가 | 번역 큐 낭비 |
| B3 | `AppleSpeechRecognizer.swift:64` | `AnalyzerInput(buffer:)`만 사용, `bufferStartTime` 미지정. `audioTimeRange`를 켜두고도 PTS를 안 줘 타임라인 신뢰도 저하 | 소폭(드롭/지터 시) |
| B4 | `AppleSpeechRecognizer.swift:67-77` | 스트리밍 중 `finalize(through:)` 호출 전무. stop()의 `finalizeAndFinishThroughEndOfInput()`만 존재 → 확정 타이밍을 모델 자율에 100% 위임, latency-to-stable 직접 제어 불가 | **stable 지연 제어 불가** |
| B5 | `SubtitlePipeline.swift:74-76` | 무음/BGM 포함 모든 버퍼를 무조건 append → 비발화 구간 오인식(환각) + 연산 낭비 | 정확도·전력 |
| B6 | `SpeechRecognizing.swift:7` | `onUpdate: ((String)->Void)` 시그니처가 isFinal/confidence/구간을 못 넘김 → 위 개선들의 공통 선결 조건 | 구조적 제약 |

---

## 2. 핵심 주장 검증 결과 (verdict 신뢰)

| 주장 | verdict | 로드맵 영향 |
|------|---------|------------|
| SpeechTranscriber가 contextualStrings로 일본어 hotword 바이어싱을 지원한다 | **refuted** | Apple 엔지니어(포럼 801877/811083)가 "SpeechTranscriber는 contextual strings를 고려하지 않는다. DictationTranscriber만 지원" 명시. → 현 엔진 hotword 바이어싱 제외, **후처리 사전교정**으로 대체 |
| SpeechTranscriber.ReportingOption에 `.frequentFinalization`이 있고 stable 지연을 줄인다 | **refuted** | SDK(MacOSX26.5.sdk .swiftinterface) 직접 확인: SpeechTranscriber 케이스는 `.volatileResults / .alternativeTranscriptions / .fastResults` 뿐. `.frequentFinalization`은 DictationTranscriber 전용. → 로드맵에서 제거 |
| SpeechAnalyzer에 `finalize(through:)`가 있어 임의 시점까지 강제 확정 가능 | **confirmed** | Apple 공식 문서 확인. 세션 유지한 채 중간 확정 가능. → **latency-to-stable 직접 제어의 토대(핵심 레버)** |
| ja-JP가 SpeechTranscriber.supportedLocales에 포함, 온디바이스 동작 | **confirmed** | 43개 로케일 verbatim 3중 교차확인에 ja_JP 포함. (주의: 시뮬레이터는 빈 배열 → 실기 테스트 필수) |
| kotoba-whisper-v2.0이 large-v3 대비 6.3x 빠르고 일본어 CER 동등 이상 | **uncertain** | in-domain만 우세, OOD는 large-v3보다 약간 나쁨. 6.3x는 배치 throughput이지 latency 아님. VTuber 도메인 벤치 전무 → 강등 |
| WhisperKit confirmed 지연 ~1.7s/word, hypothesis ~0.45s/word | **confirmed(수치)** | 단 1.7s는 WhisperKit 고유 결함 아닌 confirmation 방식 공통. Apple과 직접 비교는 논문에 없음 → 도입 시 hypothesis만 표시, confirmed는 보정 신호 |
| Parakeet TDT v3가 일본어 미지원 / FluidAudio 일본어 미제공 | **refuted(후반부)** | v3는 일본어 미지원 맞으나, FluidAudio는 **전용 `parakeet-tdt_ctc-0.6b-ja`(CoreML, vocab 포함)** 제공. 단 배치/풀컨텍스트라 스트리밍 저지연은 별도 구현 |
| 고유명사 개선은 후처리로 가야 한다 | **confirmed** | SpeechTranscriber 바이어싱 불가 + WhisperKit promptTokens 버그(#372 open) → 후처리 1순위. 단 SFSpeechRecognizer(legacy) hybrid 분기는 보조 옵션 |
| 진짜 스트리밍 일본어 transducer 온디바이스 모델은 없다 | **부분 refuted** | nvidia/nemotron-3.5-asr-streaming-0.6b(2026-06-04)이 cache-aware 스트리밍+일본어 지원, CoreML 변환본(FluidInference, 5.11GB)까지 공개. 단 0.6B로 무겁고 FluidAudio Swift 일본어 스트리밍 경로 미배선 → PoC 후 결정 |
| Reazon/Parakeet-ja가 실제 VTuber 오디오에서 Apple보다 정확 | **refuted** | 잡음/슬랭 포함 실미디어 벤치에서 Reazon-nemo-v2 CER 0.329로 6위(Whisper-turbo 0.184, Qwen3 0.140 대비 열세). Apple과의 일본어 직접 비교 데이터 자체가 없음 → A/B 전 고비용 변환 정당화 불가 |
| Apple [.volatileResults,.fastResults]가 80-560ms 스트리밍 모델과 동등 이상 지연 | **uncertain** | Apple은 스트리밍 TTFT 수치 미공개(전부 배치 throughput). 경쟁사 80-560ms는 chunk-size 설정값(측정 TTFT 아님). → 자체 계측 필수 |
| ONNX/CoreML로 NVIDIA/Moonshine 인코더가 ANE에 자동 안착·장시간 안정 | **uncertain(refuted 경향)** | ANE 안착은 자동 아님(ORT CoreML EP가 미지원 op를 CPU로 폴백, dynamic shape는 ANE 비친화). NeMo #5867은 x86 CPU 캐시버그라 ANE 예측 근거 아님 → soak test 필요 |

---

## 3. 기법 카탈로그 (적용 가능성 평가)

### 3.1 Apple 네이티브 knob (온디바이스, 저비용)

| 기법 | 적용 | 일본어 | 지연 효과 | 정확도 효과 | 난이도 | 비고 |
|------|------|--------|-----------|------------|--------|------|
| `result.isFinal` 확정/볼라타일 분리 (B1) | O | O | 중간↓ | 중간↑ | 낮음 | flicker 근원 제거. 모든 후속의 선결 |
| 번역 펌프를 confirmed=즉시 / volatile=디바운스(120-200ms)로 분리 (B2) | O | O | 중간↓ | 소폭 | 낮음 | 재번역 낭비·깜빡임 제거 |
| `finalize(through:)` 무음 트리거 펌프 (B4) | O | O | **큰↓** | 소폭(과도 시 ↓) | 낮음-중간 | confirmed API. 윈도(0.6-1.0s) 튜닝 |
| `AnalyzerInput(buffer:bufferStartTime:)` PTS 전달 (B3) | O | O | 소폭 | 소폭 | 낮음 | audioTimeRange 신뢰도↑ |
| `.preset(.timeIndexedProgressiveTranscription)` 정리 | O | O | 없음 | 없음 | trivial | 현 수동 구성과 동등 시 채택(유지보수) |
| `.alternativeTranscriptions` + `.transcriptionConfidence` | O | O | 소폭 | 중간↑ | 중간 | n-best 재랭킹·저신뢰 흐림. 미문서 필드 실측 |
| 모델 사전 다운로드·예열 (콜드스타트 제거) | O | O | 중간↓ | 없음 | 낮음 | 온보딩 시 ja-JP 설치 + 무음 예열 |

### 3.2 오디오 파이프라인

| 기법 | 적용 | 지연 | 정확도 | 난이도 |
|------|------|------|--------|--------|
| SCK sampleRate를 분석기 포맷(예 16k)에 맞춰 변환 제거/경량화 | O | 소폭↓ | 없음 | trivial (SCK 16k 거부 시 폴백 유지) |
| AVAudioConverter primeMethod=.none, quality=.medium | O | 소폭↓ | 없음 | trivial |
| 자체 RMS VAD 게이팅(히스테리시스+행오버) (B5) | O | 소폭↓ | 중간↑ | 낮음 | vDSP_rmsqv. 환각 억제 |
| 게인 정규화/소프트 AGC (VAD 연동) | O | 없음 | 소폭↑ | 낮음 | 작은 목소리 일본어 VTuber에 유효 |
| SpeechDetector 모듈(통합 VAD) | O | 소폭 | 중간↑ | 낮음 | 26.5 SpeechModule 준수 실측 필요. 경계 이벤트 미노출 → finalize 트리거로는 부적합 |

### 3.3 스트리밍 디코딩/안정화

| 기법 | 적용 | 비고 |
|------|------|------|
| Apple 네이티브 confirmed/volatile = 내장 LocalAgreement | O | 외부 레이어 불필요. B1이 곧 이것 |
| LocalAgreement-2 자체 구현 | 조건부 | Whisper류 엔진 도입 시에만. CJK는 문자 단위 LCP |
| confirmed-prefix 증분 번역(ja→ko SOV) | O | **신규 아키텍처(섹션 5)** |
| AlignAtt 방출 정책 | X | 어텐션 접근 필요, Apple 불가. R&D |

### 3.4 외부 엔진 (bigBets / R&D)

| 엔진 | 일본어 | 스트리밍 | 바이어싱 | 우리 적합성 |
|------|--------|----------|----------|-------------|
| WhisperKit large-v3-turbo (CoreML/ANE) | O | hypothesis 0.45s / confirmed 1.7s | promptTokens 버그(#372) | dual-engine 정확 엔진 후보. ja 실측 필요 |
| sherpa-onnx ReazonSpeech zipformer-ja | O | **오프라인**(VAD 분절 필요) | **O(cjkchar+modified_beam_search)** | **hotword 바이어싱이 유일 강점**. 저지연 아님 |
| sherpa-onnx Parakeet-ja(CTC 경로) | O | 오프라인 | X(CTC) | 구두점은 있으나 바이어싱 불가 |
| FluidAudio Parakeet-tdt_ctc-0.6b-ja | O | 배치/풀컨텍스트 | X | 정확도 A/B 참조. 스트리밍 직접 구현 부담 |
| nvidia nemotron-3.5-asr-streaming-0.6b | O | **진짜 cache-aware 스트리밍** | - | CoreML 공개(5.11GB). Swift 일본어 경로 미배선. PoC 가치 |
| Parakeet TDT v3 / EOU / Moonshine v2 / Kyutai | X(일본어) | - | - | 일본어 미지원 → 영어 모드 전용 |

---

## 4. 실행 로드맵

### quickWins (이미 가능, Apple knob·코드 수정)
1. **isFinal 확정/볼라타일 분리** — `AppleSpeechRecognizer.swift:51-54` + `SpeechRecognizing.swift:7` 시그니처 확장. flicker 근원 제거. (낮음 / 효과 큼)
2. **번역 펌프 confirmed=즉시 / volatile=디바운스** — `SubtitlePipeline.swift:109-122`. 재번역 낭비·깜빡임 제거. (낮음)
3. **finalize(through:) 무음 트리거 펌프** — confirmed API로 latency-to-stable 직접 제어. (낮음-중간, 효과 큼)
4. **모델 사전 다운로드·예열** — `start()` 콜드스타트 제거. (낮음)
5. **bufferStartTime(PTS) 전달** — 타임라인 신뢰도. (낮음)
6. **오디오 포맷 정합 + converter 튜닝** — 변환 비용·지터 감소. (trivial)

### mediumTerm
7. **자체 RMS VAD 게이팅 + EOU finalize 결합** — 환각 억제 + 라인 커밋 가속. (낮음-중간)
8. **후처리 사전교정(GlossaryCorrector)** — VTuber 이름/밈 용어집 정확매칭 + 경량 Levenshtein. 바이어싱 불가의 실질 해법. (낮음, 정확도 핵심)
9. **alternativeTranscriptions + confidence 게이팅** — n-best 재랭킹·저신뢰 흐림. (중간)
10. **confidence 기반 표시 제어 + 게인 정규화** — 작은 목소리 보정. (낮음-중간)

### bigBets (엔진 교체 / R&D, "Apple ja 부족 실측" 게이팅)
11. **WhisperKit dual-engine consensus** — Apple hypothesis(즉시) + WhisperKit(보정). 신규 아키텍처 후보. (중간-높음)
12. **sherpa-onnx ReazonSpeech-ja(바이어싱 전용 보조)** — hotword가 결정적으로 필요할 때. (높음)
13. **nemotron-3.5-asr-streaming CoreML PoC** — 진짜 스트리밍 ja. SpeechRecognizing 뒤 2nd 구현체로 A/B. (높음)

### 권장 구현 순서
1 → 2 → 3 → 8 → 7 → 5 → 6 → 4 → 9 → 10 → (실측 후) 11 → 13 → 12

근거: 1·2·3은 코드 한 곳 수정으로 flicker·지연·재번역을 동시에 잡는 최고 ROI. 8은 정확도 핵심 레버(엔진 무관, 온디바이스, 즉효). 7은 VAD가 finalize/환각 양쪽에 쓰여 시너지. 엔진 교체(11-13)는 1-10으로 Apple 한계를 실측한 뒤에만 착수.

---

## 5. 신규 아키텍처 설계 (Novel Proposal)

### "SOV-aware confirmed-prefix 증분 동시통역 파이프라인"

**왜:** 일본어와 한국어는 둘 다 SOV(주어-목적어-동사) 동어순이라 영↔일과 달리 단어 재배치가 거의 없다. 동시통역 연구의 FIFO(원어순 유지) 전략이 ja→ko에 자연스럽게 맞아, "확정된 만큼만 이어서 번역"하는 증분 번역의 품질 손실이 작다. 현재 latest-wins는 전체 라인을 매번 통째 재번역해 번역 비용 낭비 + 자막 출렁임을 만든다. confirmed prefix를 번역 잠금 단위로 삼으면 latency-to-stable-token이 곧 latency-to-stable-translation으로 직결되고 출렁임이 크게 준다.

**아키텍처:**
- `SpeechRecognizing.onUpdate`를 `(text, finalizedUpToCharIndex)` 구조로 확장(quickWin 1과 공유).
- `AppleSpeechRecognizer`가 `result.isFinal` 누적분을 `finalizedUpTo`로 전달.
- `SubtitlePipeline`에 `confirmedSourcePrefix`, `translatedPrefix` 상태. confirmed 경계가 늘면 **새 확정 청크만** translate에 보내 translatedPrefix에 append·잠금.
- volatile tail은 1개만 in-flight 번역해 회색으로 덧붙임(현 latest-wins 유지). `liveTranslation = translatedPrefix(검정) + volatileTail번역(회색)`.
- 청크는 문절/조사 경계·짧은 휴지(audioTimeRange gap)에서만 끊어 술어 직전까지는 volatile 유지(부정/시제 늦게 오는 일본어 보수적 커밋).
- 직전 1-2 확정 청크를 슬라이딩 컨텍스트로 함께 넣고 새 청크만 표시해 짧은 청크 번역 어색함 완화.

**리스크:** 일본어 문말 술어(〜ない/〜たい)가 의미를 뒤집어 조기 잠금 시 오역 고착 → 문절 단위 보수 커밋 필수. Apple Translation의 짧은 청크 문맥 부족 → 슬라이딩 컨텍스트로 완화. 효과는 confirmed 경계 품질에 의존(quickWin 1·3과 시너지).

---

## 6. 참고문헌

- Apple WWDC25 Session 277 — Bring advanced speech-to-text to your app with SpeechAnalyzer: https://developer.apple.com/videos/play/wwdc2025/277/
- Apple Docs — SpeechAnalyzer (finalize(through:)): https://developer.apple.com/documentation/speech/speechanalyzer
- Apple Docs — SpeechTranscriber.ReportingOption / Preset: https://developer.apple.com/documentation/speech/speechtranscriber
- Apple Docs — AnalysisContext.contextualStrings: https://developer.apple.com/documentation/speech/analysiscontext
- Apple Developer Forums thread/801877, /811083 (contextualStrings = DictationTranscriber only)
- Apple Developer Forums thread/797544 (SpeechDetector), /795924 (concurrency 14.8s trap)
- WhisperKit: On-device Real-time ASR — arXiv 2507.10860: https://arxiv.org/html/2507.10860v1
- Turning Whisper into Real-Time Transcription System (LocalAgreement-2) — arXiv 2307.14743
- kotoba-whisper-v2.0: https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0
- nvidia/parakeet-tdt_ctc-0.6b-ja: https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja
- FluidInference/parakeet-ctc-0.6b-ja-coreml; FluidAudio: https://github.com/FluidInference/FluidAudio
- nvidia/nemotron-3.5-asr-streaming-0.6b (2026-06-04); FluidInference CoreML 변환본
- sherpa-onnx hotwords / ReazonSpeech zipformer-ja: https://k2-fsa.github.io/sherpa/onnx/hotwords/index.html
- SASST: Syntax-Aware Chunking for Simultaneous Speech Translation — arXiv 2508.07781
- Model-free Speculative Decoding for ASR (Token Map Drafting) — arXiv 2507.21522
