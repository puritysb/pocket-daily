import Combine
import CoreGraphics
import Foundation

struct ContentPreviewRequest: Equatable, Sendable {
    let card: ContentCard?
    let image: Data?
    let hardware: PocketHardware
    let orientation: HostRendererBridge.Orientation
}

private actor ContentPreviewWorker {
    private var renderer: HostRendererBridge?
    private var hardware: PocketHardware?
    private var orientation: HostRendererBridge.Orientation?

    func render(_ request: ContentPreviewRequest) async throws -> CGImage {
        try Task.checkCancellation()
        if renderer == nil || hardware != request.hardware || orientation != request.orientation {
            let font = try await PreviewFontStore.shared.font()
            try Task.checkCancellation()
            renderer = try HostRendererBridge(font: font, hardware: request.hardware, orientation: request.orientation)
            hardware = request.hardware
            orientation = request.orientation
        }
        guard let renderer else { throw HostRendererBridge.Failure.unavailable }
        // Explicit Base-theme/English/unremapped reference configuration, not a
        // claim about connected-reader preferences. Values match BaseTheme.h.
        let options = HostRendererBridge.Options(sidePadding: 20, topPadding: 5, spacing: 10,
            emptyTitle: "Pocket", emptyMessage: "Pocket is ready. Connect briefly to refresh.",
            labels: ["Back", "", "Prev", "Next"])
        let frame = try await renderer.render(card: request.card, image: request.image, options: options)
        try Task.checkCancellation()
        guard let image = frame.image() else { throw HostRendererBridge.Failure.invalidFrame }
        return image
    }
}

@MainActor
final class ContentPreviewModel: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var error: String?
    @Published private(set) var isRendering = false
    private var generation: UInt64 = 0
    private let render: @Sendable (ContentPreviewRequest) async throws -> CGImage
    private let delay: @Sendable () async throws -> Void

    convenience init() {
        let worker = ContentPreviewWorker()
        self.init(render: { try await worker.render($0) })
    }

    init(render: @escaping @Sendable (ContentPreviewRequest) async throws -> CGImage,
         delay: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(180)) }) {
        self.render = render
        self.delay = delay
    }

    func update(_ request: ContentPreviewRequest) async {
        generation &+= 1
        let token = generation
        image = nil
        error = nil
        isRendering = true
        do {
            try await delay()
            try Task.checkCancellation()
            let rendered = try await render(request)
            guard token == generation else { return }
            guard !Task.isCancelled else { isRendering = false; return }
            image = rendered
            isRendering = false
        } catch {
            guard token == generation else { return }
            isRendering = false
            if !(error is CancellationError) && !Task.isCancelled {
                if let invalid = error as? ContentCard.ValidationError {
                    switch invalid {
                    case .identifier: self.error = "Enter a valid card ID to preview."
                    case let .text(field, maximumBytes): self.error = "Complete \(field) within \(maximumBytes) UTF-8 bytes to preview."
                    case .imagePath: self.error = "Choose a valid card image to preview."
                    }
                } else { self.error = error.localizedDescription }
            }
        }
    }

    func cancel() {
        generation &+= 1
        image = nil
        error = nil
        isRendering = false
    }
}
