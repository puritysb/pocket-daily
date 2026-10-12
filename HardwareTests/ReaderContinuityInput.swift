#if os(macOS)
import AppKit
import Vision
import XCTest

/// Drive the shipping SwiftUI button through its real window event route.
/// Off-screen NSHostingView renders its banner but exposes no AX children.
@MainActor
enum ReaderContinuityInput {
    struct Button {
        let point: NSPoint
        let png: Data
    }

    static func locate(_ label: String, in view: NSView) async throws -> Button {
        let deadline = Date().addingTimeInterval(15)
        func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        var lastImage = Data()
        repeat {
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            lastImage = png
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            recognition.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(data: png).perform([recognition])
            let matches = (recognition.results ?? []).filter {
                normalized($0.topCandidates(1).first?.string ?? "") == normalized(label)
            }
            if matches.count == 1, let match = matches.first {
                let rect = match.boundingBox
                let local = NSPoint(x: view.bounds.minX + rect.midX * view.bounds.width,
                    y: view.bounds.minY + (view.isFlipped ? 1 - rect.midY : rect.midY) * view.bounds.height)
                return Button(point: view.convert(local, to: nil), png: png)
            }
            try await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline
        attach(lastImage, name: "missing-reading-suggestion")
        throw ReaderInterfaceSuite.Failure(message: "No unique visible reading suggestion button: " + label)
    }

    static func press(_ button: Button, in window: NSWindow, name: String) throws {
        attach(button.png, name: name)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: button.point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    private static func attach(_ data: Data, name: String) {
        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = name; attachment.lifetime = .keepAlways; activity.add(attachment)
        }
    }
}
#endif
