import AVFoundation
import Foundation

/// "Export automations": writes everything Availeth judged automatable — and
/// only that — to a dated folder on the Desktop, so the user can hand it over
/// knowing exactly what is in it. Per workflow and per High/Medium task: a
/// readable summary, the structured data, the captured descriptions, the
/// frames still on disk, and the stitched recording. Progress is published
/// for the sidebar.
final class AutomationExporter: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    @Published private(set) var lastExport: URL?
    @Published private(set) var error: String?

    @MainActor
    func run(store: Store, hourlyRate: Double) {
        guard !isRunning else { return }
        isRunning = true; progress = 0; status = "Finding automatable work\u{2026}"; error = nil; lastExport = nil
        let job = ExportJob(store: store, hourlyRate: hourlyRate)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let url = try await job.run { p, s in
                    await MainActor.run { self?.progress = p; self?.status = s }
                }
                await MainActor.run {
                    self?.progress = 1; self?.status = "Exported"; self?.lastExport = url; self?.isRunning = false
                }
            } catch {
                await MainActor.run {
                    self?.error = error.localizedDescription; self?.status = ""; self?.isRunning = false
                }
            }
        }
    }

    @MainActor
    func clearResult() { lastExport = nil; error = nil; status = "" }
}

/// The export itself: pure file work off the main thread.
struct ExportJob {
    var store: Store
    var hourlyRate: Double
    var days = 14
    var now = Date()
    var desktop: URL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]

    typealias Progress = (Double, String) async -> Void

    /// "Availeth Data 2026-09-12", then " (2)", " (3)" if that exists.
    static func folderURL(in base: URL, date: Date, fileManager: FileManager = .default) -> URL {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let name = "Availeth Data \(f.string(from: date))"
        var url = base.appendingPathComponent(name, isDirectory: true), n = 2
        while fileManager.fileExists(atPath: url.path) {
            url = base.appendingPathComponent("\(name) (\(n))", isDirectory: true); n += 1
        }
        return url
    }

    static func safeName(_ s: String, max: Int = 60) -> String {
        var t = s.replacingOccurrences(of: #"[/:\\?%*|"<>]"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > max { t = String(t.prefix(max)).trimmingCharacters(in: .whitespaces) }
        return t.isEmpty ? "Untitled" : t
    }

    func run(progress: @escaping Progress) async throws -> URL {
        let from = now.addingTimeInterval(-Double(days) * 86400), to = now.addingTimeInterval(60)
        let spans = store.spans(from: from, to: to, demo: false)
        let opps = store.opportunities(demo: false)
        func worthIt(_ o: Opportunity?) -> Bool { o?.kind == .customApp || o?.kind == .integration }
        // Automatable by the evidence, OR judged worth building/automating by the model.
        let insights = PatternMiner.mine(spans: spans)
            .map { WorkflowInsighter.build($0, store: store, demo: false) }
            .filter { $0.automatable || worthIt(opps["wf:" + $0.pattern.id]) }
            .sorted { $0.pattern.automationScore > $1.pattern.automationScore }
        let tasks = store.taskSummaries(from: from, to: to, demo: false)
            .filter { $0.automatable.hasPrefix("High") || $0.automatable.hasPrefix("Medium") || worthIt(opps["task:\($0.id)"]) }
            .sorted { $0.start < $1.start }
        let segments = store.recordings(from: from, to: to)
        guard !insights.isEmpty || !tasks.isEmpty else {
            throw NSError(domain: "Availeth", code: 10, userInfo: [NSLocalizedDescriptionKey: "Nothing automatable to export yet \u{2014} give Availeth a few repeated tasks first."])
        }

        // Built in a private folder and moved onto the Desktop only when
        // complete — a failure never leaves a half-written export behind.
        let final = Self.folderURL(in: desktop, date: now)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("availeth-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Recordings.beginReading()
        defer { Recordings.endReading(); try? FileManager.default.removeItem(at: folder) }

        // The recorded pieces, cut once, so the progress weights and the
        // exported clips agree: a run without a recording weighs nothing extra.
        let runParts: [[(Int, [Recordings.ClipPart])]] = insights.map { ins in
            ins.pattern.windows.enumerated().compactMap { j, w in
                let p = Recordings.clipParts(for: DateInterval(start: w.start, end: w.end).padded, segments: segments)
                return p.isEmpty ? nil : (j, p)
            }
        }
        let taskParts: [[Recordings.ClipPart]] = tasks.map { Recordings.clipParts(for: DateInterval(start: $0.start, end: max($0.start, $0.end)).padded, segments: segments) }
        let total = 1 + runParts.reduce(0.0) { $0 + 1 + ($1.isEmpty ? 0 : 6) } + taskParts.reduce(0.0) { $0 + 1 + ($1.isEmpty ? 0 : 6) }
        var done = 0.0
        func report(_ s: String) async { await progress(min(0.99, done / total), s) }

        try Self.readme(insights: insights, tasks: tasks, opportunities: opps, from: from, to: now, rate: hourlyRate)
            .write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        done += 1
        var manifest: [String: Any] = [
            "exportedAt": Self.iso(now), "from": Self.iso(from), "to": Self.iso(now), "hourlyRate": hourlyRate,
            "recording": ["fps": ScreenRecorder.fps, "quality": ScreenRecorder.quality, "maxWidth": ScreenRecorder.maxWidth,
                          "note": "Clips are constant-rate HEVC .mov. When a run has a clip (tBasis = clip), `t` in events.jsonl is seconds into that clip; an instant that fell in a recording gap has no `t` and `recorded: false`. Without a clip (tBasis = wall), `t` is seconds from the run's start. Click x/y are points from the top-left of `display`; scale by clipPixels.width / display.pointsWidth to land on the clip."],
            "eventKinds": ["focus (a window came to the front; duration = wall seconds, tEnd = clip time it left; fields/shortcuts = what was typed into/used there)",
                           "scene (what the local vision model saw)", "note (minute summary)",
                           "copy/cut/paste/save (keyboard shortcut; label = focused field)", "commit (Tab, or Enter in a labelled field, after typing; label = field)",
                           "click (x, y in points from the top-left of `display`; label = right/middle for other buttons)",
                           "typing (count of keystrokes in a burst; never the keys)", "away (idle stretch; duration in s)"],
        ]
        var manifestWorkflows: [[String: Any]] = []
        var manifestTasks: [[String: Any]] = []

        for (i, insight) in insights.enumerated() {
            let name = String(format: "%02d - %@", i + 1, Self.safeName(insight.title))
            let dir = folder.appendingPathComponent("Workflows/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            await report("Workflow \(i + 1) of \(insights.count): \(insight.title)")
            let opp = opps["wf:" + insight.pattern.id]
            try Self.workflowMarkdown(insight, opportunity: opp, rate: hourlyRate).write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try Self.workflowJSON(insight, opportunity: opp, rate: hourlyRate).write(to: dir.appendingPathComponent("workflow.json"))
            let moments = allMoments(for: insight)
            try Self.momentsMarkdown(moments).write(to: dir.appendingPathComponent("moments.md"), atomically: true, encoding: .utf8)
            copyFrames(moments, into: dir.appendingPathComponent("frames", isDirectory: true))
            // The time-aligned track and storyboard, one per run. Each run's
            // clip is stitched ONCE here and reused for the video export below.
            var runsManifest: [[String: Any]] = []
            var builtClips: [Int: Recordings.Clip] = [:]
            let recorded = Dictionary(uniqueKeysWithValues: runParts[i])
            for (j, w) in insight.pattern.windows.enumerated() {
                let iv = DateInterval(start: w.start, end: w.end).padded
                let built: Recordings.Clip? = recorded[j] == nil ? nil : await Recordings.clip(recorded[j]!)
                if let built { builtClips[j] = built }
                let events = ExportTimeline.events(interval: iv, spans: store.spans(from: iv.start, to: iv.end, demo: false),
                                                   narratives: store.narratives(from: iv.start, to: iv.end, demo: false),
                                                   minutes: store.minuteSummaries(from: iv.start.addingTimeInterval(-60), to: iv.end, demo: false),
                                                   inputEvents: store.inputEvents(from: iv.start, to: iv.end, demo: false),
                                                   idles: store.idleSessions(from: iv.start, to: iv.end, demo: false), clip: built)
                let name = String(format: "run-%02d", j + 1)
                try ExportTimeline.jsonl(events).write(to: dir.appendingPathComponent("\(name).events.jsonl"), atomically: true, encoding: .utf8)
                let board = ExportTimeline.storyboard(interval: iv, events: events, time: built.map { c in { d in c.time(for: d).map { ($0.seconds * 100).rounded() / 100 } } })
                try ExportTimeline.storyboardMarkdown(title: "\(insight.title), run \(j + 1)", clip: built == nil ? nil : "\(name).mov", windows: board)
                    .write(to: dir.appendingPathComponent("\(name).storyboard.md"), atomically: true, encoding: .utf8)
                runsManifest.append(Self.runManifest(index: j + 1, interval: iv, name: name, clip: built, storyboard: board))
            }
            manifestWorkflows.append([
                "folder": "Workflows/\(name)", "title": insight.title, "kind": (opp?.kind ?? (insight.automatable ? .integration : .manual)).rawValue,
                "headline": opp?.headline ?? "", "occurrences": insight.pattern.occurrences, "score": insight.pattern.automationScore,
                "pricedAtScore": insight.pattern.pricingScore(for: opp?.kind),
                "estimatedYearlySaving": insight.pattern.estimatedYearlySaving(hourlyRate: hourlyRate, minimumScore: opp?.kind == .customApp ? Opportunity.customAppFloorScore : 0),
                "frames": moments.filter { !$0.imagePath.isEmpty && FileManager.default.fileExists(atPath: $0.imagePath) }.count,
                "runs": runsManifest,
            ])
            done += 1
            // One recording per occurrence, so a reviewer can watch a single run.
            let parts = runParts[i]
            if !parts.isEmpty {
                let share = 6.0 / Double(parts.count)
                for (j, _) in parts {
                    let label = "Workflow \(i + 1): recording run \(j + 1) of \(insight.pattern.windows.count)"
                    await report(label)
                    if let clip = builtClips[j] {
                        let base = done
                        try await Recordings.export(clip, to: dir.appendingPathComponent(String(format: "run-%02d.mov", j + 1))) { f in
                            await progress(min(0.99, (base + share * f) / total), label)
                        }
                    }
                    done += share
                }
            }
        }

        for (i, task) in tasks.enumerated() {
            let name = String(format: "%02d - %@", i + 1, Self.safeName(StoryFormat.plain(task.title)))
            let dir = folder.appendingPathComponent("Tasks/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            await report("Task \(i + 1) of \(tasks.count): \(StoryFormat.plain(task.title))")
            let minutes = store.minutesForTask(task.id)
            let opp = opps["task:\(task.id)"]
            try Self.taskMarkdown(task, minutes: minutes, opportunity: opp).write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try Self.taskJSON(task, minutes: minutes, opportunity: opp).write(to: dir.appendingPathComponent("task.json"))
            done += 1
            let parts = taskParts[i]
            let iv = DateInterval(start: task.start, end: max(task.start, task.end)).padded
            var built: Recordings.Clip?
            if !parts.isEmpty {
                built = await Recordings.clip(parts)
                if let clip = built {
                    let base = done
                    try await Recordings.export(clip, to: dir.appendingPathComponent("recording.mov")) { f in
                        await progress(min(0.99, (base + 6 * f) / total), "Task \(i + 1): recording")
                    }
                }
                done += 6
            }
            let events = ExportTimeline.events(interval: iv, spans: store.spans(from: iv.start, to: iv.end, demo: false),
                                               narratives: store.narratives(from: iv.start, to: iv.end, demo: false), minutes: minutes,
                                               inputEvents: store.inputEvents(from: iv.start, to: iv.end, demo: false),
                                               idles: store.idleSessions(from: iv.start, to: iv.end, demo: false), clip: built)
            try ExportTimeline.jsonl(events).write(to: dir.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
            let board = ExportTimeline.storyboard(interval: iv, events: events, time: built.map { c in { d in c.time(for: d).map { ($0.seconds * 100).rounded() / 100 } } })
            try ExportTimeline.storyboardMarkdown(title: StoryFormat.plain(task.title), clip: built == nil ? nil : "recording.mov", windows: board)
                .write(to: dir.appendingPathComponent("storyboard.md"), atomically: true, encoding: .utf8)
            var entry = Self.runManifest(index: 1, interval: iv, name: "recording", clip: built, storyboard: board)
            entry["events"] = "events.jsonl"; entry["storyboard"] = "storyboard.md"
            entry["folder"] = "Tasks/\(name)"; entry["title"] = StoryFormat.plain(task.title)
            entry["automatable"] = task.automatable; entry["kind"] = opp?.kind.rawValue ?? NSNull(); entry["headline"] = opp?.headline ?? ""
            entry.removeValue(forKey: "index")
            manifestTasks.append(entry)
        }
        manifest["workflows"] = manifestWorkflows
        manifest["tasks"] = manifestTasks
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("manifest.json"))
        do {
            try FileManager.default.moveItem(at: folder, to: final)
        } catch let e as NSError where e.domain == NSCocoaErrorDomain && (e.code == 513 || e.code == 257) {
            throw NSError(domain: "Availeth", code: 11, userInfo: [NSLocalizedDescriptionKey: "macOS blocked writing to the Desktop \u{2014} allow Availeth under System Settings \u{203A} Privacy & Security \u{203A} Files and Folders."])
        }
        await progress(1, "Exported")
        return final
    }

    /// Every narrative captured inside any occurrence of the workflow.
    private func allMoments(for insight: WorkflowInsight) -> [SceneNarrative] {
        var out: [SceneNarrative] = [], seen = Set<Int64>()
        for w in insight.pattern.windows {
            let iv = DateInterval(start: w.start, end: w.end).padded
            for n in store.narratives(from: iv.start, to: iv.end, demo: false)
                where !seen.contains(n.id) {
                seen.insert(n.id); out.append(n)
            }
        }
        return out.sorted { $0.timestamp < $1.timestamp }
    }

    private func copyFrames(_ moments: [SceneNarrative], into dir: URL) {
        let present = moments.filter { !$0.imagePath.isEmpty && FileManager.default.fileExists(atPath: $0.imagePath) }
        guard !present.isEmpty else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        for m in present {
            let dest = dir.appendingPathComponent("\(f.string(from: m.timestamp)) #\(m.id).png")
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: m.imagePath), to: dest)
        }
    }

    // MARK: - Documents

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    static func readme(insights: [WorkflowInsight], tasks: [TaskSummary], opportunities: [String: Opportunity] = [:], from: Date, to: Date, rate: Double) -> String {
        var s = """
        # Availeth export \u{2014} automatable work only

        Exported \(stamp.string(from: to)) from Availeth Discovery, covering \(stamp.string(from: from)) to \(stamp.string(from: to)).

        This folder contains ONLY the work Availeth judged automatable: \(insights.count) repeated workflow\(insights.count == 1 ? "" : "s") and \(tasks.count) task\(tasks.count == 1 ? "" : "s") rated High or Medium. Nothing else observed on the Mac is included. Estimates use \(Format.money(rate))/hour.

        Each workflow folder holds: `README.md` (what it is, what could be automated), `workflow.json` (the structured data), `moments.md` (what the local model saw, in order), `frames/` when any of those screens is still on disk, and one `run-NN.mov` per recorded occurrence, playable in QuickTime.

        Each task folder holds: `README.md`, `task.json`, `events.jsonl`, `storyboard.md` and `recording.mov` when a recording exists.

        `manifest.json` lists everything with paths and clip timings. Every run and task also has `*.events.jsonl` \u{2014} a time-aligned track (window changes, what the local model saw, copies, pastes, saves, committed fields, clicks with screen position, typing bursts as counts) with `t` = seconds into the clip \u{2014} and `*.storyboard.md`, which scores each 30-second stretch and suggests what to dwell on and what to fast-forward.

        """
        let apps = insights.filter { opportunities["wf:" + $0.pattern.id]?.kind == .customApp }
            .map { ($0.title, opportunities["wf:" + $0.pattern.id]!) }
            + tasks.filter { opportunities["task:\($0.id)"]?.kind == .customApp }.map { (StoryFormat.plain($0.title), opportunities["task:\($0.id)"]!) }
        if !apps.isEmpty {
            s += "## Custom app candidates\n\nProcesses the local model judged are run by hand on generic tools and would be replaced by a small purpose-built app:\n\n"
            for (title, o) in apps { s += "- **\(title)** \u{2014} \(o.headline). \(o.rationale)\n" }
            s += "\n"
        }
        s += "## Workflows\n\n"
        for (i, w) in insights.enumerated() {
            let p = w.pattern
            let o = opportunities["wf:" + p.id]
            let kind = o?.kind ?? (w.automatable ? .integration : .manual)
            s += "\(i + 1). **\(w.title)** \u{2014} \(p.apps.joined(separator: " \u{2192} ")); repeated \(p.occurrences)\u{00D7}; \(kind.label.lowercased())" + (o.map { ": \($0.headline)" } ?? "") + "; ~\(Format.money(p.estimatedYearlySaving(hourlyRate: rate, minimumScore: kind == .customApp ? Opportunity.customAppFloorScore : 0)))/yr (\(p.projectionBasis))\n"
        }
        s += "\n## Tasks\n\n"
        for (i, t) in tasks.enumerated() {
            let o = opportunities["task:\(t.id)"]
            s += "\(i + 1). **\(StoryFormat.plain(t.title))** \u{2014} \(stamp.string(from: t.start)), \(Format.duration(t.duration)); \(t.automatable)" + (o.map { "; \($0.kind.label.lowercased()): \($0.headline)" } ?? "") + "\n"
        }
        return s
    }

    /// One run's (or task's) manifest entry: the clip, its parts, the display
    /// it was recorded on, and the storyboard rows.
    static func runManifest(index: Int, interval: DateInterval, name: String, clip: Recordings.Clip?, storyboard: [ExportTimeline.Window]) -> [String: Any] {
        var o: [String: Any] = [
            "index": index, "start": iso(interval.start), "end": iso(interval.end),
            "events": "\(name).events.jsonl", "storyboard": "\(name).storyboard.md",
            "tBasis": clip == nil ? "wall" : "clip",
            "clip": clip == nil ? NSNull() : "\(name).mov",
            "clipSeconds": clip.map { ($0.duration.seconds * 10).rounded() / 10 } ?? NSNull(),
            "parts": (clip?.parts ?? []).map { ["clipStart": ($0.at.seconds * 100).rounded() / 100, "wallStart": iso($0.part.start), "seconds": ($0.part.duration * 100).rounded() / 100] },
            "storyboardRows": ExportTimeline.storyboardJSON(storyboard),
        ]
        if let seg = clip?.parts.first?.part.segment {
            o["display"] = ["id": seg.display, "pointsWidth": seg.pointsWidth, "pointsHeight": seg.pointsHeight]
            o["clipPixels"] = ["width": seg.pixelsWidth, "height": seg.pixelsHeight]
        }
        return o
    }

    static func opportunityMarkdown(_ o: Opportunity) -> String {
        var s = "## \(o.kind == .customApp ? "What we'd build" : "What to do about it")\n\n**\(o.kind.title)** \u{2014} \(o.headline)\n\n\(o.rationale)\n\n"
        if !o.entities.isEmpty { s += "The process is about: \(o.entities.joined(separator: ", ")).\n\n" }
        s += "_\(o.confidence) confidence, judged by the local model (\(o.model))._\n\n"
        return s
    }

    static func opportunityJSON(_ o: Opportunity?) -> Any {
        guard let o else { return NSNull() }
        return ["kind": o.kind.rawValue, "title": o.kind.title, "headline": o.headline, "rationale": o.rationale,
                "entities": o.entities, "confidence": o.confidence, "model": o.model] as [String: Any]
    }

    static func workflowMarkdown(_ w: WorkflowInsight, opportunity: Opportunity? = nil, rate: Double) -> String {
        let p = w.pattern
        var s = "# \(w.title)\n\n"
        if let o = opportunity { s += opportunityMarkdown(o) }
        s += "- Apps: \(p.apps.joined(separator: " \u{2192} "))\n- Repeated: \(p.occurrences)\u{00D7} over \(p.daysObserved) observed workday\(p.daysObserved == 1 ? "" : "s")\n"
        s += "- Median run: \(Format.preciseDuration(p.medianDuration)); observed in total: \(Format.duration(p.totalDuration))\n"
        let floor = opportunity?.kind == .customApp ? Opportunity.customAppFloorScore : 0
        s += "- Automation score: \(p.automationScore)/100" + (floor > p.automationScore ? " (priced at \(floor): a custom app replaces the process)" : "") + "\n- Potential saving: ~\(Format.money(p.estimatedYearlySaving(hourlyRate: rate, minimumScore: floor)))/yr (\(p.projectionBasis), at \(Format.money(rate))/h)\n\n"
        s += "## What this is\n\n\(w.whatItIs)\n\n## What could be automated\n\n\(w.whatToAutomate)\n\n## The steps, in order\n\n"
        for st in w.steps {
            s += "\(st.id + 1). **\(st.app)**" + (st.detail.isEmpty ? "" : " \u{2014} \(st.detail)") + "\n"
            if !st.content.isEmpty { s += "   \(st.content)\n" }
        }
        s += "\n## Occurrences\n\n"
        for (i, win) in p.windows.enumerated() {
            s += "\(i + 1). \(stamp.string(from: win.start)) \u{2013} \(DateFormatter.localizedString(from: win.end, dateStyle: .none, timeStyle: .short)) (\(Format.preciseDuration(win.duration)))\n"
        }
        return s
    }

    static func momentsMarkdown(_ moments: [SceneNarrative]) -> String {
        var s = "# What the local model saw, in order\n\n"
        if moments.isEmpty { s += "_No screen descriptions were captured for this workflow._\n" }
        for m in moments {
            s += "### \(stamp.string(from: m.timestamp)) \u{2014} \(m.appName)" + (m.windowTitle.isEmpty ? "" : " \u{2014} \(m.windowTitle)") + "\n\n\(m.text)\n\n"
        }
        return s
    }

    static func taskMarkdown(_ t: TaskSummary, minutes: [MinuteSummary], opportunity: Opportunity? = nil) -> String {
        var s = "# \(StoryFormat.plain(t.title))\n\n"
        if let o = opportunity { s += opportunityMarkdown(o) }
        s += "- When: \(stamp.string(from: t.start)) \u{2013} \(DateFormatter.localizedString(from: t.end, dateStyle: .none, timeStyle: .short)) (\(Format.duration(t.duration)))\n"
        s += "- Apps: \(t.apps)\n- Automatable: \(t.automatable)\n\n## Story\n\n\(t.text)\n\n## Minute by minute\n\n"
        for m in minutes where !m.text.isEmpty {
            s += "- \(DateFormatter.localizedString(from: m.minuteStart, dateStyle: .none, timeStyle: .short)) \(StoryFormat.plain(m.text))"
            let extra = [m.shortcuts, m.fields].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
            if !extra.isEmpty { s += " _(\(extra))_" }
            s += "\n"
        }
        return s
    }

    static func workflowJSON(_ w: WorkflowInsight, opportunity: Opportunity? = nil, rate: Double) throws -> Data {
        let p = w.pattern
        let obj: [String: Any] = [
            "opportunity": opportunityJSON(opportunity),
            "title": w.title, "apps": p.apps, "stepLabels": p.stepLabels, "occurrences": p.occurrences,
            "medianSeconds": p.medianDuration, "totalSeconds": p.totalDuration, "daysObserved": p.daysObserved,
            "automationScore": p.automationScore, "automatable": w.automatable,
            "estimatedYearlySaving": p.estimatedYearlySaving(hourlyRate: rate), "hourlyRate": rate,
            "projectionBasis": p.projectionBasis, "whatItIs": w.whatItIs, "whatToAutomate": w.whatToAutomate,
            "steps": w.steps.map { ["index": $0.id + 1, "app": $0.app, "detail": $0.detail, "content": $0.content] },
            "windows": p.windows.map { ["start": iso($0.start), "end": iso($0.end)] },
        ]
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    static func taskJSON(_ t: TaskSummary, minutes: [MinuteSummary], opportunity: Opportunity? = nil) throws -> Data {
        let obj: [String: Any] = [
            "opportunity": opportunityJSON(opportunity),
            "title": StoryFormat.plain(t.title), "start": iso(t.start), "end": iso(t.end), "apps": t.apps,
            "automatable": t.automatable, "story": t.text,
            "minutes": minutes.map { ["start": iso($0.minuteStart), "text": $0.text, "apps": $0.apps, "keystrokes": $0.keystrokes,
                                      "clicks": $0.clicks, "shortcuts": $0.shortcuts, "fields": $0.fields] },
        ]
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
}
