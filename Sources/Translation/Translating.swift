/// 번역 엔진 추상화. 지금은 Apple 온디바이스(Translation 프레임워크) 구현만 있지만,
/// 나중에 DeepL·GPT 등 클라우드 구현체로 교체해 번역 품질을 올릴 수 있도록 프로토콜로 둔다.
protocol Translating: AnyObject {
    /// 번역 결과를 돌려준다. 준비가 안 됐거나 실패하면 nil.
    func translate(_ text: String) async -> String?
}
