import Foundation

/// 번들에 포함된 VTuber 고유명사/슬랭 사전을 읽어, 번역 직전에 일본어 표기를
/// 한국어 정식 표기로 치환한다. 이렇게 하면 Apple 번역기의 들쭉날쭉한 음역 대신
/// 우리가 지정한 이름/별명이 그대로 출력된다(바이어싱 불가의 실질 해법).
final class GlossaryCorrector {
    private struct NamePart: Decodable { let jp: String; let ko: String }
    private struct Entry: Decodable {
        let jp: String
        let ko: String
        let aliases_jp: [String]?
        let aliases_ko: [String]?
        let kind: String?
        let group: String?
        let surname: NamePart?
        let given: NamePart?
    }
    private struct File: Decodable { let entries: [Entry] }
    /// 슬랭/게임용어 치환 사전(`vtuber_slang.json`, 검증된 안전 치환만).
    private struct SlangEntry: Decodable { let jp: String; let ko: String }

    /// 멤버 이름 치환(일본어→한국어). "멤버 이름 부스팅" 토글이 켜졌을 때만 적용한다.
    private let nameReplacements: [(jp: String, ko: String)]
    /// 슬랭 치환(やばい→대박 등). 이름과 무관하므로 항상 적용한다.
    private let slangReplacements: [(jp: String, ko: String)]

    /// STT 커스텀 어휘(바이어싱)용 일본어 이름 형태 목록(이름 전체+성+이름+별칭).
    /// 치환과 달리 과매칭 부담이 없어 성씨도 포함한다.
    let nameVocabulary: [String]

    /// 3글자 이상이라 길이 필터를 통과하지만, 치환하면 흔한 단어를 깨뜨리는 일반어/직함.
    private static let unsafeAliases: Set<String> = [
        "そら", "おじょ", "宮さん", "青くん", "あおくん", "助手くん", "中の人", "前世", "本体",
    ]

    /// 원형 + 가나 변형(히라가나↔가타카나). STT 표기 차이에도 매칭되게 한다.
    private static func kanaVariants(_ s: String) -> [String] {
        var out = [s]
        if let kata = s.applyingTransform(.hiraganaToKatakana, reverse: false), kata != s, !out.contains(kata) {
            out.append(kata)
        }
        if let hira = s.applyingTransform(.hiraganaToKatakana, reverse: true), hira != s, !out.contains(hira) {
            out.append(hira)
        }
        return out
    }

    /// 치환(replace)용 변형. 2글자 가타카나는 히라가나 변형을 만들지 않는다 —
    /// ココ→ここ(여기), メル→める(동사 어미)처럼 흔한 단어/문법과 충돌하기 때문.
    private static func replacementVariants(_ s: String) -> [String] {
        let allKatakana = s.unicodeScalars.allSatisfy { (0x30A0...0x30FF).contains($0.value) }
        if s.count == 2 && allKatakana { return [s] }
        return kanaVariants(s)
    }

    /// 별명을 치환에 써도 되는지: 3글자 이상이거나, 2글자이면서 카타카나만(과매칭 위험 낮음).
    private static func isSafeAlias(_ s: String) -> Bool {
        if Self.unsafeAliases.contains(s) { return false }
        if s.count >= 3 { return true }
        if s.count == 2 {
            return s.unicodeScalars.allSatisfy { (0x30A0...0x30FF).contains($0.value) }
        }
        return false
    }

    init(resourceName: String = "vtuber_glossary") {
        // 평가 하니스(CLI)에서는 번들 리소스가 없으므로 환경변수 경로를 우선 확인한다.
        let url: URL? = ProcessInfo.processInfo.environment["VTUBER_GLOSSARY_PATH"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: resourceName, withExtension: "json")
        guard let url,
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            nameReplacements = []
            slangReplacements = []
            nameVocabulary = []
            return
        }
        // 이름(고유명사)만 번역-전 치환에 쓴다. 슬랭/일반어는 과매칭·뜻풀이 문제로 제외.
        var map: [String: String] = [:]       // 이름 치환
        var vocab = Set<String>()
        for entry in file.entries where (entry.kind ?? "name") == "name" {
            let ko = entry.ko.trimmingCharacters(in: .whitespaces)
            guard !ko.isEmpty else { continue }

            // ── 번역 치환 맵: 정식 표기 + 안전한 별명 + 안전한 이름(given). 성씨는 제외(과매칭).
            var pairs: [(String, String)] = [(entry.jp.trimmingCharacters(in: .whitespaces), ko)]
            for alias in entry.aliases_jp ?? [] {
                let a = alias.trimmingCharacters(in: .whitespaces)
                if Self.isSafeAlias(a) { pairs.append((a, ko)) }
            }
            if let given = entry.given, Self.isSafeAlias(given.jp) {
                pairs.append((given.jp, given.ko))
            }
            // STT가 이름을 가타카나/히라가나 어느 쪽으로 받아쓸지 몰라 가나 변형도 함께 등록.
            for (form, value) in pairs where !form.isEmpty {
                for variant in Self.kanaVariants(form) where map[variant] == nil {
                    map[variant] = value
                }
            }

            // ── 커스텀 어휘: 이름 전체 + 성 + 이름 + 모든 별칭(2글자 이상). 과매칭 부담 없음.
            var forms = [entry.jp]
            if let surname = entry.surname { forms.append(surname.jp) }
            if let given = entry.given { forms.append(given.jp) }
            forms.append(contentsOf: entry.aliases_jp ?? [])
            for form in forms {
                let f = form.trimmingCharacters(in: .whitespaces)
                guard f.count >= 2 else { continue }
                for variant in Self.kanaVariants(f) { vocab.insert(variant) }
            }
        }
        // 슬랭/게임용어: 별도 JSON(vtuber_slang.json, 검증된 안전 치환만)에서 로드.
        // 2글자 가타카나는 히라가나 변형 금지(replacementVariants)로 과매칭 차단.
        var slangMap: [String: String] = [:]
        let slangURL = url.deletingLastPathComponent().appendingPathComponent("vtuber_slang.json")
        if let sdata = try? Data(contentsOf: slangURL),
           let slang = try? JSONDecoder().decode([SlangEntry].self, from: sdata) {
            for e in slang {
                let jp = e.jp.trimmingCharacters(in: .whitespaces)
                let ko = e.ko.trimmingCharacters(in: .whitespaces)
                guard !jp.isEmpty, !ko.isEmpty else { continue }
                for variant in Self.replacementVariants(jp) where slangMap[variant] == nil {
                    slangMap[variant] = ko
                }
            }
        }

        // 긴 형태부터 치환해야 "兎田ぺこら"가 "ぺこら"보다 먼저 잡힌다.
        nameReplacements = map.sorted { $0.key.count > $1.key.count }.map { ($0.key, $0.value) }
        slangReplacements = slangMap.sorted { $0.key.count > $1.key.count }.map { ($0.key, $0.value) }
        nameVocabulary = Array(vocab)
    }

    var isEmpty: Bool { nameReplacements.isEmpty && slangReplacements.isEmpty }

    /// 일본어 텍스트의 알려진 슬랭(+옵션으로 멤버 이름)을 한국어로 치환해 번역기에 넘길 형태로 만든다.
    /// - Parameter includeNames: "멤버 이름 부스팅"이 켜졌을 때만 이름을 치환한다(기본 false).
    func localize(_ text: String, includeNames: Bool = false) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for (jp, ko) in slangReplacements where result.contains(jp) {
            result = result.replacingOccurrences(of: jp, with: ko)
        }
        if includeNames {
            for (jp, ko) in nameReplacements where result.contains(jp) {
                result = result.replacingOccurrences(of: jp, with: ko)
            }
        }
        return result
    }
}
