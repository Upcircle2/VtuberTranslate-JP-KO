import Foundation

/// 앱이 지원하는 언어. 소스(음성)·타깃(번역) 양쪽에 사용한다.
/// 새 언어 확장은 여기에 case 하나만 추가하면 된다.
enum AppLanguage: String, CaseIterable, Identifiable {
    case japanese
    case english
    case korean

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .japanese: "일본어"
        case .english: "영어"
        case .korean: "한국어"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .japanese: "ja-JP"
        case .english: "en-US"
        case .korean: "ko-KR"
        }
    }

    var locale: Locale { Locale(identifier: localeIdentifier) }
    var language: Locale.Language { Locale.Language(identifier: localeIdentifier) }

    /// DeepL API 언어 코드.
    var deepLCode: String {
        switch self {
        case .japanese: "JA"
        case .english: "EN"
        case .korean: "KO"
        }
    }
}
