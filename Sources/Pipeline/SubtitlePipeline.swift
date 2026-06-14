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
    // 멤버 이름 보정: 켜면 ① 번역 전 일본어 이름→한국어 정식표기 치환, ② STT 어휘 부스팅.
    @Published var nameBoosting = UserDefaults.standard.bool(forKey: "nameBoosting") {
        didSet { UserDefaults.standard.set(nameBoosting, forKey: "nameBoosting") }
    }

    // V2.1 하이브리드: 확정(완성 문장) 자막은 DeepL(고품질), 진행 중은 Apple 온디바이스(즉시).
    @Published var useDeepL = UserDefaults.standard.bool(forKey: "useDeepL") {
        didSet { UserDefaults.standard.set(useDeepL, forKey: "useDeepL") }
    }
    @Published var deepLApiKey = UserDefaults.standard.string(forKey: "deepLApiKey") ?? "" {
        didSet { UserDefaults.standard.set(deepLApiKey, forKey: "deepLApiKey") }
    }

    private let capture = SystemAudioCapture()
    private var recognizer: SpeechRecognizing = FluidParakeetJaRecognizer()
    private let translator = AppleTranslator()
    private let deepL = DeepLTranslator()
    private let glossary = GlossaryCorrector()

    // 문장 단위 번역 상태: 확정(흰색)은 "완성된 문장"만 번역해 잠그고(고품질),
    // 진행 중(회색)은 미완성 꼬리를 빠르게 초벌 번역한다.
    private var stableSentences: [String] = []     // 현재 확정 텍스트의 완성 문장들(JP)
    private var draftSource = ""                    // 진행 중 = 미완성 문장 + 미확정 꼬리(JP)
    private var lastDraftSent = ""
    private var sentenceCache: [String: String] = [:]   // 완성 문장(JP) → 번역(KO), 1회만 번역
    private var needsTranslate = false
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
        stableSentences = []
        draftSource = ""
        lastDraftSent = ""
        sentenceCache.removeAll()
        needsTranslate = false
        translateWorker?.cancel()
        translateWorker = nil
    }

    // MARK: 인식 → 번역

    private func handleUpdate(_ update: TranscriptionUpdate) {
        let cc = max(0, min(update.confirmedCharCount, update.text.count))
        let confirmedText = String(update.text.prefix(cc))
        let volatileTail = String(update.text.dropFirst(cc)).trimmingCharacters(in: .whitespacesAndNewlines)

        liveSource = update.text       // 원문은 즉시 표시(지연 0)

        // 확정 영역을 완성 문장 + 미완성 꼬리로 분리.
        // 완성 문장만 흰색으로 잠그고(완전한 입력 → NMT 품질↑), 나머지는 회색 초벌로.
        let (complete, partial) = Self.splitSentences(confirmedText)
        var stable = complete
        var draft = (partial + " " + volatileTail).trimmingCharacters(in: .whitespacesAndNewlines)
        // 발화가 통째로 확정됐는데 종결부호가 없으면(STT가 。를 안 붙인 경우),
        // 미완성 꼬리를 한 문장으로 간주해 흰색으로 잠근다(회색에 영영 남는 것 방지).
        if cc == update.text.count, cc > 0, !partial.isEmpty {
            stable.append(partial)
            draft = ""
        }
        stableSentences = stable
        draftSource = draft

        rebuildConfirmed()             // 캐시된 문장은 즉시 반영
        needsTranslate = true
        kickTranslator()
    }

    /// 캐시된 완성-문장 번역을 앞에서부터 이어붙여 흰색 확정 자막을 만든다(빈 구멍 없이 prefix만).
    private func rebuildConfirmed() {
        var parts: [String] = []
        for s in stableSentences {
            guard let t = sentenceCache[s] else { break }
            parts.append(t)
        }
        confirmedTranslation = parts.joined(separator: " ")
    }

    /// 완성 문장은 "한 문장 통째로" 1회 번역해 캐시·잠그고(고품질), 진행 중 꼬리는 최신값으로 빠르게
    /// 초벌 번역해 회색으로 덧붙인다. 번역은 항상 1개만 in-flight라 세션 충돌이 없다.
    private func kickTranslator() {
        guard translateWorker == nil else { return }
        translateWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.needsTranslate {
                self.needsTranslate = false
                // 1) 완성 문장: 캐시에 없는 것만 완전한 문장으로 번역(DeepL 고품질, 1회).
                for s in self.stableSentences where self.sentenceCache[s] == nil {
                    if let translated = await self.translate(s, highQuality: true) {
                        self.sentenceCache[s] = translated
                        self.rebuildConfirmed()
                    }
                }
                // 2) 진행 중(회색): 미완성 꼬리를 빠르게 번역.
                if self.draftSource != self.lastDraftSent {
                    self.lastDraftSent = self.draftSource
                    if self.draftSource.isEmpty {
                        self.volatileTranslation = ""
                    } else if let translated = await self.translate(self.draftSource) {
                        self.volatileTranslation = translated
                    }
                }
            }
            self.translateWorker = nil
        }
    }

    /// 일본어 텍스트를 문장 종결부호 기준으로 (완성 문장들, 미완성 꼬리)로 나눈다.
    private static let sentenceEnders: Set<Character> = ["。", "．", "！", "!", "？", "?", "…", "\n"]
    private static func splitSentences(_ text: String) -> (complete: [String], trailing: String) {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if sentenceEnders.contains(ch) {
                let s = current.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { sentences.append(s) }
                current = ""
            }
        }
        return (sentences, current.trimmingCharacters(in: .whitespaces))
    }

    /// 번역 전 고유명사 치환 → 번역 → 반말 변환.
    /// highQuality(확정 문장)면 DeepL을 우선 쓰고, 미사용/실패 시 Apple 온디바이스로 폴백한다.
    private func translate(_ source: String, highQuality: Bool = false) async -> String? {
        // 멤버 이름 치환은 "멤버 이름 부스팅" 토글이 켜졌을 때만(슬랭은 항상).
        let localized = glossary.localize(source, includeNames: nameBoosting)
        var translated: String?
        if highQuality, useDeepL, !deepLApiKey.isEmpty {
            translated = await deepL.translate(localized, apiKey: deepLApiKey,
                                               source: sourceLanguage.deepLCode,
                                               target: targetLanguage.deepLCode)
        }
        if translated == nil {                         // DeepL 미사용/실패 → 온디바이스 폴백
            translated = await translator.translate(localized)
        }
        guard let result = translated else { return nil }
        return casualizeKorean ? ConversationalStyle.casualize(result) : result
    }
}
