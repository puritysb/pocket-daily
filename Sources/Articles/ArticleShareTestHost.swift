#if DEBUG && os(iOS)
import SwiftUI
import UIKit

/// Exercises the real system share extension across its process boundary in simulator UI tests.
struct ArticleShareTestHost: View {
    @State private var sharing = false
    var body: some View {
        Button("Share selected article text") { sharing = true }
            .sheet(isPresented: $sharing) { ShareController() }
    }
    private struct ShareController: UIViewControllerRepresentable {
        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: ["Selected article text shared from another app."], applicationActivities: nil)
        }
        func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
    }
}
#endif
