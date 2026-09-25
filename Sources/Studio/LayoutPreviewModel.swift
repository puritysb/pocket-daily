import Combine
import CoreGraphics
import Foundation

/// A Home or Daily Brief frame drawn by the firmware's own painter with the
/// labelled sample content (never the reader's real data).
struct LayoutPreviewRequest: Equatable, Sendable {
    enum Surface: Sendable { case home, brief }
    let profile: PocketProfile
    let surface: Surface
    let hardware: PocketHardware
    var orientation: HostRendererBridge.Orientation = .portrait
    var samples: HostRendererBridge.LayoutSamples = .all
}

private actor LayoutPreviewWorker {
    private var renderer: HostRendererBridge?
    private var key: (PocketHardware, HostRendererBridge.Orientation)?

    func render(_ request: LayoutPreviewRequest) async throws -> CGImage {
        try Task.checkCancellation()
        if renderer == nil || key?.0 != request.hardware || key?.1 != request.orientation {
            let font = try await PreviewFontStore.shared.font()
            try Task.checkCancellation()
            renderer = try HostRendererBridge(font: font, hardware: request.hardware, orientation: request.orientation)
            key = (request.hardware, request.orientation)
        }
        guard let renderer else { throw HostRendererBridge.Failure.unavailable }
        let frame = switch request.surface {
        case .home: try await renderer.renderHome(profile: request.profile, samples: request.samples)
        case .brief: try await renderer.renderBrief(profile: request.profile, samples: request.samples)
        }
        try Task.checkCancellation()
        guard let image = frame.image() else { throw HostRendererBridge.Failure.invalidFrame }
        return image
    }
}

@MainActor
final class LayoutPreviewModel: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var error: String?
    private var generation: UInt64 = 0
    private let render: @Sendable (LayoutPreviewRequest) async throws -> CGImage

    convenience init() {
        let worker = LayoutPreviewWorker()
        self.init(render: { try await worker.render($0) })
    }

    init(render: @escaping @Sendable (LayoutPreviewRequest) async throws -> CGImage) {
        self.render = render
    }

    /// Keeps the previous frame on screen until the new one is ready, so
    /// toggling a control does not flash the canvas.
    func update(_ request: LayoutPreviewRequest) async {
        generation &+= 1
        let token = generation
        do {
            let rendered = try await render(request)
            guard token == generation, !Task.isCancelled else { return }
            image = rendered
            error = nil
        } catch {
            guard token == generation, !(error is CancellationError), !Task.isCancelled else { return }
            image = nil
            self.error = error.localizedDescription
        }
    }
}
