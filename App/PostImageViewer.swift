import SwiftUI
import OpenBookCore

struct PostImageSelection: Identifiable {
    let id: String
    let url: URL
    let description: String
}

extension View {
    @ViewBuilder
    func imageViewer(selection: Binding<PostImageSelection?>) -> some View {
        #if os(iOS)
        fullScreenCover(item: selection) { PostImageViewer(selection: $0) }
        #else
        sheet(item: selection) { PostImageViewer(selection: $0) }
        #endif
    }
}

/// Full-size attachments and profile photos share gestures, accessibility and loading states.
struct PostImageViewer: View {
    let selection: PostImageSelection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0
    @State private var retryID = UUID()
    @State private var zoom = ImageZoom()
    @State private var imageSize: CGSize = .zero
    @State private var pinchStart: ImageZoom?
    @State private var panStart: CGSize?
    @State private var panWasZoomed = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            GeometryReader { geometry in
                AsyncImage(url: selection.url) { phase in
                    switch phase {
                    case .success(let image):
                        zoomableImage(image, viewport: geometry.size)
                    case .failure:
                        VStack(spacing: 16) {
                            Label("Immagine non disponibile", systemImage: "photo")
                            Button("Riprova") { retryID = UUID() }.buttonStyle(.bordered)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(dismissGesture)
                    default:
                        ProgressView("Caricamento immagine…").tint(.white).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .gesture(dismissGesture)
                    }
                }
                .id(retryID)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .offset(y: dragOffset)
            }
            .contentShape(Rectangle())
            .clipped()

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .accessibilityLabel("Chiudi immagine")
            .keyboardShortcut(.cancelAction)
            .padding(16)
        }
        .preferredColorScheme(.dark)
        .accessibilityAction(.escape) { dismiss() }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 900, minHeight: 360, idealHeight: 700)
        #endif
    }

    private func zoomableImage(_ image: Image, viewport: CGSize) -> some View {
        image.resizable().scaledToFit()
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { imageSize = geometry.size }
                        .onChange(of: geometry.size) { _, size in
                            imageSize = size
                            zoom.constrain(imageSize: size, viewport: viewport)
                        }
                }
            }
            .scaleEffect(zoom.scale)
            .offset(zoom.offset)
            .frame(width: viewport.width, height: viewport.height)
            .contentShape(Rectangle())
            .gesture(imageGesture(viewport: viewport))
            .onTapGesture(count: 2) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    if zoom.isZoomed { zoom.reset() }
                    else { zoom.magnify(to: 3, imageSize: imageSize, viewport: viewport) }
                }
            }
            .onChange(of: viewport) { _, size in zoom.constrain(imageSize: imageSize, viewport: size) }
            .accessibilityLabel(selection.description)
            .accessibilityValue("Zoom \(Int(zoom.scale * 100)) per cento")
            .accessibilityHint("Allarga con due dita per ingrandire. Doppio tocco per ingrandire o ripristinare. Alla dimensione iniziale, scorri verso il basso per chiudere.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: zoom.magnify(to: zoom.scale + 1, imageSize: imageSize, viewport: viewport)
                case .decrement: zoom.magnify(to: zoom.scale - 1, imageSize: imageSize, viewport: viewport)
                @unknown default: break
                }
            }
            .accessibilityAction(named: Text("Ripristina zoom")) { zoom.reset() }
    }

    private func imageGesture(viewport: CGSize) -> some Gesture {
        MagnifyGesture().simultaneously(with: DragGesture(minimumDistance: 16))
            .onChanged { value in
                if let pinch = value.first {
                    if pinchStart == nil { pinchStart = zoom }
                    guard let initial = pinchStart else { return }
                    zoom = initial
                    zoom.magnify(to: initial.scale * pinch.magnification,
                                 anchor: CGPoint(x: (pinch.startAnchor.x - 0.5) * viewport.width,
                                                 y: (pinch.startAnchor.y - 0.5) * viewport.height),
                                 imageSize: imageSize, viewport: viewport)
                    dragOffset = 0
                } else if let drag = value.second, pinchStart == nil {
                    if panStart == nil { panStart = zoom.offset; panWasZoomed = zoom.isZoomed }
                    if panWasZoomed {
                        zoom.pan(from: panStart ?? .zero, translation: drag.translation,
                                 imageSize: imageSize, viewport: viewport)
                    } else { updateDismissDrag(drag) }
                }
            }
            .onEnded { value in
                defer { pinchStart = nil; panStart = nil; panWasZoomed = false }
                // Even a pinch returning to 1x must not be interpreted as a dismiss swipe.
                if pinchStart != nil || value.first != nil || panWasZoomed { dragOffset = 0; return }
                if let drag = value.second { endDismissDrag(drag) }
            }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged(updateDismissDrag)
            .onEnded(endDismissDrag)
    }

    private func updateDismissDrag(_ value: DragGesture.Value) {
        guard value.translation.height > 0,
              value.translation.height > abs(value.translation.width) else { return }
        dragOffset = value.translation.height
    }

    private func endDismissDrag(_ value: DragGesture.Value) {
        let down = value.translation.height
        let vertical = down > abs(value.translation.width)
        if vertical && (down > 110 || (down > 35 && value.predictedEndTranslation.height > 220)) {
            dismiss()
        } else {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
                dragOffset = 0
            }
        }
    }
}
