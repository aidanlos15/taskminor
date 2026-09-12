import AppKit
import Foundation

/// Deterministic seeded RNG so the demo dataset is identical on every launch.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Generates two weeks of realistic finance-department activity so the
/// dashboard demonstrates the full product before any live data exists.
/// Contains deliberately repeated workflows the miner should discover:
///  - Supplier invoice processing: Mail → Preview → Excel → Chrome (NetSuite), ~5×/day
///  - CRM updating: Chrome (Salesforce) → Excel → Chrome, ~3×/day
///  - Weekly reporting: Excel → Keynote → Mail, Fridays
/// plus meetings, Slack, and browsing noise.
enum DemoData {

    static func generate(now: Date = Date()) -> [ActivitySpan] {
        var rng = SplitMix64(seed: 0xA11E7)
        var spans: [ActivitySpan] = []
        let cal = Calendar.current

        for dayOffset in stride(from: 13, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -dayOffset, to: cal.startOfDay(for: now)) else { continue }
            let weekday = cal.component(.weekday, from: day)
            guard weekday >= 2 && weekday <= 6 else { continue } // Mon–Fri

            var clock = day.addingTimeInterval(TimeInterval(Int.random(in: (8 * 3600 + 30 * 60)...(9 * 3600 + 15 * 60), using: &rng)))
            let endOfDay = day.addingTimeInterval(17.5 * 3600)

            // Morning email triage
            clock = append(&spans, at: clock, app: .mail, title: "Inbox", minutes: Double.random(in: 12...22, using: &rng), rng: &rng)

            // Mon/Wed/Fri: next week's staff rota, kept in a spreadsheet with
            // availability collected by email one person at a time — the shape
            // of a process a small custom app would replace.
            if [2, 4, 6].contains(weekday) {
                clock = rotaWorkflow(&spans, at: clock, rng: &rng, week: 36 + (14 - dayOffset) / 7)
            }

            var invoicesDone = 0
            var crmDone = 0
            let invoiceTarget = Int.random(in: 4...6, using: &rng)
            let crmTarget = Int.random(in: 2...4, using: &rng)

            while clock < endOfDay {
                // Weighted activity picker; workflow weights drop out once the
                // daily quota is met so the remainder of the day stays balanced.
                enum Activity { case invoice, crm, slack, browse, deepWork, mail, meeting, claude }
                var choices: [(Double, Activity)] = [
                    (10, .slack), (10, .browse), (9, .deepWork), (6, .mail), (8, .meeting), (7, .claude),
                ]
                if invoicesDone < invoiceTarget { choices.append((28, .invoice)) }
                if crmDone < crmTarget { choices.append((14, .crm)) }
                let totalWeight = choices.reduce(0) { $0 + $1.0 }
                var roll = Double.random(in: 0..<totalWeight, using: &rng)
                var picked = choices[0].1
                for (weight, activity) in choices {
                    if roll < weight { picked = activity; break }
                    roll -= weight
                }

                switch picked {
                case .invoice:
                    clock = invoiceWorkflow(&spans, at: clock, rng: &rng, index: invoicesDone + dayOffset * 7)
                    invoicesDone += 1
                case .crm:
                    clock = crmWorkflow(&spans, at: clock, rng: &rng)
                    crmDone += 1
                case .slack:
                    clock = append(&spans, at: clock, app: .slack, title: "#finance", minutes: Double.random(in: 3...9, using: &rng), rng: &rng)
                case .browse:
                    clock = append(&spans, at: clock, app: .chrome, title: chromeNoise(rng: &rng), minutes: Double.random(in: 5...15, using: &rng), rng: &rng)
                case .deepWork:
                    clock = append(&spans, at: clock, app: .excel, title: deepWorkTitle(rng: &rng), minutes: Double.random(in: 12...30, using: &rng), rng: &rng)
                case .mail:
                    clock = append(&spans, at: clock, app: .mail, title: "Inbox", minutes: Double.random(in: 4...9, using: &rng), rng: &rng)
                case .claude:
                    // A bare "Claude" window: the intent labels (seedSpanLabels) name these sittings.
                    clock = append(&spans, at: clock, app: .claude, title: "Claude", minutes: Double.random(in: 6...14, using: &rng), rng: &rng,
                                   keys: Int.random(in: 120...420, using: &rng), clicks: Int.random(in: 6...24, using: &rng),
                                   shortcuts: "\u{2318}V\u{00D7}2, \u{21B5}\u{00D7}3", fields: "Message Claude [prompt]")
                case .meeting:
                    clock = append(&spans, at: clock, app: .calendar, title: "Team Standup", minutes: 2, rng: &rng)
                    clock = clock.addingTimeInterval(Double.random(in: 25...45, using: &rng) * 60)
                }

                // Lunch around 12:30
                let hour = cal.component(.hour, from: clock)
                let minute = cal.component(.minute, from: clock)
                if hour == 12 && minute > 20 {
                    clock = clock.addingTimeInterval(Double.random(in: 35...55, using: &rng) * 60)
                }
            }

            // Friday afternoon: weekly reporting workflow
            if weekday == 6 {
                var t = day.addingTimeInterval(14.5 * 3600)
                t = append(&spans, at: t, app: .excel, title: "Weekly Ops Report.xlsx", minutes: Double.random(in: 22...30, using: &rng), rng: &rng)
                t = append(&spans, at: t, app: .keynote, title: "Ops Review.key", minutes: Double.random(in: 15...22, using: &rng), rng: &rng)
                _ = append(&spans, at: t, app: .mail, title: "Weekly Ops Report — draft", minutes: Double.random(in: 4...7, using: &rng), rng: &rng)
            }
        }

        // Deterministic aligned invoice workflow so Workflows detection + the
        // drill-down walkthrough are demonstrable in demo mode.
        for step in alignedInvoiceSteps(now: now) {
            spans.append(ActivitySpan(
                bundleID: step.bundle, appName: step.app, windowTitle: step.title,
                start: step.start, end: step.start.addingTimeInterval(step.duration)
            ))
        }

        return spans.map { span in
            var s = span
            s.isDemo = true
            return s
        }
    }

    /// One step of the deterministic aligned invoice workflow — the SAME
    /// timestamps back both the spans and the narratives, so the Workflows
    /// drill-down shows a real screenshot walkthrough in demo mode.
    struct AlignedStep {
        var bundle: String, app: String, title: String
        var start: Date, duration: TimeInterval, narrative: String
    }

    static func alignedInvoiceSteps(now: Date = Date()) -> [AlignedStep] {
        let cal = Calendar.current
        var out: [AlignedStep] = []
        let template: [(String, String, String, TimeInterval, String)] = [
            ("com.apple.mail", "Mail", "Invoice #10247 — Acme Corp", 90, "Reading a supplier invoice email with a PDF attachment."),
            ("com.apple.Preview", "Preview", "invoice_10247.pdf", 60, "Reviewing the supplier invoice PDF before entering it."),
            ("com.microsoft.Excel", "Microsoft Excel", "Purchase Orders.xlsx", 90, "Searching the purchase-order spreadsheet for a match and copying the reference."),
            ("com.google.Chrome", "Google Chrome", "Vendor Bills — NetSuite", 180, "Entering the supplier, invoice number, and amount into NetSuite and submitting the bill."),
        ]
        // 6 occurrences across today + yesterday so the miner detects the pattern.
        for occ in 0..<6 {
            let day = cal.date(byAdding: .day, value: -(occ % 2), to: cal.startOfDay(for: now)) ?? now
            var t = day.addingTimeInterval(10 * 3600 + Double(occ) * 35 * 60)
            for step in template {
                out.append(AlignedStep(bundle: step.0, app: step.1, title: step.2, start: t, duration: step.3, narrative: step.4))
                t = t.addingTimeInterval(step.3 + 8) // small gap between steps
            }
        }
        return out
    }

    /// Seeds the synthesized story hierarchy (task summaries + their linked
    /// minute summaries) so the Story tab demonstrates the full picture without
    /// needing the local model.
    static func seedSummaries(into store: Store) {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())

        struct DemoTask {
            var title: String, apps: String, automatable: String, story: String
            var startHour: Double, minutes: [(String, Int, Int, String, String)] // text, keys, clicks, shortcuts, fields
        }

        let tasks: [DemoTask] = [
            DemoTask(
                title: "Supplier invoice processing",
                apps: "Mail, Preview, Microsoft Excel, Google Chrome",
                automatable: "High — repeated copy/paste between systems, structured data entry into fields",
                story: "The employee opened a supplier invoice from email, checked the PDF, looked up the purchase order in a spreadsheet, then re-entered the supplier, invoice number, and amount into NetSuite and submitted the bill for approval. The same copy-from-spreadsheet, paste-into-ERP pattern repeats every invoice — a strong candidate for automated extraction and posting.",
                startHour: 9.1,
                minutes: [
                    ("Opened a supplier invoice email and saved the attached PDF.", 12, 4, "⌘S×1", ""),
                    ("Reviewed the invoice PDF and switched to the purchase-order spreadsheet.", 6, 3, "⌘F×1, ↵×1", "PO Search [search]"),
                    ("Searched the spreadsheet for the matching purchase order and copied the reference.", 18, 5, "⌘F×2, ⌘C×1, ↵×1", ""),
                    ("Opened NetSuite and started a new vendor bill.", 8, 6, "Tab×2", ""),
                    ("Pasted the PO and entered supplier, invoice number, and amount into the bill.", 34, 7, "⌘V×1, Tab×5", "Invoice Number [identifier], Amount [currency], PO Number [identifier]"),
                    ("Reviewed the vendor bill and submitted it for approval.", 5, 3, "↵×1", ""),
                ]
            ),
            DemoTask(
                title: "CRM opportunity updates",
                apps: "Google Chrome, Microsoft Excel",
                automatable: "Medium — structured data entry into fields, form/tab navigation",
                story: "The employee worked through the sales pipeline in Salesforce, cross-checking figures against a deal-tracking spreadsheet and updating each opportunity's stage and amount by hand. The lookups and field updates are consistent enough to be driven from the spreadsheet automatically.",
                startHour: 11.0,
                minutes: [
                    ("Reviewed the Q3 pipeline in Salesforce and opened the deal-tracker spreadsheet.", 10, 5, "⌘F×1, ↵×1", "Account Search [search]"),
                    ("Cross-checked deal figures in the spreadsheet and copied an updated value.", 14, 4, "⌘C×1", ""),
                    ("Updated the opportunity stage and amount in Salesforce.", 22, 6, "⌘V×1, Tab×3", "Opportunity Name [name], Stage, Amount [currency]"),
                    ("Moved to the next opportunity and repeated the update.", 20, 5, "Tab×3", "Stage, Amount [currency]"),
                ]
            ),
            DemoTask(
                title: "Build next week's staff rota",
                apps: "Microsoft Excel, Mail",
                automatable: "Medium \u{2014} structured data entry into fields, form/tab navigation",
                story: "The employee laid out next week's shifts in the rota spreadsheet, emailed each person to ask which days they can work, and keyed the replies back into the sheet one at a time before saving. Nothing here needs judgement once availability is known \u{2014} it is bookkeeping between a spreadsheet and an inbox.",
                startHour: 9.5,
                minutes: [
                    ("Opened the staff rota spreadsheet for next week and started filling Monday's shifts.", 60, 18, "Tab\u{00D7}12, \u{21B5}\u{00D7}6", "Name, Mon, Tue, Wed"),
                    ("Emailed a staff member to ask about their availability next week.", 40, 4, "", "To, Subject"),
                    ("Keyed the reply into the rota and moved on to the second half of the week.", 30, 10, "Tab\u{00D7}8", "Thu, Fri, Sat"),
                    ("Emailed another staff member about availability.", 35, 4, "", "To, Subject"),
                    ("Entered the last shifts and saved the rota.", 24, 8, "\u{2318}S\u{00D7}1", "Sun"),
                ]
            ),
            DemoTask(
                title: "Weekly report preparation",
                apps: "Microsoft Excel, Keynote, Mail",
                automatable: "Medium — heavy manual typing, repetitive data entry",
                story: "The employee pulled weekly figures into a spreadsheet, rebuilt the same summary slides in Keynote, and emailed the report. The report structure is identical each week — a candidate for templated generation from the source data.",
                startHour: 14.5,
                minutes: [
                    ("Compiled weekly figures in the operations report spreadsheet.", 210, 8, "⌘C×3, ⌘V×3", ""),
                    ("Updated charts and totals in the spreadsheet.", 160, 6, "Tab×4", ""),
                    ("Rebuilt the summary slides in Keynote from the spreadsheet.", 120, 10, "⌘C×2, ⌘V×2", ""),
                    ("Drafted the report email and attached the deck.", 90, 4, "⌘V×1", "To, Subject"),
                ]
            ),
        ]

        for (i, task) in tasks.enumerated() {
            let day = cal.date(byAdding: .day, value: -(i % 2), to: base) ?? base
            let start = day.addingTimeInterval(task.startHour * 3600)
            let end = start.addingTimeInterval(Double(task.minutes.count) * 60)
            let taskID = store.insertTaskSummary(TaskSummary(
                start: start, end: end, title: task.title, text: task.story,
                apps: task.apps, minuteCount: task.minutes.count, automatable: task.automatable, isDemo: true
            ))
            for (m, minute) in task.minutes.enumerated() {
                store.insertMinuteSummary(MinuteSummary(
                    minuteStart: start.addingTimeInterval(Double(m) * 60),
                    text: minute.0, apps: task.apps, keystrokes: minute.1, clicks: minute.2,
                    shortcuts: minute.3, fields: minute.4, sourceCount: 2, taskID: taskID, isDemo: true
                ))
            }
        }
    }

    /// A couple of away-from-keyboard stretches so idle handling is visible in
    /// the demo (e.g. a lunch break and an end-of-day gap).
    static func generateIdleSessions(now: Date = Date()) -> [IdleSession] {
        let cal = Calendar.current
        var out: [IdleSession] = []
        for dayOffset in [0, 1] {
            guard let day = cal.date(byAdding: .day, value: -dayOffset, to: cal.startOfDay(for: now)) else { continue }
            // Lunch ~12:30–13:10
            out.append(IdleSession(start: day.addingTimeInterval(12.5 * 3600), end: day.addingTimeInterval(13.17 * 3600), isDemo: true))
            // A mid-afternoon meeting away from desk ~15:00–15:35
            out.append(IdleSession(start: day.addingTimeInterval(15 * 3600), end: day.addingTimeInterval(15.58 * 3600), isDemo: true))
        }
        return out
    }

    /// A handful of storyline narratives (as a local vision model would produce)
    /// so Storyline mode is demonstrable in the demo dataset.
    static func generateNarratives(now: Date = Date()) -> [SceneNarrative] {
        let cal = Calendar.current
        let lines: [(String, String, String, String)] = [
            ("Google Chrome", "Vendor Bills — NetSuite", "Submitting a vendor bill for approval in an accounting system.", "Pasted"),
            ("Microsoft Excel", "Purchase Orders.xlsx", "Searching a spreadsheet of purchase orders for a matching record.", "Copied"),
            ("Preview", "invoice_10247.pdf", "Reviewing a supplier invoice PDF before data entry.", "Switched to Preview"),
            ("Mail", "Invoice #10247 — Acme Corp", "Reading a supplier invoice email with an attachment.", "Switched to Mail"),
            ("Google Chrome", "Q3 Pipeline — Salesforce", "Updating an opportunity record in a CRM pipeline.", "Filled a field"),
            ("Microsoft Excel", "Cash Flow Model.xlsx", "Editing figures in a financial model spreadsheet.", "Saved"),
            ("Google Chrome", "Opportunity — Salesforce", "Entering deal details into a CRM opportunity form.", "Filled a field"),
            ("Keynote", "Ops Review.key", "Assembling slides for a weekly operations review.", "Switched to Keynote"),
        ]
        var out: [SceneNarrative] = []
        for (i, line) in lines.enumerated() {
            let day = cal.date(byAdding: .day, value: -(i % 3), to: cal.startOfDay(for: now)) ?? now
            let ts = day.addingTimeInterval(TimeInterval(9 * 3600 + i * 1800))
            let path = renderMockScene(app: line.0, title: line.1) ?? ""
            out.append(SceneNarrative(timestamp: ts, appName: line.0, windowTitle: line.1, text: line.2, imagePath: path, trigger: line.3, isDemo: true))
        }
        // Narratives aligned to the invoice-workflow occurrences (same timestamps
        // as the spans), so the Workflows drill-down shows a real walkthrough.
        for step in alignedInvoiceSteps(now: now) {
            let path = renderMockScene(app: step.app, title: step.title) ?? ""
            out.append(SceneNarrative(
                timestamp: step.start.addingTimeInterval(5), appName: step.app, windowTitle: step.title,
                text: step.narrative, imagePath: path, isDemo: true
            ))
        }
        return out
    }

    /// Draws a clearly-stylized mock "window" so the demo storyline shows the
    /// image-plus-transcription layout without pretending to be a real capture.
    private static func renderMockScene(app: String, title: String) -> String? {
        let w = 528, h = 328
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        // title bar — deterministic hue from the app name
        var hash: UInt64 = 0xcbf29ce484222325
        for b in app.utf8 { hash ^= UInt64(b); hash = hash &* 0x100000001b3 }
        NSColor(calibratedHue: CGFloat(hash % 360) / 360.0, saturation: 0.55, brightness: 0.6, alpha: 1).setFill()
        NSRect(x: 0, y: h - 56, width: w, height: 56).fill()
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ sz: CGFloat, _ c: NSColor) {
            (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.boldSystemFont(ofSize: sz), .foregroundColor: c])
        }
        text(app, 20, CGFloat(h) - 42, 20, .white)
        text(title, 20, CGFloat(h) - 96, 15, NSColor(calibratedWhite: 0.25, alpha: 1))
        // fake content rows
        NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
        for r in 0..<5 { NSRect(x: 20, y: CGFloat(h) - 140 - CGFloat(r) * 34, width: CGFloat(w) - 60, height: 18).fill() }
        text("(demo mock — not a real screenshot)", 20, 16, 11, NSColor(calibratedWhite: 0.6, alpha: 1))
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = ScreenshotCapture.directory().appendingPathComponent("demo-scene-\(app.replacingOccurrences(of: " ", with: "_"))-\(abs(title.hashValue)).png")
        try? png.write(to: url)
        return url.path
    }

    // MARK: - Workflows

    private static let suppliers = ["Acme Corp", "Northwind", "Globex", "Initech", "Vandelay", "Stark Supply", "Wayne Logistics", "Hooli Cloud"]

    private static func invoiceWorkflow(_ spans: inout [ActivitySpan], at start: Date, rng: inout SplitMix64, index: Int) -> Date {
        let supplier = suppliers[index % suppliers.count]
        let invoiceNo = 10200 + index * 7
        var t = start
        t = append(&spans, at: t, app: .mail, title: "Invoice #\(invoiceNo) — \(supplier)", minutes: Double.random(in: 1.5...3, using: &rng), rng: &rng, keys: 3, clicks: 4, shortcuts: "⌘S×1")
        t = append(&spans, at: t, app: .preview, title: "invoice_\(invoiceNo).pdf", minutes: Double.random(in: 0.8...1.8, using: &rng), rng: &rng, clicks: 2)
        t = append(&spans, at: t, app: .excel, title: "Purchase Orders.xlsx", minutes: Double.random(in: 1.5...3, using: &rng), rng: &rng, keys: 7, clicks: 3, shortcuts: "⌘F×1, ↵×1, ⌘C×1", fields: "PO Search [search]")
        t = append(&spans, at: t, app: .chrome, title: "Vendor Bills — NetSuite", minutes: Double.random(in: 3...5, using: &rng), rng: &rng, keys: 14, clicks: 6, shortcuts: "⌘V×1, Tab×4, ↵×1", fields: "Invoice Number [identifier], Amount [currency], PO Number [identifier]")
        return t.addingTimeInterval(Double.random(in: 1...5, using: &rng) * 60)
    }

    private static let staff = ["Sarah", "Tom", "Priya", "Liam", "Aoife"]

    /// Excel rota → an availability email → back to the rota → another email → the rota.
    private static func rotaWorkflow(_ spans: inout [ActivitySpan], at start: Date, rng: inout SplitMix64, week: Int) -> Date {
        var t = start
        let rota = "Staff Rota \u{2014} Week \(week).xlsx"
        t = append(&spans, at: t, app: .excel, title: rota, minutes: Double.random(in: 3...5, using: &rng), rng: &rng, keys: 60, clicks: 18, shortcuts: "Tab\u{00D7}12, \u{21B5}\u{00D7}6", fields: "Name, Mon, Tue, Wed")
        t = append(&spans, at: t, app: .mail, title: "Re: Availability next week \u{2014} \(staff[Int.random(in: 0..<staff.count, using: &rng)])", minutes: Double.random(in: 1...2, using: &rng), rng: &rng, keys: 40, clicks: 4, fields: "To, Subject")
        t = append(&spans, at: t, app: .excel, title: rota, minutes: Double.random(in: 2...3, using: &rng), rng: &rng, keys: 30, clicks: 10, shortcuts: "Tab\u{00D7}8", fields: "Thu, Fri, Sat")
        t = append(&spans, at: t, app: .mail, title: "Re: Availability next week \u{2014} \(staff[Int.random(in: 0..<staff.count, using: &rng)])", minutes: Double.random(in: 1...2, using: &rng), rng: &rng, keys: 35, clicks: 4, fields: "To, Subject")
        t = append(&spans, at: t, app: .excel, title: rota, minutes: Double.random(in: 2...3, using: &rng), rng: &rng, keys: 24, clicks: 8, shortcuts: "\u{2318}S\u{00D7}1", fields: "Sun")
        return t.addingTimeInterval(Double.random(in: 2...6, using: &rng) * 60)
    }

    private static func crmWorkflow(_ spans: inout [ActivitySpan], at start: Date, rng: inout SplitMix64) -> Date {
        var t = start
        t = append(&spans, at: t, app: .chrome, title: "Q3 Pipeline — Salesforce", minutes: Double.random(in: 2...4, using: &rng), rng: &rng, keys: 6, clicks: 5, shortcuts: "⌘F×1, ↵×1", fields: "Account Search [search]")
        t = append(&spans, at: t, app: .excel, title: "Deal Tracker.xlsx", minutes: Double.random(in: 1...2.5, using: &rng), rng: &rng, keys: 4, clicks: 3, shortcuts: "⌘C×1")
        t = append(&spans, at: t, app: .chrome, title: "Opportunity — Salesforce", minutes: Double.random(in: 1.5...3, using: &rng), rng: &rng, keys: 10, clicks: 4, shortcuts: "⌘V×1, Tab×3", fields: "Opportunity Name [name], Stage, Amount [currency]")
        return t.addingTimeInterval(Double.random(in: 2...8, using: &rng) * 60)
    }

    private static func deepWorkTitle(rng: inout SplitMix64) -> String {
        let options = ["Purchase Orders.xlsx", "Month-End Accruals.xlsx", "Cash Flow Model.xlsx", "Budget vs Actuals.xlsx"]
        return options[Int.random(in: 0..<options.count, using: &rng)]
    }

    private static func chromeNoise(rng: inout SplitMix64) -> String {
        let options = [
            "FX rates — xe.com", "Supplier onboarding docs — Notion",
            "Expense policy — Google Docs", "Payment run checklist — Confluence",
            "Industry news — FT.com",
        ]
        return options[Int.random(in: 0..<options.count, using: &rng)]
    }

    /// Demo intent labels: every Claude sitting gets a task title (and one
    /// captured narrative, so "captured" detail exists to open) and every other
    /// sitting gets the deterministic row the labeler would write — so the demo
    /// Tasks tab shows the finished shape without a local model.
    /// Judgements for the demo's workflows and tasks, so the "build an app"
    /// read is on screen without the local model. Keys come from the miner
    /// and the seeded tasks, so they match whatever the app would compute.
    static func seedOpportunities(into store: Store) {
        let now = Date()
        let spans = store.spans(from: .distantPast, to: .distantFuture, demo: true)
        for p in PatternMiner.mine(spans: spans) {
            let titles = (p.stepLabels + p.sampleTitles).joined(separator: " ").lowercased()
            if titles.contains("rota") {
                store.upsertOpportunity(Opportunity(
                    key: "wf:" + p.id, kind: .customApp,
                    headline: "A rota app: shifts, availability requests and confirmations in one place",
                    rationale: "The rota lives in a spreadsheet and availability is collected by email one person at a time, then keyed in by hand every week. A small app would hold the shifts, ask staff for availability itself and fill the rota from the answers.",
                    entities: ["staff", "shifts", "availability", "weeks"], confidence: "high", model: "demo", created: now,
                    evidence: p.occurrences, isDemo: true))
            } else if titles.contains("netsuite") {
                store.upsertOpportunity(Opportunity(
                    key: "wf:" + p.id, kind: .integration,
                    headline: "Post supplier bills into NetSuite straight from the invoice email",
                    rationale: "The invoice number, PO number and amount are read off a PDF and re-keyed into NetSuite after a lookup in the purchase-order sheet. All three systems hold the data already; an integration can move it and leave the approval to a person.",
                    entities: ["suppliers", "invoices", "purchase orders", "bills"], confidence: "high", model: "demo", created: now,
                    evidence: p.occurrences, isDemo: true))
            }
        }
        for t in store.taskSummaries(from: .distantPast, to: .distantFuture, demo: true) {
            let title = t.title.lowercased()
            if title.contains("rota") {
                store.upsertOpportunity(Opportunity(
                    key: "task:\(t.id)", kind: .customApp,
                    headline: "A rota app: shifts, availability requests and confirmations in one place",
                    rationale: "Shifts are laid out in a spreadsheet and each person is emailed for their availability, with replies keyed back in by hand. The whole loop is a form and a table \u{2014} the kind of thing a small app does without the emails.",
                    entities: ["staff", "shifts", "availability"], confidence: "high", model: "demo", created: now,
                    evidence: t.minuteCount, isDemo: true))
            } else if title.contains("invoice") {
                store.upsertOpportunity(Opportunity(
                    key: "task:\(t.id)", kind: .integration,
                    headline: "Post supplier bills into NetSuite straight from the invoice email",
                    rationale: "The same fields are copied from the PDF and the purchase-order sheet into NetSuite on every invoice; an integration could do the entry and leave the approval to a person.",
                    entities: ["invoices", "purchase orders", "bills"], confidence: "high", model: "demo", created: now,
                    evidence: t.minuteCount, isDemo: true))
            } else if title.contains("weekly report") {
                store.upsertOpportunity(Opportunity(
                    key: "task:\(t.id)", kind: .streamline,
                    headline: "Generate the weekly report and slides from the source figures",
                    rationale: "The report and slides have the same structure every week; a template fed from the figures would remove the rebuilding, without needing new software.",
                    entities: ["weekly figures", "report", "slides"], confidence: "medium", model: "demo", created: now,
                    evidence: t.minuteCount, isDemo: true))
            }
        }
    }

    static func seedSpanLabels(into store: Store) {
        let spans = store.spans(from: .distantPast, to: .distantFuture, demo: true)
        let sessions = IntentLabeler.sessionise(spans, gap: 5 * 60).sorted { $0.start < $1.start }
        let rota: [(title: String, narrative: String)] = [
            ("Draft the supplier payment-terms email",
             "The user asks Claude to rewrite a payment-terms paragraph for a supplier email, pasting the current wording and asking for a firmer but polite tone."),
            ("Explain month-end accrual entries",
             "The user asks Claude how to book month-end accruals for services received but not yet invoiced, then follows up on reversing them next period."),
            ("Write a NetSuite CSV import formula",
             "The user asks Claude for an Excel formula that reshapes a purchase-order export into the column layout NetSuite's CSV import expects."),
            ("Summarise the weekly ops review",
             "The user pastes bullet notes from the ops review and asks Claude for a short summary to send to the team."),
        ]
        let now = Date()
        var rows: [SpanLabel] = []
        var narratives: [SceneNarrative] = []
        var pick = 0
        for s in sessions {
            if s.unit == "Claude" {
                let item = rota[pick % rota.count]
                pick += 1
                rows += s.spans.map {
                    SpanLabel(spanID: $0.id, sessionKey: s.sessionKey, unit: s.unit, titleKey: s.titleKey,
                              intent: item.title, canon: item.title, source: .model, model: "demo", created: now, isDemo: true)
                }
                narratives.append(SceneNarrative(timestamp: s.start.addingTimeInterval(45), appName: "Claude", windowTitle: "Claude",
                                                 text: item.narrative, trigger: "Pasted", isDemo: true))
            } else {
                let informative = !LabelKey.isUninformative(unit: s.unit, cleanTitle: s.cleanTitle)
                let title = informative ? s.cleanTitle : s.unit
                rows += s.spans.map {
                    SpanLabel(spanID: $0.id, sessionKey: s.sessionKey, unit: s.unit, titleKey: s.titleKey,
                              intent: title, canon: title, source: informative ? .title : .fallback, created: now, isDemo: true)
                }
            }
        }
        store.insertSpanLabels(rows)
        narratives.forEach { store.insertNarrative($0) }
    }

    // MARK: - Plumbing

    private enum DemoApp {
        case mail, preview, excel, chrome, slack, keynote, calendar, claude

        var identity: (bundle: String, name: String) {
            switch self {
            case .claude: return ("com.anthropic.claudefordesktop", "Claude")
            case .mail: return ("com.apple.mail", "Mail")
            case .preview: return ("com.apple.Preview", "Preview")
            case .excel: return ("com.microsoft.Excel", "Microsoft Excel")
            case .chrome: return ("com.google.Chrome", "Google Chrome")
            case .slack: return ("com.tinyspeck.slackmacgap", "Slack")
            case .keynote: return ("com.apple.iWork.Keynote", "Keynote")
            case .calendar: return ("com.apple.iCal", "Calendar")
            }
        }
    }

    private static func append(_ spans: inout [ActivitySpan], at start: Date, app: DemoApp, title: String, minutes: Double, rng: inout SplitMix64, keys: Int = 0, clicks: Int = 0, shortcuts: String = "", fields: String = "") -> Date {
        let (bundle, name) = app.identity
        let end = start.addingTimeInterval(minutes * 60)
        spans.append(ActivitySpan(
            bundleID: bundle, appName: name, windowTitle: title, start: start, end: end,
            keystrokes: keys, clicks: clicks, shortcuts: shortcuts, fields: fields
        ))
        // Small natural gap between window switches.
        return end.addingTimeInterval(Double.random(in: 2...20, using: &rng))
    }
}
