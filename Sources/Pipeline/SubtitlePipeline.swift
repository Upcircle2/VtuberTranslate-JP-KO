import Foundation
import SwiftUI
import ScreenCaptureKit
import Translation

/// 오디오 캡처 → 음성 인식 → 번역 → 자막 표시를 잇는 오케스트레이터.
@MainActor
final class SubtitlePipeline: ObservableObject {
    // 설정
    @Published var availableApps: [SCRunningApplication] = []
    @Published var selectedAppID: pid_t?
    @Published var sourceLanguage: AppLanguage = .japanese
    @Published var targetLanguage: AppLanguage = .korean

    // 상태
    @Published var isRunning = false
    @Published var statusMessage = "대기 중"

    // 자막 표시: 원문 + (확정 번역=흰색) + (진행 중 번역=회색 꼬리)
    @Published var liveSource = ""
    @Published var confirmedTranslation = ""
    @Published var volatileTranslation = ""

    // SwiftUI `.translationTask`가 관찰하는 번역 설정
    @Published var translationConfig: TranslationSession.Configuration?

    // 번역 다듬기 옵션
    @Published var casualizeKorean = true   // 격식체 → 반말(대화체)
    @Published var nameBoosting = false     // 이름 CustomVocabulary 부스팅(실험, 기본 끔)

    private let capture = SystemAudioCapture()
    private var recognizer: SpeechRecognizing = FluidParakeetJaRecognizer()
    private let translator = AppleTranslator()
    private let glossary = GlossaryCorrector()

    // confirmed-prefix 증분 번역 상태(ja→ko SOV 동어순 활용)
    private var confirmedSource = ""
    private var volatileSource = ""
    private var lastConfirmedSent = ""
    private var lastVolatileSent = ""
    private var needsConfirmed = false
    private var needsVolatile = false
    private var translateWorker: Task<Void, Never>?

    // MARK: 설정/준비

    func refreshApps() async {
        do {
            availableApps = try await SystemAudioCapture.availableApps()
            if availableApps.isEmpty {
                statusMessage = "앱 목록이 비어 있습니다. 화면 기록 권한을 확인하세요."
            } else if !isRunning {
                statusMessage = "앱 \(availableApps.count)개 감지됨. 음원 앱을 선택하세요."
            }
        } catch {
            statusMessage = "앱 목록을 가져오지 못했습니다: \(error.localizedDescription)"
        }
    }

    /// 받아쓰기 엔진은 FluidAudio Parakeet-ja(일본어 정확) 단일 고정.
    private func makeRecognizer() -> SpeechRecognizing {
        let recognizer = FluidParakeetJaRecognizer()
        if nameBoosting { recognizer.vocabulary = glossary.nameVocabulary }
        return recognizer
    }

    /// 방송 시작 전에 음성 모델을 미리 내려받아 콜드스타트를 줄인다.
    func prepare() async {
        await makeRecognizer().prewarm(locale: sourceLanguage.locale)
    }

    func attachTranslationSession(_ session: TranslationSession) {
        translator.attach(session)
    }

    // MARK: 시작/중지

    func start() async {
        guard !isRunning else { return }
        guard let appID = selectedAppID,
              let app = availableApps.first(where: { $0.processID == appID }) else {
            statusMessage = "먼저 음원 앱을 선택하세요."
            return
        }

        resetSubtitleState()

        // 번역 세션 준비(미설치 언어면 시스템이 다운로드를 안내).
        translationConfig = TranslationSession.Configuration(
            source: sourceLanguage.language,
            target: targetLanguage.language
        )

        recognizer = makeRecognizer()
        recognizer.onUpdate = { [weak self] update in
            Task { @MainActor in self?.handleUpdate(update) }
        }
        capture.onBuffer = { [recognizer] buffer, pts in
            recognizer.append(buffer, at: pts)
        }

        do {
            statusMessage = "음성 모델 준비 중…"
            try await recognizer.start(locale: sourceLanguage.locale)
            statusMessage = "오디오 캡처 시작 중…"
            try await capture.start(app: app)
            isRunning = true
            statusMessage = "\(app.applicationName) 자막 송출 중"
        } catch {
            statusMessage = "시작 실패: \(error.localizedDescription)"
            await stop()
        }
    }

    func stop() async {
        translateWorker?.cancel()
        translateWorker = nil
        await capture.stop()
        await recognizer.stop()
        recognizer.onUpdate = nil
        capture.onBuffer = nil
        isRunning = false
        statusMessage = "중지됨"
    }

    private func resetSubtitleState() {
        liveSource = ""
        confirmedTranslation = ""
        volatileTranslation = ""
        confirmedSource = ""
        volatileSource = ""
        lastConfirmedSent = ""
        lastVolatileSent = ""
        needsConfirmed = false
        needsVolatile = false
        translateWorker?.cancel()
        translateWorker = nil
    }

    // MARK: 인식 → 번역

    private func handleUpdate(_ update: TranscriptionUpdate) {
        let cc = max(0, min(update.confirmedCharCount, update.text.count))
        let confirmed = String(update.text.prefix(cc))
        let volatile = String(update.text.dropFirst(cc)).trimmingCharacters(in: .whitespacesAndNewlines)

        liveSource = update.text       // 원문은 즉시 표시(지연 0)
        confirmedSource = confirmed
        volatileSource = volatile

        if confirmed != lastConfirmedSent { needsConfirmed = true }
        if volatile != lastVolatileSent { needsVolatile = true }
        kickTranslator()
    }

    /// 확정 prefix는 즉시(저빈도·고중요) 번역해 잠그고, volatile 꼬리는 최신값 우선으로 번역해
    /// 회색으로 덧붙인다. 번역은 항상 1개만 in-flight라 세션 충돌이 없다.
    private func kickTranslator() {
        guard translateWorker == nil else { return }
        translateWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.needsConfirmed || self.needsVolatile {
                if self.needsConfirmed {
                    self.needsConfirmed = false
                    let src = self.confirmedSource
                    self.lastConfirmedSent = src
                    if src.isEmpty {
                        self.confirmedTranslation = ""
                    } else if let translated = await self.translate(src) {
                        self.confirmedTranslation = translated
                    }
                } else if self.needsVolatile {
                    self.needsVolatile = false
                    let src = self.volatileSource
                    self.lastVolatileSent = src
                    if src.isEmpty {
                        self.volatileTranslation = ""
                    } else if let translated = await self.translate(src) {
                        self.volatileTranslation = translated
                    }
                }
            }
            self.translateWorker = nil
        }
    }

    /// 번역 전 고유명사 치환(이름 정확 출력) → Apple 온디바이스 번역 → 반말 변환.
    private func translate(_ source: String) async -> String? {
        let localized = glossary.localize(source)
        guard let translated = await translator.translate(localized) else { return nil }
        return casualizeKorean ? ConversationalStyle.casualize(translated) : translated
    }
}
