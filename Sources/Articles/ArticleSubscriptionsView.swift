import SwiftUI

struct ArticleSubscriptionsView: View {
    @ObservedObject var inbox: ArticleInboxModel
    let isDemo: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var error: String?
    @State private var adding = false
    @State private var removing: ArticleFeed?
    @State private var work: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("Follow a publication") {
                    TextField("HTTPS RSS or Atom feed URL", text: $url)
                        .accessibilityIdentifier("feed-url")
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
#endif
                    Button(adding ? "Adding Subscription…" : "Subscribe") { subscribe() }
                        .disabled(isDemo || inbox.isRefreshing || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("feed-subscribe")
                    Text(isDemo ? "Leave demo mode to subscribe. Your saved articles are still available offline." :
                            "Use the RSS or Atom link from a blog, publication or newsletter. We start with its latest 20 articles and save readable text on this device. Email-only newsletters can be saved by sharing their web link or text.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(PocketPalette.critical).accessibilityIdentifier("feed-error") }
                }
                Section("Subscriptions") {
                    if inbox.feeds.isEmpty { Text("Your favourite publications will appear here.").foregroundStyle(.secondary) }
                    ForEach(inbox.feeds) { feed in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(feed.title).font(.headline)
                                Text(URL(string: feed.url)?.host ?? "Subscription").font(.caption).foregroundStyle(.secondary)
                                if let error = feed.lastError {
                                    PocketStatusLabel(error, tone: .failure).font(.caption)
                                } else if let date = feed.lastRefreshedAt {
                                    Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Unsubscribe", systemImage: "minus.circle") { removing = feed }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                                .frame(minWidth: PocketDesign.actionTarget, minHeight: PocketDesign.actionTarget)
                                .contentShape(Rectangle())
                                .accessibilityIdentifier("unsubscribe-\(feed.title)")
                        }.padding(.vertical, 4)
                    }
                }
                Section {
                    Text("New articles refresh when you open the app, or when you choose Refresh. Read articles remain in All Articles. Saved Articles stay here even after you unsubscribe. Nothing is sent to your reader automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Subscriptions")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(adding) }
                if adding {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { work?.cancel() } }
                }
            }
            .confirmationDialog("Unsubscribe from \(removing?.title ?? "this publication")?", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                    if let removing { Button("Unsubscribe", role: .destructive) { Task { await inbox.unsubscribe(removing) } } }
            } message: { Text("All articles already collected, including saved articles, stay on this device.") }
        }
        .interactiveDismissDisabled(adding)
        .onDisappear { work?.cancel() }
#if os(macOS)
        .frame(minWidth: 500, minHeight: 560)
#endif
    }

    private func subscribe() {
        adding = true; error = nil
        work = Task {
            defer { adding = false }
            do { try await inbox.subscribe(url); url = "" }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
