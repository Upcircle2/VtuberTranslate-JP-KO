import Foundation

/// 번역 결과의 격식체(합니다/한다체) 문장 종결을 대화체(반말)로 바꾼다.
/// 방송인은 보통 반말/구어체로 말하므로 자막도 그렇게 보이는 게 자연스럽다.
///
/// 잘못된 한국어를 만들지 않도록 **규칙적이거나 특정한 안전한 종결만** 변환한다.
/// (예: 과거형 았/었+종결은 항상 규칙적이라 안전. '좋습니다'처럼 모음조화가 필요한
///  불규칙은 제외.) 완전한 스타일 변환은 추후 하이브리드 LLM에서 처리한다.
enum ConversationalStyle {
    /// 문장 끝(긴 것 우선)에서만 적용하는 종결 치환표.
    private static let endings: [(String, String)] = [
        // 과거형(규칙적) — 안전
        ("했습니다", "했어"), ("했어요", "했어"), ("했다", "했어"),
        ("였습니다", "였어"), ("였어요", "였어"), ("였다", "였어"), ("이었다", "이었어"),
        ("았습니다", "았어"), ("았어요", "았어"),
        ("었습니다", "었어"), ("었어요", "었어"),
        // 현재/평서
        ("합니다", "해"), ("해요", "해"), ("한다", "해"),
        ("됩니다", "돼"), ("됐습니다", "됐어"), ("됐어요", "됐어"), ("된다", "돼"),
        ("있습니다", "있어"), ("있어요", "있어"), ("있다", "있어"),
        ("없습니다", "없어"), ("없어요", "없어"), ("없다", "없어"),
        ("겠습니다", "겠어"), ("겠어요", "겠어"),
        // 계사
        ("입니다", "이야"), ("이에요", "이야"), ("예요", "야"),
        // 의향/추측/감탄
        ("거예요", "거야"), ("거에요", "거야"), ("겁니다", "거야"),
        ("네요", "네"), ("군요", "구나"), ("지요", "지"), ("죠", "지"),
        // 자주 나오는 인사/반응(LLM이 존댓말로 빠질 때 보정)
        ("감사합니다", "고마워"), ("감사해요", "고마워"), ("고맙습니다", "고마워"), ("고마워요", "고마워"),
        ("죄송합니다", "미안"), ("죄송해요", "미안"), ("미안해요", "미안"),
        ("좋아요", "좋아"), ("싫어요", "싫어"), ("그래요", "그래"), ("맞아요", "맞아"),
        ("아니에요", "아니야"), ("아니요", "아니"),
        ("잖아요", "잖아"), ("거든요", "거든"), ("는데요", "는데"), ("던데요", "던데"),
    ]

    private static let sortedEndings = endings.sorted { $0.0.count > $1.0.count }
    private static let sentenceEnders: Set<Character> = ["。", "．", ".", "！", "!", "？", "?", "…", "\n"]

    static func casualize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = ""
        var sentence = ""
        for char in text {
            sentence.append(char)
            if sentenceEnders.contains(char) {
                result += convertSentence(sentence)
                sentence = ""
            }
        }
        result += convertSentence(sentence)   // 종결부호 없는 마지막 조각(진행 중 자막)
        return result
    }

    private static func convertSentence(_ sentence: String) -> String {
        guard !sentence.isEmpty else { return sentence }
        // 끝쪽 공백/문장부호를 분리한 뒤 핵심 종결만 검사한다.
        var trailing = ""
        var core = sentence
        while let last = core.last, last.isWhitespace || sentenceEnders.contains(last) {
            trailing = String(last) + trailing
            core.removeLast()
        }
        for (formal, casual) in sortedEndings where core.hasSuffix(formal) {
            core.removeLast(formal.count)
            core += casual
            break
        }
        return core + trailing
    }
}
