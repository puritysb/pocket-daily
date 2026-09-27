import UIKit
import SwiftUI
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        Task { @MainActor [weak self] in
            guard let self else { return }
            var link = ""
            var text = ""
            var loadError: String?
            for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
                for provider in item.attachments ?? [] {
                    do {
                        if link.isEmpty, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                            let value = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
                            if let url = value as? URL { link = url.absoluteString }
                        } else if text.isEmpty, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                            let value = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
                            if let value = value as? String {
                                if value.utf8.count <= ArticleRecord.maximumTextBytes { text = value }
                                else { loadError = ArticleError.tooLarge.localizedDescription }
                            }
                        }
                    } catch {
                        loadError = "The shared item could not be loaded. Paste its link or text below."
                    }
                }
            }
            let host = UIHostingController(rootView: ArticleCaptureView(initialURL: link, initialText: text, initialError: loadError) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            })
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            host.didMove(toParent: self)
        }
    }
}
