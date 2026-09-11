import NaturalLanguage
import SwiftUI

/// Turns a task story — structured markdown from the synthesizer, or an older
/// single paragraph — into something scannable: a one-line summary for the
/// collapsed card, and headed sections with bullets and numbered steps when
/// the card is opened. Also scrubs the markdown/label debris a local model
/// sometimes leaks ("** Title", "STORY: …", "**SUMMARY**:").
enum StoryFormat {
    enum Block: Equatable {
        case heading(String)
        case bullet(String)
        case step(Int, String)
        case paragraph(String)
    }

    /// "TITLE:", "**Summary**:", "## STORY:" at the start of a line.
    private static let label = #/^[\s*#]*(?i:title|summary|story)\s*\**\s*:\s*/#
    /// "1. ", "2) ", "Step 3: "
    private static let step = #/^(?i:step\s+)?(\d{1,2})[.):]\s+(.+)$/#

    /// CRLF/CR → LF so every line split below sees real lines.
    static func normalise(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Strips a leaked label, "#" markers, a bold wrapper around the whole
    /// string (or a dangling one at either end), and wrapping quotes. Inner
    /// bold is left alone — the markdown renderer turns it into weight.
    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = t.firstMatch(of: label) { t = String(t[m.range.upperBound...]) }
        t = t.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("**"), t.hasSuffix("**"), t.count >= 4 {
            t = String(t.dropFirst(2).dropLast(2))
        } else if t.hasPrefix("**"), !t.dropFirst(2).contains("**") {
            t = String(t.dropFirst(2))                           // "** Title"
        } else if t.hasSuffix("**"), !t.dropLast(2).contains("**") {
            t = String(t.dropLast(2))                            // "Title **"
        }
        t = t.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") { t = String(t.dropFirst().dropLast()) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// For text rendered without markdown (titles, the card line): no "**" at all.
    static func plain(_ s: String) -> String {
        clean(s).replacingOccurrences(of: "**", with: "")
    }

    /// True when the text carries its own structure (headings, bullets or steps).
    static func isStructured(_ text: String) -> Bool {
        lines(text).contains { isHeading($0) || bulletBody($0) != nil || stepBody($0) != nil }
    }

    /// The one-liner for a collapsed card: a structured story's leading plain
    /// line, otherwise the first sentence or two, cut on a word. Empty when
    /// the story has nothing but headings.
    static func summary(_ text: String, limit: Int = 150) -> String {
        let ls = lines(text)
        var candidate: String
        if let first = ls.first, !isHeading(first), bulletBody(first) == nil, stepBody(first) == nil {
            candidate = plain(first)
        } else {
            candidate = ls.compactMap { l -> String? in
                if let b = bulletBody(l) { return b }
                if let s = stepBody(l) { return s.1 }
                return isHeading(l) ? nil : plain(l)
            }.first ?? ""
            candidate = candidate.replacingOccurrences(of: "**", with: "")
        }
        var out = ""
        for s in sentences(candidate) {
            if out.isEmpty { out = s } else if (out + " " + s).count <= limit { out += " " + s } else { break }
        }
        if out.count > limit {
            var cut = String(out.prefix(limit - 1))
            if let sp = cut.lastIndex(of: " ") { cut = String(cut[..<sp]) }
            out = cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:\u{2014}-")) + "\u{2026}"
        }
        return out
    }

    /// Blocks for the expanded view. An unstructured story becomes a
    /// "What happened" section with one bullet per sentence. The leading plain
    /// line is the card's summary and isn't repeated.
    static func blocks(_ text: String) -> [Block] {
        let ls = lines(text)
        if isStructured(text) {
            var out: [Block] = []
            for line in ls {
                if isHeading(line) { out.append(.heading(headingText(line))) }
                else if let b = bulletBody(line) { out.append(.bullet(b)) }
                else if let (n, s) = stepBody(line) { out.append(.step(n, s)) }
                else {
                    let p = clean(line)
                    if !p.isEmpty { out.append(.paragraph(p)) }
                }
            }
            if case .paragraph = out.first { out.removeFirst() }
            return out
        }
        let body = ls.count >= 2 ? ls.dropFirst().joined(separator: " ") : ls.first ?? ""
        let s = sentences(clean(body))
        guard !s.isEmpty else { return [] }
        return [.heading("\u{1F4CC} What happened")] + s.map { .bullet($0) }
    }

    // MARK: - Line classification

    /// Non-empty, trimmed lines.
    private static func lines(_ text: String) -> [String] {
        normalise(text).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !clean($0).isEmpty }
    }

    /// "# H", "**H**", "**H**:", "**H:**", or a short plain "Heading:" line.
    static func isHeading(_ line: String) -> Bool {
        var l = line.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("#") { return true }
        if bulletBody(l) != nil || stepBody(l) != nil { return false }
        if l.hasSuffix(":") { l = String(l.dropLast()).trimmingCharacters(in: .whitespaces) }
        if l.hasPrefix("**"), l.hasSuffix("**"), l.count > 4 {
            return !l.dropFirst(2).dropLast(2).contains("**")
        }
        // "What happened:" — a plain label line, not a sentence.
        return line.trimmingCharacters(in: .whitespaces).hasSuffix(":")
            && l.split(separator: " ").count <= 6
            && !l.contains(where: { ".!?,;".contains($0) })
    }

    /// Heading text without markers or a trailing colon.
    static func headingText(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix(":") { t = String(t.dropLast()) }
        t = plain(t)
        if t.hasSuffix(":") { t = String(t.dropLast()) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func bulletBody(_ line: String) -> String? {
        let l = line.trimmingCharacters(in: .whitespaces)
        for p in ["- ", "* ", "\u{2022} ", "\u{2013} ", "\u{2014} "] where l.hasPrefix(p) {
            let b = clean(String(l.dropFirst(p.count)))
            return b.isEmpty ? nil : b
        }
        return nil
    }

    static func stepBody(_ line: String) -> (Int, String)? {
        let l = line.trimmingCharacters(in: .whitespaces)
        guard let m = l.firstMatch(of: step) else { return nil }
        let body = clean(String(m.2))
        return body.isEmpty ? nil : (Int(m.1) ?? 0, body)
    }

    /// Sentence split that survives "e.g.", decimals and initials.
    static func sentences(_ text: String) -> [String] {
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        var out: [String] = []
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let s = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
            if s.count > 2 { out.append(s) }
            return true
        }
        return out
    }

    /// "High — reason" → ("High", "reason").
    static func level(_ automatable: String) -> (level: String, reason: String) {
        let parts = automatable.components(separatedBy: " \u{2014} ")
        let level = (parts.first ?? "Low").trimmingCharacters(in: .whitespaces)
        let reason = parts.dropFirst().joined(separator: " \u{2014} ").trimmingCharacters(in: .whitespaces)
        return (level.isEmpty ? "Low" : level, reason)
    }
}

/// Renders story blocks: bold headings, accent bullets, numbered steps, with
/// inline **bold** honoured.
struct StoryMarkdown: View {
    var blocks: [StoryFormat.Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                switch b {
                case .heading(let t):
                    Text(inline(t))
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, i == 0 ? 0 : 8)
                case .bullet(let t):
                    HStack(alignment: .top, spacing: 8) {
                        Text("\u{2022}").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent).frame(width: 10)
                        Text(inline(t)).font(.system(size: 12)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .step(let n, let t):
                    HStack(alignment: .top, spacing: 8) {
                        ZStack {
                            Circle().fill(Theme.accentDim)
                            Text("\(n)").font(.system(size: 9.5, weight: .bold)).numeric().foregroundStyle(Theme.accent)
                        }
                        .frame(width: 18, height: 18)
                        Text(inline(t)).font(.system(size: 12)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 1)
                    }
                case .paragraph(let t):
                    Text(inline(t)).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// LOW / MEDIUM / HIGH automatability pill.
struct LevelPill: View {
    var level: String
    private var color: Color {
        switch level.lowercased() {
        case "high": return Theme.good
        case "medium": return Theme.amber
        default: return Theme.ink3
        }
    }
    var body: some View {
        Text(level.uppercased())
            .font(.system(size: 10, weight: .bold)).tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(level.lowercased() == "low" ? Theme.panelHi : color.opacity(0.14)))
    }
}
