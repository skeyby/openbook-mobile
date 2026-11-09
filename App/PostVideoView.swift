import SwiftUI
import AVKit
import OpenBookCore

/// Creates a player only while visible; never sends API credentials to media URLs.
struct PostVideoView: View {
    let media: Media
    let url: URL
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var visible = false
    @State private var anyVisible = false
    @State private var manuallyStarted = false
    @State private var resumeAfterBackground = false
    @State private var ready = false
    @State private var failed = false
    @State private var paused = true
    @State private var muted = true
    @State private var fullscreen = false
    @State private var retryID = UUID()

    private var needsPlayer: Bool { visible || (manuallyStarted && anyVisible) || fullscreen }
    private var description: String { media.mediaAltText ?? "Video allegato" }
    private var aspect: CGFloat {
        guard let width = media.mediaWidth, let height = media.mediaHeight, width > 0, height > 0 else { return 16 / 9 }
        // Keep very tall media bounded in a scrolling feed.
        return max(CGFloat(width) / CGFloat(height), 4 / 3)
    }

    var body: some View {
        Color.black.aspectRatio(aspect, contentMode: .fit)
            .overlay {
                ZStack {
                    if let player, !fullscreen { VideoPlayer(player: player) }
                    if !ready {
                        if let preview = safeImageURL(media.mediaPreviewUrl), preview != url {
                            AsyncImage(url: preview) { image in image.resizable().scaledToFit() }
                                placeholder: { Color.black }
                                .allowsHitTesting(false)
                        }
                        if failed {
                            VStack(spacing: 8) {
                                Text("Video non disponibile")
                                Button("Riprova") { retryID = UUID() }.buttonStyle(.bordered)
                            }.padding().background(.black.opacity(0.8))
                        } else if visible {
                            ProgressView("Caricamento video…").tint(.white)
                                .padding().background(.black.opacity(0.7)).allowsHitTesting(false)
                        }
                    }
                    if !failed && paused {
                        Button {
                            if let player {
                                if let item = player.currentItem, item.duration.isNumeric,
                                   player.currentTime() >= item.duration { player.seek(to: .zero) }
                                player.play()
                            } else { manuallyStarted = true }
                        } label: {
                            Image(systemName: "play.fill").font(.title)
                                .frame(width: 56, height: 56).background(.black.opacity(0.7), in: Circle())
                        }.accessibilityLabel("Riproduci video: \(description)")
                    }
                    if let player {
                        VStack {
                            HStack {
                                VideoOverlayButton(title: muted ? "Attiva audio" : "Disattiva audio",
                                                   icon: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                                    muted.toggle(); player.isMuted = muted
                                }
                                Spacer()
                                VideoOverlayButton(title: "Video a tutto schermo", icon: "arrow.up.left.and.arrow.down.right") {
                                    fullscreen = true
                                }
                            }
                            Spacer()
                        }.padding(8)
                    }
                }.foregroundStyle(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .background {
                GeometryReader { geometry in
                    let viewport = geometry.bounds(of: .scrollView) ?? CGRect(origin: .zero, size: geometry.size)
                    let frame = CGRect(origin: .zero, size: geometry.size)
                    let intersection = frame.intersection(viewport)
                    let enoughVisible = frame.width > 0 && frame.height > 0 && !intersection.isNull && intersection.width * intersection.height >= frame.width * frame.height * 0.5
                    Color.clear
                        .onChange(of: enoughVisible, initial: true) { _, value in visible = value }
                        .onChange(of: !intersection.isNull && intersection.width > 0 && intersection.height > 0, initial: true) { _, value in
                            anyVisible = value
                            if !value { manuallyStarted = false }
                        }
                }
            }
            .task(id: needsPlayer) {
                guard needsPlayer else {
                    stop()
                    return
                }
                await monitor()
            }
            .onChange(of: retryID) { _, _ in
                stop()
                if needsPlayer { start() }
            }
            .onChange(of: scenePhase) { oldPhase, phase in
                if phase == .active {
                    if resumeAfterBackground && needsPlayer {
                        muted = true; player?.isMuted = true; player?.play()
                    }
                    resumeAfterBackground = false
                } else {
                    if oldPhase == .active {
                        resumeAfterBackground = player.map { $0.timeControlStatus != .paused } ?? false
                    }
                    player?.pause()
                }
            }
            .onDisappear { if !fullscreen { manuallyStarted = false; stop() } }
            .videoPresentation(isPresented: $fullscreen) {
                if let player {
                    FullscreenPostVideo(player: player, description: description, muted: $muted)
                }
            }
            .onChange(of: fullscreen) { _, showing in
                if !showing {
                    muted = player?.isMuted ?? true
                }
            }
    }

    private func start() {
        let video = AVPlayer(url: url)
        video.isMuted = true
        muted = true; ready = false; failed = false; paused = true
        player = video
        if scenePhase == .active { video.play() }
    }
    private func stop() {
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        ready = false; paused = true
    }
    private func monitor() async {
        if player == nil { start() }
        while !Task.isCancelled {
            if let player {
                failed = player.currentItem?.status == .failed || player.status == .failed
                ready = !failed && player.currentItem?.status == .readyToPlay
                paused = player.timeControlStatus == .paused
            }
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
        }
    }
}

private extension View {
    @ViewBuilder
    func videoPresentation<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}

private struct FullscreenPostVideo: View {
    let player: AVPlayer
    let description: String
    @Environment(\.dismiss) private var dismiss
    @Binding var muted: Bool
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player).accessibilityLabel(description)
            HStack {
                VideoOverlayButton(title: muted ? "Attiva audio" : "Disattiva audio",
                                   icon: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                    muted.toggle(); player.isMuted = muted
                }
                Spacer()
                VideoOverlayButton(title: "Chiudi video", icon: "xmark") { dismiss() }
            }.padding().foregroundStyle(.white)
        }
        .onAppear { muted = player.isMuted }
        .accessibilityAction(.escape) { dismiss() }
        #if os(macOS)
        .onExitCommand { dismiss() }
        #endif
        .frame(minWidth: 280, minHeight: 240)
    }
}

private struct VideoOverlayButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 44, height: 44)
                .background(.black.opacity(0.7), in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}
