import SwiftUI

/// Every movement of data between two places, on its own page. A movement is
/// a copy in one app or site followed within the transfer window by a paste
/// in another. This is the evidence the Workflows tab reasons from, so the
/// person being observed can read all of it: where data left, where it
/// landed, which field it went into, never what it was.
struct TransfersView: View {
    @EnvironmentObject private var state: AppState
    var range: TimeRange

    @State private var transfers: [Transfer] = []
    @State private var search = ""

    private static let displayCap = 300

    private struct Route: Identifiable {
        var id: String { "\(from)→\(to)" }
        var from: String
        var to: String
        var count: Int
        var fields: [String]
        var lastSeen: Date
        var medianGap: TimeInterval
        var days: Int
        /// Text of the most recent paste on this route, "" if none was captured.
        var lastPayload: String
    }

    /// One line of pasted text, trimmed of line breaks and cut to 120 characters.
    private static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > 120 ? String(flat.prefix(120)) + "…" : flat
    }

    private var routes: [Route] {
        var groups: [String: [Transfer]] = [:]
        for t in transfers { groups["\(t.fromUnit)→\(t.toUnit)", default: []].append(t) }
        return groups.values.map { ts in
            let sorted = ts.map(\.gapSeconds).sorted()
            var fieldCounts: [String: Int] = [:]
            for t in ts { if let f = Evidence.cleanField(t.toField) { fieldCounts[f, default: 0] += 1 } }
            let fields = fieldCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(4).map(\.key)
            let newest = ts.max { $0.at < $1.at }
            return Route(from: ts[0].fromUnit, to: ts[0].toUnit, count: ts.count, fields: fields,
                         lastSeen: ts.map(\.at).max() ?? .distantPast,
                         medianGap: sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                         days: TransferMiner.distinctDays(ts.map(\.at)),
                         lastPayload: newest?.payload ?? "")
        }
        .sorted { $0.count == $1.count ? $0.lastSeen > $1.lastSeen : $0.count > $1.count }
    }

    private var filtered: [Transfer] {
        guard !search.isEmpty else { return transfers }
        return transfers.filter {
            $0.fromUnit.localizedCaseInsensitiveContains(search)
                || $0.toUnit.localizedCaseInsensitiveContains(search)
                || $0.fromTitle.localizedCaseInsensitiveContains(search)
                || $0.toTitle.localizedCaseInsensitiveContains(search)
                || $0.toField.localizedCaseInsensitiveContains(search)
                || $0.payload.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statsRow

                if transfers.isEmpty {
                    Card(title: "Data movements", subtitle: explainer) {
                        EmptyState(
                            icon: "arrow.left.arrow.right",
                            title: "No data movements in this range",
                            message: state.showDemo
                                ? "The demo dataset has none here. Try a longer range."
                                : "A movement is recorded when you copy in one app or site and paste in another within a minute and a half. Work normally and check back."
                        )
                    }
                } else {
                    routesCard
                    Card(title: "Every movement", subtitle: "\(transfers.count) movement\(transfers.count == 1 ? "" : "s"), newest first. \(explainer)") {
                        searchField
                        if filtered.isEmpty {
                            EmptyState(icon: "magnifyingglass", title: "Nothing matches", message: "Try a different app, site or field name.")
                        } else {
                            movementList
                        }
                    }
                }
            }
            .padding(24)
        }
        .onAppear(perform: reload)
        .onChange(of: range) { reload() }
        .onChange(of: state.showDemo) { reload() }
        .onChange(of: state.dataVersion) { reload() }
    }

    private var explainer: String {
        "Availeth records where data left and where it landed, and the field it went into. It never records what was copied."
    }

    private func reload() {
        let from = range.startDate()
        let to = Date().addingTimeInterval(60)
        transfers = state.store.transfers(from: from, to: to, demo: state.showDemo).reversed()
    }

    // MARK: Pieces

    private var statsRow: some View {
        let routeList = routes
        let withField = transfers.filter { Evidence.cleanField($0.toField) != nil }.count
        let days = TransferMiner.distinctDays(transfers.map(\.at))
        return HStack(spacing: 12) {
            StatCard(icon: "arrow.left.arrow.right", value: "\(transfers.count)", label: "Movements", detail: "copy here, paste there")
            StatCard(icon: "point.topleft.down.curvedto.point.bottomright.up", value: "\(routeList.count)", label: "Routes", detail: "distinct from → to pairs")
            StatCard(icon: "rectangle.and.pencil.and.ellipsis", value: "\(withField)", label: "Into a named field", detail: "the paste landed in a form field")
            StatCard(icon: "calendar", value: "\(days)", label: "Days seen", detail: "days with at least one movement")
        }
    }

    private var routesCard: some View {
        let list = Array(routes.prefix(30))
        return Card(title: "Routes", subtitle: "Where data goes, most travelled first. A route seen on several days, into the same fields, is what the Workflows tab turns into a candidate.") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, r in
                    routeRow(r)
                    if index < list.count - 1 { Rectangle().fill(Theme.line).frame(height: 1) }
                }
            }
        }
    }

    private func routeRow(_ r: Route) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(r.count)×")
                .font(.system(size: 13, weight: .semibold, design: .rounded)).numeric()
                .foregroundStyle(Theme.ink).frame(width: 46, alignment: .trailing)
            HStack(spacing: 6) {
                AppChip(name: r.from)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.accent)
                AppChip(name: r.to)
            }
            VStack(alignment: .leading, spacing: 2) {
                if !r.fields.isEmpty {
                    Text("into \(r.fields.joined(separator: ", "))").font(.system(size: 11.5)).foregroundStyle(Theme.ink2)
                } else {
                    Text("pasted into the page or editor, not a named field").font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                }
                if !r.lastPayload.isEmpty {
                    Text(Self.oneLine(r.lastPayload))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .help(r.lastPayload)
                }
                Text("\(r.days) day\(r.days == 1 ? "" : "s") · about \(Int(r.medianGap))s from copy to paste · last \(r.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(Theme.ink3)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink3)
            TextField("Filter by app, site, window or field…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    private var movementList: some View {
        let entries = Array(filtered.prefix(Self.displayCap))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, t in
                movementRow(t)
                if index < entries.count - 1 { Rectangle().fill(Theme.line).frame(height: 1) }
            }
            if filtered.count > Self.displayCap {
                Text("Showing the newest \(Self.displayCap) of \(filtered.count). Narrow the range or filter to see the rest.")
                    .font(.caption2).foregroundStyle(Theme.ink3).padding(.top, 8)
            }
        }
    }

    private func movementRow(_ t: Transfer) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(t.at.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 10.5, design: .monospaced)).numeric().foregroundStyle(Theme.ink2)
                Text(t.at.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 9.5)).foregroundStyle(Theme.ink3)
            }
            .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    AppChip(name: t.fromUnit)
                    if !t.fromTitle.isEmpty {
                        Text(StoryWriter.shortTitle(t.fromTitle, app: t.fromApp)).font(.system(size: 11.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(Theme.accent)
                    AppChip(name: t.toUnit)
                    if !t.toTitle.isEmpty {
                        Text(StoryWriter.shortTitle(t.toTitle, app: t.toApp)).font(.system(size: 11.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                }
                HStack(spacing: 8) {
                    if let f = Evidence.cleanField(t.toField) {
                        Text("into \(f)").font(.caption2).foregroundStyle(Theme.ink2)
                    }
                    Text("\(Int(t.gapSeconds))s between copy and paste").font(.caption2).foregroundStyle(Theme.ink3)
                }
                if !t.payload.isEmpty {
                    Text(Self.oneLine(t.payload))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .help(t.payload)
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}
