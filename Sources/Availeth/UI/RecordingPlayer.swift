import AVFoundation
import AVKit
import SwiftUI

/// A description attached to a point in a recording — a narrative or a
/// minute note — shown beside the player and used as a chapter marker.
struct RecordingMoment: Identifiable, Equatable {
    var id: Int64
    var time: Date
    var text: String
    var caption: String
}

extension RecordingMoment {
    init(_ n: SceneNarrative) {
        self.init(id: n.id, time: n.timestamp, text: n.text,
                  caption: n.windowTitle.isEmpty ? n.appName : "\(n.appName) \u{2014} \(n.windowTitle)")
    }
    init(_ m: MinuteSummary) {
        self.init(id: m.id, time: m.minuteStart, text: StoryFormat.plain(m.text), caption: m.apps)
    }
}

/// Opens the player in its own window — not a sheet — so it can go full
/// screen and outlive the sheet it was opened from.
enum RecordingWindow {
    private static var windows: [NSWindow] = []

    @MainActor
    static func present(title: String, subtitle: String, interval: DateInterval, moments: [RecordingMoment], segments: [RecordingSegment]) {
        let controller = PlayerController()
        let view = RecordingPlayerView(title: title, subtitle: subtitle, interval: interval, moments: moments, segments: segments, controller: controller)
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: 1120, height: 780))
        w.minSize = NSSize(width: 760, height: 520)
        w.collectionBehavior = [.fullScreenPrimary]
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windows.append(w)
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            controller.stop()
            windows.removeAll { $0 === w }
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}

/// Owns the AVPlayer and its time observer so closing the window stops
/// playback deterministically (SwiftUI's onDisappear is not guaranteed when a
/// hosting window closes). Holds a retention "reader" while alive.
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    @Published var current = CMTime.zero
    private var observer: Any?
    private var reading = false

    func attach(_ item: AVPlayerItem) {
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        if observer == nil {
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
                self?.current = t
            }
        }
        if !reading { reading = true; Recordings.beginReading() }
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        player.replaceCurrentItem(with: nil)
        if reading { reading = false; Recordings.endReading() }
    }

    deinit { stop() }
}

/// The stitched recording with 1×–4× speed, full screen, and every
/// description from that stretch beside it — click one to jump there.
struct RecordingPlayerView: View {
    var title: String
    var subtitle: String
    var interval: DateInterval
    var moments: [RecordingMoment]
    var segments: [RecordingSegment]
    @ObservedObject var controller: PlayerController

    private var player: AVPlayer { controller.player }
    private var current: CMTime { controller.current }
    @State private var clip: Recordings.Clip?
    @State private var loading = true
    @State private var rate: Float = 1

    private static let rates: [Float] = [1, 2, 3, 4]

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 0) {
                ZStack {
                    Color.black
                    if clip != nil {
                        PlayerSurface(player: player)
                    } else if loading {
                        ProgressView().controlSize(.large)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "video.slash").font(.system(size: 28)).foregroundStyle(.white.opacity(0.6))
                            Text("No recording for this stretch").foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Theme.line).frame(width: 1)
                momentsPane.frame(width: 340)
            }
        }
        .appCanvas()
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(subtitle).font(.system(size: 11.5)).numeric().foregroundStyle(Theme.ink3).lineLimit(1)
            }
            Spacer()
            speedControl
            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
            .help("Full screen (\u{2303}\u{2318}F)")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var speedControl: some View {
        HStack(spacing: 2) {
            ForEach(Self.rates, id: \.self) { r in
                let on = rate == r
                Button {
                    rate = r
                    player.defaultRate = r
                    if player.rate > 0 { player.rate = r }
                } label: {
                    Text("\(Int(r))\u{00D7}")
                        .font(.system(size: 11, weight: .semibold)).numeric()
                        .foregroundStyle(on ? Theme.accent : Theme.ink3)
                        .frame(width: 34, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? Theme.accentDim : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.panelHi))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .help("Playback speed")
    }

    private var momentsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What was happening").microLabel(Theme.ink3)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            if moments.isEmpty {
                Text("No descriptions were captured in this stretch.")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink3).padding(.horizontal, 16)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(moments) { m in
                                momentRow(m)
                                    .id(m.id)
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 14)
                    }
                    .onChange(of: currentMomentID) { _, id in
                        if let id { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
    }

    /// The most recent moment at or before the playhead.
    private var currentMomentID: Int64? {
        guard let clip else { return nil }
        let now = current.seconds
        return moments.filter { m in
            guard let t = clip.time(for: m.time) else { return false }
            return t.seconds <= now + 0.5
        }.max { $0.time < $1.time }?.id
    }

    private func momentRow(_ m: RecordingMoment) -> some View {
        let active = m.id == currentMomentID
        let seekable = clip?.nearestTime(for: m.time) != nil
        return Button {
            if let t = clip?.nearestTime(for: m.time) {
                player.seek(to: t, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600))
                if player.rate == 0 { player.play(); player.rate = rate }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(m.time.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 10.5, weight: .semibold)).numeric()
                        .foregroundStyle(active ? Theme.accent : Theme.ink3)
                    Text(m.caption).font(.system(size: 10.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                    Spacer(minLength: 0)
                    if seekable {
                        Image(systemName: "play.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.ink3)
                    }
                }
                Text(m.text)
                    .font(.system(size: 12)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active ? Theme.accentDim : Theme.panel2))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(active ? Theme.accent.opacity(0.5) : Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!seekable)
    }

    private func load() async {
        let parts = Recordings.clipParts(for: interval, segments: segments)
        let built = await Task.detached(priority: .userInitiated) { await Recordings.clip(parts) }.value
        guard !Task.isCancelled else { return }
        loading = false
        guard let built else { return }
        clip = built
        controller.attach(AVPlayerItem(asset: built.composition))
        player.defaultRate = rate
        player.play()
        player.rate = rate
    }
}

/// AVKit's player view with floating controls; full screen is ours (the window's).
struct PlayerSurface: NSViewRepresentable {
    var player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = false
        v.videoGravity = .resizeAspect
        v.allowsPictureInPicturePlayback = false
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

/// A frame from the recording at the start of a stretch, with a play badge;
/// tapping opens the player on that stretch.
struct ClipPoster: View {
    var part: Recordings.ClipPart
    var width: CGFloat = 150
    var height: CGFloat = 94
    var action: () -> Void

    @State private var image: NSImage?

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.panelHi)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Circle().fill(.black.opacity(0.55)).frame(width: 30, height: 30)
                    .overlay(Image(systemName: "play.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white).offset(x: 1))
            }
            .frame(width: width, height: height)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Play this stretch of the recording")
        .task(id: part) {
            image = await Task.detached(priority: .utility) { await Recordings.poster(for: part) }.value
        }
    }
}
