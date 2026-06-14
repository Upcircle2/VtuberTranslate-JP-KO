import Foundation

/// DeepL API 기반 클라우드 번역기(고품질). 확정(완성 문장) 자막에만 쓰고, 진행 중 자막은
/// Apple 온디바이스로 즉시 처리하는 하이브리드 구조의 "고품질" 쪽을 담당한다.
/// 키가 `:fx`로 끝나면 무료(api-free) 엔드포인트. 실패(키 오류·네트워크·할당량) 시 nil →
/// 호출부에서 Apple 온디바이스로 자동 폴백한다.
final class DeepLTranslator {
    /// - Parameters:
    ///   - source/target: DeepL 언어코드(JA·EN·KO 등).
    func translate(_ text: String, apiKey: String, source: String, target: String) async -> String? {
        guard !text.isEmpty, !apiKey.isEmpty else { return nil }
        let host = apiKey.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        guard let url = URL(string: "https://\(host)/v2/translate") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["text": [text], "source_lang": source, "target_lang": target]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translations = json["translations"] as? [[String: Any]],
              let first = translations.first?["text"] as? String,
              !first.isEmpty else { return nil }
        return first
    }
}
