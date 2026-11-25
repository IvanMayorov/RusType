import Foundation

struct Rule: Codable, Identifiable {
    var id = UUID()
    var heard: String
    var written: String
}

enum Dictation {
    static func prepare(_ raw: String, rules: [Rule]) -> String {
        let boundary = #"[\p{L}\p{M}\p{N}_-]"#
        let filler = #"(?i)(?<![\p{L}\p{M}\p{N}_‑-])(?:э(?:[-‑]э)+|э{3,})(?![\p{L}\p{M}\p{N}_‑-])"#
        var text = raw.replacingOccurrences(of: #"(?:,[ \t]*)?"# + filler + #"[ \t]*(?:,[ \t]*)?"#, with: " ", options: .regularExpression)
        if text != raw {
            text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #" +(?=[.,!?…])"#, with: "", options: .regularExpression)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.last == ".", !text.hasSuffix("..") { text.removeLast() }
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        var replacements = [String: String]()
        for rule in rules where !rule.heard.isEmpty { replacements[rule.heard.lowercased()] = rule.written }
        let keys = replacements.keys.sorted { $0.count > $1.count }
        if !keys.isEmpty {
            let alternatives = keys.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            let regex = try! NSRegularExpression(pattern: "(?<!"+boundary+")(?:"+alternatives+")(?!"+boundary+")", options: .caseInsensitive)
            let output = NSMutableString(string: text)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                let key = (text as NSString).substring(with: match.range).lowercased()
                if let replacement = replacements[key] { output.replaceCharacters(in: match.range, with: replacement) }
            }
            text = output as String
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + " "
    }

    /// Adapts a prepared phrase to the text before the caret: continue in lowercase mid-sentence.
    /// `prefix == nil` means the context is unknown, so the phrase is left as is.
    static func fit(_ text: String, after prefix: String?) -> String {
        guard let prefix, let first = text.first else { return text }
        guard let lastChar = prefix.last, !lastChar.isNewline else { return text }
        let trailing = prefix.reversed().prefix { $0.isWhitespace }
        if trailing.contains(where: { $0.isNewline }) { return text }
        // Look through closing quotes and brackets: «Готово.» / (см. выше.)
        var meaningful = prefix.trimmingCharacters(in: .whitespaces)
        while let last = meaningful.last, "\"'»”’)]}".contains(last) { meaningful.removeLast() }
        guard let last = meaningful.last else { return text }
        let space = !lastChar.isWhitespace && !first.isPunctuation && !"([{«“„/".contains(lastChar) ? " " : ""
        if ".!?…".contains(last) { return space + text }
        var result = text
        let second = text.dropFirst().first
        if first.isUppercase, second?.isUppercase != true {
            result = first.lowercased() + text.dropFirst()
        }
        return space + result
    }

    static func recognize(_ wav: URL) throws -> String {
        let resources = Bundle.main.resourceURL!
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: result) }
        let worker = Process()
        worker.executableURL = resources.appendingPathComponent("transcribe-cli")
        worker.arguments = ["-q", "-m", resources.appendingPathComponent("gigaam.gguf").path,
                            "--timestamps", "none", "-o", result.path, wav.path]
        worker.standardOutput = FileHandle.nullDevice
        worker.standardError = FileHandle.nullDevice
        try worker.run()
        worker.waitUntilExit()
        guard worker.terminationStatus == 0 else { throw NSError(domain: "Распознавание", code: Int(worker.terminationStatus)) }
        return try String(contentsOf: result, encoding: .utf8)
    }
}
