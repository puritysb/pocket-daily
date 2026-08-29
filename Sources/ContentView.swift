import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: PocketModel
    @StateObject private var nearby = NearbySyncController()
    @State private var importing = false
    @State private var choosingSDSource = false
    @State private var choosingSDRoot = false
    @State private var sdSource: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero
                    connectionCard
                    if let status = model.readerStatus { deviceCard(status) }
                    transferCard
                }
                .padding()
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Pocket")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.epub, .data], allowsMultipleSelection: false) {
            if case let .success(urls) = $0, let url = urls.first { model.upload(url) }
        }
        .fileImporter(isPresented: $choosingSDSource, allowedContentTypes: [.epub, .data], allowsMultipleSelection: false) {
            if case let .success(urls) = $0, let url = urls.first {
                sdSource = url
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    choosingSDRoot = true
                }
            }
        }
        .fileImporter(isPresented: $choosingSDRoot, allowedContentTypes: [.folder], allowsMultipleSelection: false) {
            if case let .success(urls) = $0, let root = urls.first, let sdSource {
                model.copyToSD(sdSource, root: root)
                self.sdSource = nil
            }
        }
        .onChange(of: nearby.hotspotLease) { _, lease in
            if let lease { model.useNearbyLease(lease) }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your reader, without a server")
                .font(.largeTitle.bold())
            Text("Books, Japanese study, Today cards, and firmware stay on your Pocket and SD card.")
                .foregroundStyle(.secondary)
        }
    }

    private var connectionCard: some View {
        GroupBox("Connect") {
            VStack(alignment: .leading, spacing: 12) {
                Text(connectionText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Find nearby Pocket") { nearby.scan() }
                        .buttonStyle(.borderedProminent)
                    Button("Use current hotspot") { model.connectToExistingHotspot() }
                        .buttonStyle(.bordered)
                }
                if case .connected = nearby.state {
                    Button("Start private high-speed connection") {
                        do { try nearby.requestHotspot() }
                        catch { model.message = error.localizedDescription }
                    }
                }
                if let lease = nearby.hotspotLease {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Wi-Fi: \(lease.ssid)")
                        Text("Password: \(lease.passphrase)")
                            .textSelection(.enabled)
                        Button("Verify private connection") {
                            Task {
                                await model.verify(
                                    host: lease.host,
                                    httpPort: lease.httpPort,
                                    webSocketPort: lease.webSocketPort
                                )
                            }
                        }
                    }
                    .font(.footnote.monospaced())
                }
                if model.isWorking { ProgressView() }
                Text(model.message).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        }
    }

    private var transferCard: some View {
        GroupBox("Send to Pocket") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Send an EPUB, Pocket content pack, or firmware file over the reader's direct Wi-Fi link.")
                    .foregroundStyle(.secondary)
                Button("Choose file…") { importing = true }
                    .disabled(model.readerStatus == nil || model.isWorking)
#if os(macOS)
                Button("Copy a file directly to SD card…") { choosingSDSource = true }
                    .disabled(model.isWorking)
#endif
                if model.uploadProgress > 0 { ProgressView(value: model.uploadProgress) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    private func deviceCard(_ status: CrossPointStatus) -> some View {
        GroupBox("Reader") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow { Text("Device").foregroundStyle(.secondary); Text(status.device) }
                GridRow { Text("Firmware").foregroundStyle(.secondary); Text(status.version) }
                GridRow { Text("Connection").foregroundStyle(.secondary); Text(status.mode) }
                GridRow { Text("Address").foregroundStyle(.secondary); Text(status.ip) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    private var connectionText: String {
        switch nearby.state {
        case .idle: "Open Nearby Sync on the reader, or use Create Hotspot today."
        case .bluetoothUnavailable: "Bluetooth is unavailable. You can still use the reader hotspot."
        case .scanning: "Looking for a nearby Pocket…"
        case let .connecting(name): "Connecting securely to \(name)…"
        case let .connected(status): "Connected to \(status.model) · \(status.deviceID)"
        case .switchingToHotspot: "Preparing a private high-speed connection…"
        case let .failed(message): message
        }
    }
}
