import Combine
import CoreGraphics
import Foundation

struct ContentPreviewRequest: Equatable, Sendable {
    let card: ContentCard?
    let image: Data?
    let hardware: PocketHardware
    let orientation: HostRendererBridge.Orientation
    /// Reader-resolved inputs when connected, otherwise the labelled reference.
    var style: PreviewStyle = .reference

    /// A reader's own orientation wins over the local preview choice.
    var effectiveOrientation: HostRendererBridge.Orientation { style.orientation ?? orientation }
}

private actor ContentPreviewWorker {
    private var renderer: HostRendererBridge?
    private var hardware: PocketHardware?
    private var orientation: HostRendererBridge.Orientation?

    func render(_ request: ContentPreviewRequest) async throws -> CGImage {
        try Task.checkCancellation()
        let wanted = request.effectiveOrientation
        if renderer == nil || hardware != request.hardware || orientation != wanted {
            let font = try await PreviewFontStore.shared.font()
            try Task.checkCancellation()
            renderer = try HostRendererBridge(font: font, hardware: request.hardware, orientation: wanted)
            hardware = request.hardware
            orientation = wanted
        }
        guard let renderer else { throw HostRendererBridge.Failure.unavailable }
        // The connected reader's resolved inputs (GET display), or the labelled
        // default-theme reference; never an unlabelled assumption.
        let frame = try await renderer.render(card: request.card, image: request.image, options: request.style.options)
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
