import Translation

/// Apple Translation 프레임워크 기반 온디바이스 번역기.
/// 세션은 SwiftUI `.translationTask`가 만들어 주입한다(미설치 언어 다운로드 처리 때문).
@MainActor
final class AppleTranslator: Translating {
    private var session: TranslationSession?

    func attach(_ session: TranslationSession?) {
        self.session = session
    }

    func translate(_ text: String) async -> String? {
        guard let session, !text.isEmpty else { return nil }
        do {
            return try await session.translate(text).targetText
        } catch {
            return nil
        }
    }
}
