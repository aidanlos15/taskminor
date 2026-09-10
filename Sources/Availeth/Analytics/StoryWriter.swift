import Foundation

/// Writes the plain-English story layer: the record handed to the local text
/// model, the deterministic lines used when the model is not needed or not
/// trusted, and the checks that decide which.
///
/// Why it is built this way: a 3B model asked to "describe what was done" from
/// a window title and four counts either parrots the counts back ("used the
/// ⌘C×3 shortcut") or invents a purpose ("adjusted settings for a graphic
/// design project"). So the model is only asked to write when the record
/// carries something worth writing (fields, data moved between windows, screen
/// notes); it is shown the record in labelled plain words rather than symbols;
/// and its output is kept only if every proper noun and number in it comes from
/// the record. Anything else falls back to a line built from the record itself,
/// which can be dull but cannot be wrong.
enum StoryWriter {

    // MARK: - Words for keys and fields

    /// Shortcut tokens as the capture layer stores them, in the words a reader
    /// uses. A model shown "⌘C×3" writes "used the ⌘C×3 shortcut".
    static let keyWords: [String: String] = [
        "⌘C": "copy", "⌘V": "paste", "⌘X": "cut", "⌘A": "select all", "⌘S": "save", "⌘F": "find",
        "⌘Z": "undo", "⌘⇧Z": "redo", "⌘T": "new tab", "⌘W": "close", "⌘N": "new", "⌘P": "print",
        "⌘R": "reload", "⌘L": "address bar", "⌘Tab": "switch app", "⌘`": "switch window",
        "↵": "Enter", "⌫": "Delete", "Tab": "Tab", "⎋": "Escape",
        "↑": "arrow keys", "↓": "arrow keys", "←": "arrow keys", "→": "arrow keys",
        "⌘+": "zoom", "⌘-": "zoom", "⌘=": "zoom",
    ]

    static func keyWord(_ token: String) -> String {
        keyWords[token] ?? token.replacingOccurrences(of: "⌘", with: "Cmd+")
    }

    /// Distinct key words across stored shortcut blobs ("⌘C×2, ↵×4"), most used
    /// first. Counts are dropped on purpose: they are shown in the UI and a
    /// model given them narrates them.
    static func keyWordList(_ blobs: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for blob in blobs {
            for token in blob.split(separator: ",") {
                let t = token.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
                var name = t, n = 1
                if let x = t.lastIndex(of: "×"), let c = Int(t[t.index(after: x)...]) { name = String(t[..<x]); n = c }
                let w = keyWord(name)
                if counts[w] == nil { order.append(w) }
                counts[w, default: 0] += n
            }
        }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return order.sorted { (counts[$0]!, -rank[$0]!) > (counts[$1]!, -rank[$1]!) }
    }

    /// Field labels worth mentioning: the value-kind tag ("[identifier]") is
    /// dropped and browser chrome such as the address bar is skipped.
    static func cleanFields(_ blob: String) -> [String] {
        var out: [String] = []
        for token in blob.split(separator: ",") {
            guard let f = Evidence.cleanField(String(token)), !out.contains(f) else { continue }
            out.append(f)
        }
        return out
    }

    static func typingLevel(_ keys: Int) -> String {
        keys == 0 ? "none" : keys < 20 ? "light" : keys < 100 ? "moderate" : "heavy"
    }

    static func clickLevel(_ clicks: Int) -> String {
        clicks == 0 ? "none" : clicks < 5 ? "little" : clicks < 15 ? "some" : "a lot"
    }

    /// A window title as the record shows it: app suffix stripped, capped so a
    /// page's marketing strapline does not swamp the record.
    static func shortTitle(_ raw: String, app: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var t = Analytics.normalizeTitle(trimmed, appName: app)
        if t.count > 60 { t = String(t.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" }
        return t
    }

    static func joinAnd(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        }
    }

    static func timesWord(_ n: Int) -> String {
        n <= 1 ? "once" : n == 2 ? "twice" : n < 6 ? "several times" : "many times"
    }

    // MARK: - The minute record

    struct Window: Equatable {
        var app: String
        var title: String
        var fields: [String] = []
        var label: String { title.isEmpty ? app : "\(app) \"\(title)\"" }
    }

    struct MinuteRecord: Equatable {
        var windows: [Window] = []
        var keystrokes = 0
        var clicks = 0
        var keys: [String] = []
        var moves: [String] = []
        var sceneNotes: [String] = []

        var hasFields: Bool { windows.contains { !$0.fields.isEmpty } }

        /// Nothing beyond which windows were open and how much was typed. The
        /// model has nothing to add to that, so it is not asked.
        var isThin: Bool { !hasFields && moves.isEmpty && sceneNotes.isEmpty }

        /// The labelled record the model sees. The same text is what its output
        /// is checked against.
        var text: String {
            var lines: [String] = []
            let wins = windows.map { w in
                w.fields.isEmpty ? w.label : "\(w.label) (typed into fields: \(w.fields.prefix(6).joined(separator: ", ")))"
            }
            lines.append("Windows: " + (wins.isEmpty ? "none" : wins.joined(separator: "; ")))
            lines.append("Typing: \(StoryWriter.typingLevel(keystrokes)). Clicking: \(StoryWriter.clickLevel(clicks)).")
            lines.append("Keys: " + (keys.isEmpty ? "none" : keys.joined(separator: ", ")))
            lines.append("Data moved: " + (moves.isEmpty ? "none" : moves.joined(separator: "; ")))
            if !sceneNotes.isEmpty { lines.append("Screen notes: " + sceneNotes.prefix(6).joined(separator: " ")) }
            return lines.joined(separator: "\n")
        }
    }

    static func minuteRecord(spans: [ActivitySpan], transfers: [Transfer], narratives: [SceneNarrative]) -> MinuteRecord {
        var r = MinuteRecord()
        var index: [String: Int] = [:]
        for s in spans {
            let title = shortTitle(s.windowTitle, app: s.appName)
            let key = s.appName + "\u{1}" + title
            if index[key] == nil { index[key] = r.windows.count; r.windows.append(Window(app: s.appName, title: title)) }
            let i = index[key]!
            for f in cleanFields(s.fields) where !r.windows[i].fields.contains(f) { r.windows[i].fields.append(f) }
            r.keystrokes += s.keystrokes
            r.clicks += s.clicks
        }
        if r.windows.isEmpty {
            for n in narratives where !n.appName.isEmpty && !r.windows.contains(where: { $0.app == n.appName }) {
                r.windows.append(Window(app: n.appName, title: shortTitle(n.windowTitle, app: n.appName)))
            }
        }
        r.keys = keyWordList(spans.map(\.shortcuts))
        r.moves = moveLines(transfers)
        r.sceneNotes = narratives.map(\.text).filter { !$0.isEmpty }
        return r
    }

    /// One line per distinct route, with the field when one was in focus.
    static func moveLines(_ transfers: [Transfer]) -> [String] {
        var out: [String] = []
        for t in transfers where t.fromUnit != t.toUnit || t.fromApp != t.toApp {
            let from = Window(app: t.fromApp, title: shortTitle(t.fromTitle, app: t.fromApp)).label
            let to = Window(app: t.toApp, title: shortTitle(t.toTitle, app: t.toApp)).label
            var line = "\(from) to \(to)"
            if let f = Evidence.cleanField(t.toField) { line += ", into field \(f)" }
            if !out.contains(line) { out.append(line) }
        }
        return out
    }

    // MARK: - Deterministic lines

    /// The minute in one true sentence built only from the record. Used for
    /// every thin minute and whenever the model's entry fails its checks.
    static func plainEntry(_ r: MinuteRecord) -> String {
        var byApp: [(app: String, titles: [String])] = []
        for w in r.windows {
            if let i = byApp.firstIndex(where: { $0.app == w.app }) {
                if !w.title.isEmpty, !byApp[i].titles.contains(w.title) { byApp[i].titles.append(w.title) }
            } else {
                byApp.append((w.app, w.title.isEmpty ? [] : [w.title]))
            }
        }
        let places = byApp.prefix(3).map { $0.titles.isEmpty ? $0.app : "\($0.app) (\($0.titles.prefix(2).joined(separator: ", ")))" }
        let place = places.isEmpty ? "this Mac" : joinAnd(places)

        let verb: String
        switch typingLevel(r.keystrokes) {
        case "none": verb = r.clicks >= 5 ? "Clicked around in" : "Looked at"
        case "light": verb = "Worked briefly in"
        case "moderate": verb = "Worked in"
        default: verb = "Typed at length in"
        }
        var tail: [String] = []
        if r.keys.contains("copy") && r.keys.contains("paste") { tail.append("copying and pasting") }
        else if r.keys.contains("paste") { tail.append("pasting") }
        if r.keys.contains("find") { tail.append("searching") }
        if r.keys.contains("save") { tail.append("saving") }

        var s = "\(verb) \(place)"
        if !tail.isEmpty { s += ", " + tail.joined(separator: " and ") }
        s += "."
        let fieldWins = r.windows.filter { !$0.fields.isEmpty }
        if !fieldWins.isEmpty {
            s += " Typed into " + fieldWins.map { "\($0.fields.prefix(4).joined(separator: ", ")) in \($0.app)" }.joined(separator: "; ") + "."
        }
        if !r.moves.isEmpty { s += " Moved data from " + r.moves.prefix(3).joined(separator: "; ") + "." }
        return capStory(s)
    }

    // MARK: - The minute prompt

    /// Stops keep a few-shot model from writing a fourth "Example record".
    static let minuteStops = ["\nRecord", "\nExample", "\nEntry:"]

    static func minutePrompt(_ r: MinuteRecord) -> String {
        """
        Turn the record below into one short log entry, as in the examples.

        Rules:
        1. Start with a verb. Do not name the person working and do not write "the user" or "the employee".
        2. State only what the record shows. Never add a reason, a goal, or a project that is not in the record.
        3. Only say that something was copied, pasted, or moved from one window to another if the "Data moved" line says so.
        4. Write one sentence if the record has only windows and typing. Write up to three if it has fields, data moved, or screen notes.
        5. Do not write numbers or key names. Use the typing and clicking levels only to choose wording.
        6. Window titles may be cut short. Do not complete or explain them.
        7. A personal name in a title or field is the subject of a record on screen, never the person working.

        Example record
        Windows: Microsoft Excel "Purchase Orders.xlsx"; Google Chrome "Vendor Bills - NetSuite" (typed into fields: Invoice Number, Amount)
        Typing: heavy. Clicking: some.
        Keys: copy, paste, Tab
        Data moved: Microsoft Excel "Purchase Orders.xlsx" to Google Chrome "Vendor Bills - NetSuite", into field Invoice Number
        Entry: Copied a purchase order reference from Purchase Orders.xlsx into the Invoice Number field of a vendor bill in NetSuite, then typed the Amount.

        Example record
        Windows: Code "main.swift - taskminor"; Safari "New chat - Claude"
        Typing: heavy. Clicking: little.
        Keys: Delete, Enter, paste
        Data moved: none
        Entry: Edited main.swift in Code and typed in a Claude chat in Safari.

        Example record
        Windows: Microsoft Outlook "RE: Dana Whitfield - August timesheet" (typed into fields: To Recipients, Subject)
        Typing: moderate. Clicking: some.
        Keys: Enter
        Data moved: none
        Entry: Wrote an email in Outlook on the thread about Dana Whitfield's August timesheet, filling in the recipients and subject.

        Record
        \(r.text)
        Entry:
        """
    }

    /// The model's entry if it passes every check, else nil.
    static func acceptEntry(_ raw: String?, record: MinuteRecord) -> String? {
        guard let raw else { return nil }
        let entry = Check.tidy(raw, maxSentences: 3)
        guard !entry.isEmpty, Check.entryProblems(entry, record: record.text, hasMoves: !record.moves.isEmpty).isEmpty else { return nil }
        return entry
    }

    // MARK: - The task record

    struct TaskRecord {
        var text: String
        var apps: [String]
        var topWindow: Window?
        var moves: [String]
        var lengthWords: String
        var fields: [String]
        var keys: [String]
        var minuteCount: Int
        var keystrokes: Int
        /// Windows ranked by minutes seen, with their share words.
        var ranked: [(window: Window, share: String)]
        /// What the local vision model saw on screen during this task, newest
        /// first: the first sentence of each of the last few narratives.
        var sceneNotes: [String] = []
    }

    /// The first sentence of a narrative, trimmed and closed with a full stop.
    static func firstSentence(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        var out = text
        if let stop = text.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            out = String(text[...stop])
        }
        out = out.trimmingCharacters(in: .whitespaces)
        if let last = out.last, last != "." && last != "!" && last != "?" { out += "." }
        return out
    }

    /// The newest few screen notes, one sentence each, with repeats dropped.
    static func sceneNotes(_ narratives: [SceneNarrative], limit: Int = 3) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for n in narratives.sorted(by: { $0.timestamp > $1.timestamp }) {
            let line = firstSentence(n.text)
            guard !line.isEmpty else { continue }
            let key = line.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(line)
            if out.count == limit { break }
        }
        return out
    }

    /// Task cards are read at a glance, so a story stops at roughly 500
    /// characters, on a sentence boundary where there is one.
    static func capStory(_ text: String, limit: Int = 500) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let stop = head.lastIndex(of: "."), head.distance(from: head.startIndex, to: stop) > limit / 3 {
            return String(head[...stop])
        }
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func lengthWords(minutes n: Int) -> String {
        n < 4 ? "a couple of minutes" : n < 10 ? "a few minutes" : n < 22 ? "about a quarter of an hour"
            : n < 40 ? "about half an hour" : "the best part of an hour"
    }

    static func taskRecord(minutes: [MinuteSummary], transfers: [Transfer], narratives: [SceneNarrative] = []) -> TaskRecord {
        var minutesSeen: [String: Int] = [:]
        var windows: [String: Window] = [:]
        var order: [String] = []
        var apps: [String] = []
        var keystrokes = 0, clicks = 0
        for m in minutes {
            keystrokes += m.keystrokes; clicks += m.clicks
            var seenThisMinute = Set<String>()
            for label in AppList.parse(m.apps) {
                let parts = label.components(separatedBy: " — ")
                let app = parts[0]
                let title = parts.count > 1 ? shortTitle(parts[1...].joined(separator: " — "), app: app) : ""
                let key = app + "\u{1}" + title
                if windows[key] == nil { windows[key] = Window(app: app, title: title); order.append(key) }
                if !apps.contains(app) { apps.append(app) }
                if seenThisMinute.insert(key).inserted { minutesSeen[key, default: 0] += 1 }
            }
        }
        let n = max(minutes.count, 1)
        let ranked = order.sorted { minutesSeen[$0]! > minutesSeen[$1]! }.prefix(8).map { key -> (window: Window, share: String) in
            let share = Double(minutesSeen[key]!) / Double(n)
            return (windows[key]!, share >= 0.6 ? "most of the time" : share >= 0.25 ? "part of the time" : "briefly")
        }
        let fields = cleanFields(minutes.map(\.fields).joined(separator: ", "))
        let keys = keyWordList(minutes.map(\.shortcuts))

        var moveCounts: [String: Int] = [:]
        var moveOrder: [String] = []
        for line in transfers.flatMap({ moveLines([$0]) }) {
            if moveCounts[line] == nil { moveOrder.append(line) }
            moveCounts[line, default: 0] += 1
        }
        let moves = moveOrder.map { "\($0) (\(timesWord(moveCounts[$0]!)))" }

        // Consecutive identical entries collapse, so forty "Worked in Code"
        // lines read as one line with a count.
        var entries: [(text: String, count: Int)] = []
        for m in minutes where !m.text.isEmpty {
            if let last = entries.last, last.text == m.text { entries[entries.count - 1].count += 1 }
            else { entries.append((m.text, 1)) }
        }
        let entryLines = entries.map { "- \($0.text)" + ($0.count > 1 ? " (repeated \(timesWord($0.count)))" : "") }

        let notes = sceneNotes(narratives)

        let length = lengthWords(minutes: minutes.count)
        var lines = ["Length: \(length)"]
        lines.append("Windows: " + (ranked.isEmpty ? "none" : ranked.map { "\($0.window.label) (\($0.share))" }.joined(separator: "; ")))
        if !fields.isEmpty { lines.append("Fields typed into: " + fields.prefix(8).joined(separator: ", ")) }
        lines.append("Typing: \(typingLevel(keystrokes / n)) overall. Clicking: \(clickLevel(clicks / n)) overall.")
        lines.append("Keys: " + (keys.isEmpty ? "none" : keys.joined(separator: ", ")))
        lines.append("Data moved: " + (moves.isEmpty ? "none" : moves.joined(separator: "; ")))
        if !notes.isEmpty {
            lines.append("What the screen showed, newest first:")
            lines.append(contentsOf: notes.map { "- \($0)" })
        }
        lines.append("Minute entries, in order:")
        lines.append(contentsOf: entryLines.prefix(45))

        return TaskRecord(text: lines.joined(separator: "\n"), apps: apps, topWindow: ranked.first?.window,
                          moves: moves, lengthWords: length, fields: fields, keys: keys, minuteCount: minutes.count,
                          keystrokes: keystrokes, ranked: Array(ranked), sceneNotes: notes)
    }

    // MARK: - The task prompt

    static let taskStops = ["\nRecord", "\nExample"]

    static func taskPrompt(_ r: TaskRecord) -> String {
        """
        Write a work-log account of one task from the record below, then a title, as in the example.

        Rules:
        1. Start each sentence with a verb. Do not name the person working and do not write "the user" or "the employee".
        2. State only what the record shows. Never add a reason, a goal, or a project that is not in the record.
        3. Only say that something was copied, pasted, or moved from one window to another if the "Data moved" line says so.
        4. If the record has a "What the screen showed" section, say what was done there in the first sentence, naming the thing that was pasted or typed and where it went.
        5. Write two to four sentences in your own words covering the whole task in order, using the time shares in the Windows line. Do not copy the minute entries and do not write numbers or key names.
        6. Reply with two lines: first "STORY:" then the sentences, then "TITLE:" then the title.
        7. The title is three to six words naming the work itself, for example "Vendor bill entry from purchase orders". It must not contain the words automation, management, workflow, task, process, activity, session or work, and no personal name.

        Example record
        Length: about a quarter of an hour
        Windows: Microsoft Excel "Purchase Orders.xlsx" (part of the time); Google Chrome "Vendor Bills - NetSuite" (most of the time)
        Fields typed into: Invoice Number, Amount, Memo
        Typing: moderate overall. Clicking: some overall.
        Keys: copy, paste, Tab, find
        Data moved: Microsoft Excel "Purchase Orders.xlsx" to Google Chrome "Vendor Bills - NetSuite", into field Invoice Number (several times)
        Minute entries, in order:
        - Searched Purchase Orders.xlsx in Excel.
        - Copied a purchase order reference from Purchase Orders.xlsx into the Invoice Number field of a vendor bill in NetSuite, then typed the Amount. (repeated several times)
        - Typed a Memo on the vendor bill in NetSuite.
        STORY: Spent most of the time entering vendor bills in NetSuite, with Purchase Orders.xlsx open in Excel alongside. Looked up each purchase order in the spreadsheet, copied its reference into the Invoice Number field, typed the Amount and added a Memo.
        TITLE: Vendor bill entry from purchase orders

        Record
        \(r.text)
        """
    }

    /// A true account of the task built only from the record, for when there is
    /// no model or its story failed its checks.
    static func plainStory(_ r: TaskRecord) -> String {
        // What the screen showed beats a count of keystrokes, so the notes lead
        // and the structure sentence follows as the backing detail. With no
        // notes the structure sentence is the whole story, as it always was.
        var s = ""
        if !r.sceneNotes.isEmpty { s = r.sceneNotes.joined(separator: " ") + " " }
        s += r.lengthWords.prefix(1).uppercased() + r.lengthWords.dropFirst()
        if let top = r.ranked.first {
            s += ", mostly in \(top.window.label)"
            let rest = r.ranked.dropFirst().prefix(3).map(\.window.label)
            if !rest.isEmpty { s += ", also " + joinAnd(rest) }
        } else {
            s += " on this Mac"
        }
        s += "."
        var typing = "Typing \(typingLevel(r.keystrokes / max(r.minuteCount, 1)))"
        if r.keys.contains("copy") && r.keys.contains("paste") { typing += ", copying and pasting" }
        if r.keys.contains("find") { typing += ", searching" }
        s += " \(typing)."
        if !r.fields.isEmpty { s += " Typed into " + joinAnd(Array(r.fields.prefix(5))) + "." }
        if !r.moves.isEmpty { s += " Moved data from " + r.moves.prefix(3).joined(separator: "; ") + "." }
        return capStory(s)
    }

    /// A title that names the place of the work when the model gave none worth
    /// keeping: the app and its main window, or the apps involved.
    static func plainTitle(apps: [String], topWindow: Window? = nil) -> String {
        if apps.count <= 1, let top = topWindow ?? apps.first.map({ Window(app: $0, title: "") }) {
            guard !top.title.isEmpty else { return top.app.isEmpty ? "Work on this Mac" : top.app }
            let t = top.title.count > 32 ? String(top.title.prefix(31)).trimmingCharacters(in: .whitespaces) + "…" : top.title
            return "\(top.app) · \(t)"
        }
        if apps.isEmpty { return "Work on this Mac" }
        return joinAnd(Array(apps.prefix(3)))
    }

    /// The model's title and story, each kept only if it passes its checks.
    static func acceptTitleAndStory(_ raw: String?, record: TaskRecord) -> (title: String, story: String) {
        let fallbackTitle = plainTitle(apps: record.apps, topWindow: record.topWindow)
        let fallbackStory = plainStory(record)
        let (t, s) = Synthesizer.parseTitleAndStory(raw, fallbackApps: record.apps, fallbackStory: fallbackStory)
        let story = capStory(Check.tidy(s, maxSentences: 5))
        let storyOK = !story.isEmpty && story != fallbackStory
            && Check.entryProblems(story, record: record.text, hasMoves: !record.moves.isEmpty).isEmpty
        let title = Check.tidyTitle(t)
        let titleOK = !title.isEmpty && Check.titleProblems(title, record: record.text).isEmpty
        return (titleOK ? title : fallbackTitle, storyOK ? story : fallbackStory)
    }

    // MARK: - Where a job ends

    /// The job so far and the minutes that follow, in words, with one question.
    /// The model answers SAME or NEW. Kept tiny so it can be asked at every
    /// turnover without slowing capture.
    static func boundaryPrompt(episode: [MinuteSummary], next: [MinuteSummary]) -> String {
        let r = taskRecord(minutes: episode, transfers: [])
        var soFar = r.lengthWords
        if !r.ranked.isEmpty { soFar += "; " + r.ranked.prefix(5).map { "\($0.window.label) (\($0.share))" }.joined(separator: "; ") }
        if !r.fields.isEmpty { soFar += "; fields: " + r.fields.prefix(5).joined(separator: ", ") }
        let then = next.map { $0.text.isEmpty ? "Worked on this Mac." : $0.text }.joined(separator: " / ")
        return """
        Decide whether a person has moved on to a different job. Reply with one word: SAME or NEW.

        SAME means the minutes that follow are part of the job so far, even if a different window is used for it: looking something up, replying to a message, a quick check.
        NEW means a different job has started: different windows for a different purpose, with no return to the job so far.

        Example
        Job so far: about a quarter of an hour; Google Chrome "Vendor Bills - NetSuite" (most of the time); Microsoft Excel "Purchase Orders.xlsx" (part of the time); fields: Invoice Number, Amount
        Then: Worked briefly in Microsoft Outlook (Inbox). / Worked in Google Chrome (Vendor Bills - NetSuite), copying and pasting. / Worked in Microsoft Excel (Purchase Orders.xlsx).
        Answer: SAME

        Example
        Job so far: about half an hour; Google Chrome "Vendor Bills - NetSuite" (most of the time); Microsoft Excel "Purchase Orders.xlsx" (part of the time); fields: Invoice Number, Amount
        Then: Typed at length in Microsoft Word (Site safety plan.docx). / Typed at length in Microsoft Word (Site safety plan.docx). / Worked in Safari (Procore).
        Answer: NEW

        Job so far: \(soFar)
        Then: \(then)
        Answer:
        """
    }

    /// true = a new job started, false = the same job continues, nil = no answer.
    static func parseBoundary(_ raw: String) -> Bool? {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if word.hasPrefix("NEW") { return true }
        if word.hasPrefix("SAME") { return false }
        return nil
    }

    // MARK: - Checks

    enum Check {
        /// Words that may be capitalised without appearing in the record.
        static let allowed: Set<String> = ["enter", "delete", "tab", "escape", "cmd", "vs", "mac", "pdf", "url", "ai", "i", "also", "then"]
        static let bannedTitleWords: Set<String> = ["automation", "automations", "automated", "management", "workflow", "workflows",
                                                    "task", "tasks", "process", "processes", "activity", "activities",
                                                    "session", "sessions", "work"]

        static func sentences(_ s: String) -> [String] {
            var out: [String] = []
            var current = ""
            for ch in s {
                current.append(ch)
                if ".!?".contains(ch) { out.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            }
            let tail = current.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { out.append(tail) }
            return out.filter { !$0.isEmpty }
        }

        /// Strips labels and the openers a chat model adds, and caps the length.
        static func tidy(_ raw: String, maxSentences: Int) -> String {
            var s = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            for label in ["Entry:", "STORY:", "Story:"] where s.hasPrefix(label) { s = String(s.dropFirst(label.count)) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            for opener in ["This minute, ", "In this minute, ", "During this minute, ", "The user ", "The employee "] where s.hasPrefix(opener) {
                s = String(s.dropFirst(opener.count))
                s = s.prefix(1).uppercased() + s.dropFirst()
            }
            s = s.replacingOccurrences(of: "  ", with: " ")
            let sents = sentences(s)
            if sents.count > maxSentences { s = sents.prefix(maxSentences).joined(separator: " ") }
            return s
        }

        static func tidyTitle(_ raw: String) -> String {
            var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”.*"))
            if t.hasSuffix(".") { t.removeLast() }
            return t
        }

        static func words(_ s: String) -> [String] {
            var out: [String] = []
            var current = ""
            for ch in s {
                if ch.isLetter || ch.isNumber || (!current.isEmpty && ".'’-".contains(ch)) { current.append(ch) }
                else if !current.isEmpty { out.append(current); current = "" }
            }
            if !current.isEmpty { out.append(current) }
            return out.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".'’-")) }.filter { !$0.isEmpty }
        }

        static func core(_ word: String) -> String {
            var w = word
            for suffix in ["’s", "'s"] where w.hasSuffix(suffix) { w = String(w.dropLast(suffix.count)) }
            return w
        }

        /// Reasons a model entry cannot be trusted; empty when it can. Every
        /// capitalised word, number and cross-window claim must be in the record.
        static func entryProblems(_ out: String, record: String, hasMoves: Bool) -> [String] {
            var problems: [String] = []
            let low = out.lowercased()
            let recordLow = record.lowercased()
            for phrase in ["the user", "the employee", "this minute", "employee"] where containsWord(low, phrase) {
                problems.append("names the person (\"\(phrase)\")"); break
            }
            for number in numbers(in: out) where !record.contains(number) {
                problems.append("number \(number) not in record"); break
            }
            if !hasMoves {
                for verb in ["copied", "pasted", "moved", "transferred"] where containsWord(low, verb) {
                    let sentence = sentences(low).first { containsWord($0, verb) } ?? ""
                    if containsWord(sentence, "from") || sentence.contains("between") {
                        problems.append("claims data moved between windows"); break
                    }
                }
            }
            for prefix in cutTitles(in: record) where completes(prefix, in: out) {
                problems.append("completes the cut title \"\(prefix)…\""); break
            }
            if mangledDot(in: out) { problems.append("splits a name at a full stop") }
            for sentence in sentences(out) {
                let ws = words(sentence)
                for (i, w) in ws.enumerated() where i > 0 && w.first!.isUppercase {
                    let c = core(w)
                    guard !allowed.contains(c.lowercased()), !recordLow.contains(c.lowercased()) else { continue }
                    problems.append("\"\(c)\" is not in the record")
                    return problems
                }
            }
            return problems
        }

        static func titleProblems(_ title: String, record: String) -> [String] {
            var problems: [String] = []
            let ws = words(title)
            if ws.count < 2 || ws.count > 7 { problems.append("\(ws.count) words") }
            if ws.contains(where: { bannedTitleWords.contains($0.lowercased()) }) { problems.append("banned word") }
            let recordLow = record.lowercased()
            for (i, w) in ws.enumerated() where i > 0 && w.first!.isUppercase {
                let c = core(w)
                if !allowed.contains(c.lowercased()), !recordLow.contains(c.lowercased()) { problems.append("\"\(c)\" is not in the record"); break }
            }
            return problems
        }

        static func containsWord(_ text: String, _ word: String) -> Bool {
            guard let r = text.range(of: word) else { return false }
            var found = r
            while true {
                let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
                let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
                if !(before?.isLetter ?? false) && !(after?.isLetter ?? false) { return true }
                guard let next = text.range(of: word, range: found.upperBound..<text.endIndex) else { return false }
                found = next
            }
        }

        /// ". a" inside a sentence: the model has broken "Stampede.ai" into
        /// "Stampede. ai". A real sentence never starts with a lowercase letter.
        static func mangledDot(in s: String) -> Bool {
            var previous: Character = " ", beforeThat: Character = " "
            for ch in s {
                if previous == " ", beforeThat == ".", ch.isLowercase { return true }
                beforeThat = previous; previous = ch
            }
            return false
        }

        static func numbers(in s: String) -> [String] {
            var out: [String] = []
            var current = ""
            for ch in s {
                if ch.isNumber { current.append(ch) } else if !current.isEmpty { out.append(current); current = "" }
            }
            if !current.isEmpty { out.append(current) }
            return out
        }

        /// The text before each "…" inside a quoted title in the record. The
        /// cut is usually mid-title ("Stampede.ai graphics ren… — astra"),
        /// so the prefix is taken up to the first ellipsis, not the end.
        static func cutTitles(in record: String) -> [String] {
            var out: [String] = []
            for part in record.split(separator: "\"") {
                guard let dots = part.firstIndex(of: "…") else { continue }
                let prefix = String(part[..<dots])
                if prefix.count >= 4, !out.contains(prefix) { out.append(prefix) }
            }
            return out
        }

        /// True when the output continues a cut title with more letters.
        static func completes(_ prefix: String, in out: String) -> Bool {
            var search = out.startIndex
            while let r = out.range(of: prefix, range: search..<out.endIndex) {
                if r.upperBound < out.endIndex, out[r.upperBound].isLetter { return true }
                search = r.upperBound
            }
            return false
        }
    }
}
