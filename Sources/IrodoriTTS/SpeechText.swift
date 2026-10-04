import Foundation

/// Japanese speech formatting ported from Local AI. Formatting never rewrites kanji readings.
public enum SpeechText {
    private static func replace(_ text: String, _ pattern: String, _ replacement: String = " ") -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    public static func prepare(_ input: String) -> String {
        var text = markdown(input).trimmingCharacters(in: .whitespacesAndNewlines)
        text = replace(text, #"[#*_>\[\]]"#)
        text = replace(text, #"[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}]"#)
        text = replace(text, #"[\x{FE00}-\x{FE0F}\x{200D}]"#, "")
        text = replace(text, #"[\(（][^A-Za-z0-9\u3005-\u3007\u3040-\u30ff\u3400-\u9fff\uff10-\uff19\uff21-\uff3a\uff41-\uff5a\uff66-\uff9f]{0,24}[\)）]"#)
        text = replace(text, #"(?:(?:[:;=8xX][\-o\*']?[\)\]\(\[dDpP/:\}\{@\|\\])|(?:[\^;；][_\-o\.]?[\^;；])|(?:[Tt;；][_\-]?[Tt;；]))"#)
        text = replace(text, #"[~〜♪♡♥❤☆★※]+"#)
        text = replace(text, #"[「」『』【】\[\]]"#, "")
        text = replace(text, #"[()（）]"#, "、")
        text = replace(text, #"[、,]{2,}"#, "、")
        text = replace(text, #"[、,]*([。！？!?])[、,]*"#, "$1")
        text = replace(text, #"^[、,\s]+|[、,\s]+$"#, "")
        text = replace(text, #"[^A-Za-z0-9\u3005-\u3007\u3040-\u30ff\u3400-\u9fff\uff01-\uffef\s。、！？!?，,・ー\-+%&/'\.「」『』【】():;]"#)
        text = replace(text, #"\s+"#).trimmingCharacters(in: .whitespacesAndNewlines)
        text = replace(text, #"\s+([。、！？!?])"#, "$1")
        text = replace(text, #"([。、！？!?]){2,}"#, "$1")
        guard text.range(of: #"[A-Za-z0-9\u3040-\u30ff\u3400-\u9fff\uff10-\uff19\uff21-\uff3a\uff41-\uff5a\uff66-\uff9f]"#,
                         options: .regularExpression) != nil else { return "" }
        // Unlike the app's per-sentence sanitizer, this accepts a whole document.
        // Split/retry at model limits rather than silently truncating at 600 characters.
        return text
    }

    static func markdown(_ input: String) -> String {
        let chars = Array(input)
        var output = "", i = 0
        func starts(_ prefix: String, at index: Int) -> Bool {
            let p = Array(prefix)
            return index + p.count <= chars.count && Array(chars[index..<(index + p.count)]) == p
        }
        func find(_ needle: String, from start: Int) -> Int? {
            guard start < chars.count else { return nil }
            return (start..<chars.count).first { starts(needle, at: $0) }
        }
        while i < chars.count {
            if i == 0 || chars[i - 1] == "\n" {
                let rest = String(chars[i...])
                if let match = rest.range(of: #"^(?: {0,3}#{1,6}[ \t]+|[ \t]*[-+*][ \t]+)"#, options: .regularExpression) {
                    i += rest[match].count; continue
                }
            }
            if starts("```", at: i) {
                guard let end = find("```", from: i + 3) else { break }
                output += "\n"; i = end + 3; continue
            }
            if chars[i] == "`" {
                guard let end = find("`", from: i + 1) else { break }
                output += markdown(String(chars[(i + 1)..<end])); i = end + 1; continue
            }
            let label = starts("![", at: i) ? i + 1 : i
            if chars[label] == "[", let close = find("]", from: label + 1), close + 1 < chars.count,
               chars[close + 1] == "(" {
                var depth = 0, end = close + 1
                while end < chars.count {
                    if chars[end] == "\\" { end += 2; continue }
                    if chars[end] == "(" { depth += 1 }
                    if chars[end] == ")" { depth -= 1; if depth == 0 { break } }
                    end += 1
                }
                output += markdown(String(chars[(label + 1)..<close]))
                i = min(end + 1, chars.count); continue
            }
            let rest = String(chars[i...]).lowercased()
            if ["https://", "http://", "www."].contains(where: rest.hasPrefix) {
                let stops = Set(Array("<>「」『』【】（）\"'\n\r\t 。、！？"))
                var end = i, depth = 0
                while end < chars.count && !stops.contains(chars[end]) {
                    if chars[end] == "(" { depth += 1 }
                    if chars[end] == ")" { if depth == 0 { break }; depth -= 1 }
                    end += 1
                }
                var addressEnd = end
                while addressEnd > i && ".,;!".contains(chars[addressEnd - 1]) { addressEnd -= 1 }
                output += "リンク" + String(chars[addressEnd..<end]); i = end; continue
            }
            if starts("**", at: i) || starts("__", at: i) { i += 2; continue }
            output.append(chars[i]); i += 1
        }
        return output
    }

    public static func sentences(_ text: String) -> [String] {
        var result: [String] = [], current = ""
        for char in text {
            current.append(char)
            if "。！？!?\n".contains(char) {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(current) }
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(current) }
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func bisect(_ text: String) -> [String]? {
        let chars = Array(text)
        guard chars.count >= 8 else { return nil }
        let middle = chars.count / 2
        let candidates = (max(2, chars.count / 4)..<min(chars.count - 2, chars.count * 3 / 4))
            .filter { "、,;； ".contains(chars[$0]) }
        let split = candidates.min { abs($0 - middle) < abs($1 - middle) }.map { $0 + 1 } ?? middle
        return [String(chars[..<split]), String(chars[split...])]
    }
}
