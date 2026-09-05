import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private enum FileImportAction {
        case wirelessUpload
        case sdSource
        case sdRoot
    }

    private struct PendingFirmwareTransfer: Identifiable {
        let id = UUID()
        let url: URL
        let action: FileImportAction
    }

    @EnvironmentObject private var model: PocketModel
    @StateObject private var nearby = NearbySyncController()
    @State private var importing = false
    @State private var importAction: FileImportAction = .wirelessUpload
    @State private var sdSource: URL?
    @State private var pendingFirmwareTransfer: PendingFirmwareTransfer?
    @State private var showingProjectInfo = false

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 920 { desktopStudio } else { compactStudio }
        }
        .background(PocketPalette.workspace)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: importAction == .sdRoot ? [.folder] : [.epub, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            switch importAction {
            case .wirelessUpload:
                prepareTransfer(url, action: .wirelessUpload)
            case .sdSource:
                prepareTransfer(url, action: .sdSource)
            case .sdRoot:
                if let sdSource {
                    model.copyToSD(sdSource, root: url)
                    self.sdSource = nil
                }
            }
        }
        .onChange(of: nearby.hotspotLease) { _, lease in
            if let lease { model.useNearbyLease(lease) }
        }
        .onChange(of: nearby.state) { _, state in
            if case let .connected(status) = state {
                model.selectHardware(named: status.model)
                do { try nearby.requestHotspot() } catch { model.message = error.localizedDescription }
            }
        }
        .sheet(item: $pendingFirmwareTransfer) { transfer in
            FirmwareTransferSheet(
                filename: transfer.url.lastPathComponent,
                cancel: { pendingFirmwareTransfer = nil },
                continueTransfer: {
                    pendingFirmwareTransfer = nil
                    performTransfer(transfer.url, action: transfer.action)
                }
            )
        }
        .sheet(isPresented: $showingProjectInfo) {
            ProjectInformationSheet()
        }
        .task {
            if !model.isDemoMode { model.findOnLocalNetwork() }
        }
    }

    private var desktopStudio: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    desktopHeader
                    previewHeader
                    PocketDevicePreview(
                        hardware: model.hardware,
                        status: model.readerStatus,
                        screenImageData: model.readerScreenImageData
                    )
                        .frame(maxWidth: 430)
                        .frame(height: 590)
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .background(PocketPalette.stage)
            Divider()
            ScrollView { inspector.padding(18) }
                .frame(width: 356)
                .background(PocketPalette.panel)
        }
    }

    private var compactStudio: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    previewHeader
                    PocketDevicePreview(
                        hardware: model.hardware,
                        status: model.readerStatus,
                        screenImageData: model.readerScreenImageData
                    )
                        .frame(maxWidth: 390)
                    inspector
                }
                .padding()
            }
            .navigationTitle("Pocket Daily")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("About", systemImage: "info.circle") { showingProjectInfo = true }
                }
            }
        }
    }

    private var desktopHeader: some View {
        HStack(spacing: 12) {
            PocketMark()
            VStack(alignment: .leading, spacing: 2) {
                Text("Pocket Daily").font(.title2.weight(.semibold))
                Text("LOCAL READER COMPANION")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.0)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("About & Privacy", systemImage: "info.circle") { showingProjectInfo = true }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: 560)
    }

    private var previewHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Reader profile").font(.title2.weight(.semibold))
                    Text("\(model.hardware.screenWidth) × \(model.hardware.screenHeight) · \(model.hardware.controlSummary)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let status = model.readerStatus {
                    Text(status.device)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Color.green.opacity(0.12), in: Capsule())
                } else {
                    Picker("Device", selection: $model.preferredHardware) {
                        ForEach(PocketHardware.allCases) { hardware in
                            Text(hardware.rawValue).tag(hardware)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 112)
                }
            }
            Label(
                model.readerScreenImageData == nil
                    ? "Connect from Pocket Daily Nearby Sync to load the exact reader frame."
                    : "Exact reader frame captured when Nearby Sync opened.",
                systemImage: model.readerScreenImageData == nil ? "rectangle.dashed" : "checkmark.rectangle"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 520)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            ConnectionInspector(model: model, nearby: nearby, onConnect: connect)
            TransferDropZone(isEnabled: model.readerStatus != nil && !model.isDemoMode && !model.isWorking) { urls in
                if let first = urls.first { prepareTransfer(first, action: .wirelessUpload) }
            } choose: {
                importAction = .wirelessUpload
                importing = true
            }
            if model.uploadProgress > 0 && model.uploadProgress < 1 { ProgressView(value: model.uploadProgress) }
            StatusCallout(message: model.message)
#if os(macOS)
            Button("Copy directly to SD card…") {
                importAction = .sdSource
                importing = true
            }
                .buttonStyle(.borderless).disabled(model.isWorking || model.isDemoMode)
#endif
            DeviceSettingsInspector(model: model)
            if !model.isDemoMode {
                TroubleshootingInspector(model: model, nearby: nearby)
            }
        }
    }

    private func connect() {
        model.exitDemoMode()
        model.startConnectionSearch()
        nearby.scan()
    }

    private func prepareTransfer(_ url: URL, action: FileImportAction) {
        guard !model.isDemoMode else {
            model.message = "Exit demo and connect a reader before sending files."
            return
        }
        if url.pathExtension.lowercased() == "bin" {
            pendingFirmwareTransfer = PendingFirmwareTransfer(url: url, action: action)
        } else {
            performTransfer(url, action: action)
        }
    }

    private func performTransfer(_ url: URL, action: FileImportAction) {
        switch action {
        case .wirelessUpload:
            model.upload(url)
        case .sdSource:
            sdSource = url
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                importAction = .sdRoot
                importing = true
            }
        case .sdRoot:
            break
        }
    }
}

private struct PocketMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(PocketPalette.ink)
                .frame(width: 32, height: 38)
            RoundedRectangle(cornerRadius: 3)
                .fill(PocketPalette.paper)
                .frame(width: 22, height: 27)
            Capsule()
                .fill(PocketPalette.accent)
                .frame(width: 10, height: 3)
                .offset(y: 11)
        }
        .accessibilityHidden(true)
    }
}

private struct FirmwareTransferSheet: View {
    let filename: String
    let cancel: () -> Void
    let continueTransfer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(PocketPalette.accent)
                    .frame(width: 48, height: 48)
                    .background(PocketPalette.selection, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stage custom firmware?").font(.title2.weight(.semibold))
                    Text(filename).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SafetyLine(symbol: "checkmark.seal", text: "Pocket validates the ESP32-C3 image structure, checksum, SHA-256 digest, and Nearby Sync identity before staging.")
                SafetyLine(symbol: "checkmark.shield", text: "Use only Pocket Daily or compatible CrossPoint-based firmware for this reader profile.")
                SafetyLine(symbol: "building.2.crop.circle", text: "Factory firmware and manufacturer services are not supported by this app.")
                SafetyLine(symbol: "wrench.and.screwdriver", text: "Custom firmware can affect support or warranty if it causes device damage.")
                SafetyLine(symbol: "hand.tap", text: "Pocket Daily only stages the file. Installation still requires confirmation on the reader.")
            }
            .padding(16)
            .background(PocketPalette.stage, in: RoundedRectangle(cornerRadius: 14))

            Text("Keep a known recovery method available before installing. The selected file remains your responsibility.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("I understand · Continue", action: continueTransfer)
                    .buttonStyle(.borderedProminent)
                    .tint(PocketPalette.ink)
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
#if os(macOS)
        .frame(minWidth: 420, idealWidth: 480)
#endif
        .presentationDetents([.medium])
    }
}

private struct SafetyLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(PocketPalette.ink).frame(width: 20)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProjectInformationSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        PocketMark()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pocket Daily").font(.title2.weight(.semibold))
                            Text("Independent, local-first reader companion")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }

                    InfoSection(title: "Compatibility", symbol: "rectangle.connected.to.line.below") {
                        Text("Designed for X3/X4 hardware running Pocket Daily or compatible CrossPoint-based firmware. Factory firmware and manufacturer cloud services are not supported.")
                    }
                    InfoSection(title: "Independent project", symbol: "person.crop.circle.badge.checkmark") {
                        Text("Pocket Daily is not affiliated with, sponsored by, or endorsed by CrossPoint Reader, Xteink, or any device manufacturer.")
                    }
                    InfoSection(title: "Privacy", symbol: "lock.shield") {
                        Text("No account, analytics, advertising, or cloud relay. Device discovery and transfer stay on Bluetooth and the local network. Pocket Daily does not read your coordinates.")
                    }
                    InfoSection(title: "Firmware responsibility", symbol: "externaldrive.badge.exclamationmark") {
                        Text("Custom firmware can affect device support or warranty. Pocket Daily stages user-selected files but never installs firmware without confirmation on the reader.")
                    }

                    ViewThatFits(in: .horizontal) {
                        projectLinks
                        VStack(alignment: .leading, spacing: 10) {
                Link("Privacy policy", destination: URL(string: "https://puritysb.github.io/pocket-daily/privacy/")!)
                            Link("Open-source notices", destination: URL(string: "https://github.com/puritysb/pocket-daily/blob/main/THIRD_PARTY_NOTICES.md")!)
                            Link("Support", destination: URL(string: "https://github.com/puritysb/pocket-daily/issues")!)
                        }
                    }
                    .font(.callout.weight(.medium))
                }
                .padding(24)
            }
            .navigationTitle("About Pocket Daily")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
#if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
#endif
    }

    private var projectLinks: some View {
        HStack(spacing: 18) {
                            Link("Privacy policy", destination: URL(string: "https://puritysb.github.io/pocket-daily/privacy/")!)
            Link("Open-source notices", destination: URL(string: "https://github.com/puritysb/pocket-daily/blob/main/THIRD_PARTY_NOTICES.md")!)
                            Link("Support", destination: URL(string: "https://puritysb.github.io/pocket-daily/support/")!)
        }
    }
}

private struct InfoSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            content.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PocketPalette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(PocketPalette.line) }
    }
}

/// The single place the app reports what just happened. It used to be a
/// caption-sized secondary line at the bottom of the inspector, which is why a
/// successful firmware transfer was easy to miss. Tone is derived from the
/// message so success, a staged-but-not-installed firmware, and failures are
/// visually distinct without threading extra state through the model.
private struct StatusCallout: View {
    let message: String

    private enum Tone { case success, pending, failure, neutral }

    private var tone: Tone {
        let lower = message.lowercased()
        if lower.hasPrefix("firmware installed") || lower.contains("was verified and published") { return .success }
        if lower.hasPrefix("staged, not installed yet") || lower.hasPrefix("not installed yet") { return .pending }
        if lower.contains("failed") || lower.contains("could not") || lower.contains("cannot")
            || lower.contains("error") || lower.contains("invalid") || lower.contains("not found")
            || lower.contains("interrupted") || lower.contains("ended") {
            return .failure
        }
        return .neutral
    }

    private var symbol: String {
        switch tone {
        case .success: "checkmark.circle.fill"
        case .pending: "arrow.down.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .neutral: "info.circle"
        }
    }

    private var color: Color {
        switch tone {
        case .success: .green
        case .pending: .orange
        case .failure: .red
        case .neutral: .secondary
        }
    }

    private var title: String? {
        switch tone {
        case .success: "Done"
        case .pending: "Staged — install on the reader"
        case .failure: "Attention"
        case .neutral: nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title).font(.subheadline.weight(.semibold))
                }
                Text(message)
                    .font(tone == .neutral ? .caption : .callout)
                    .foregroundStyle(tone == .neutral ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(tone == .neutral ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(tone == .neutral ? Color.clear : color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tone == .neutral ? Color.clear : color.opacity(0.45), lineWidth: 1)
        )
    }
}

private struct ProjectNotice: View {
    var body: some View {
        InspectorCard(title: "ABOUT", symbol: "info.circle") {
            Text("Independent and local-first. Requires Pocket Daily or compatible CrossPoint-based firmware; factory firmware is not supported.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Link("Privacy", destination: URL(string: "https://puritysb.github.io/pocket-daily/privacy/")!)
                Link("Notices", destination: URL(string: "https://github.com/puritysb/pocket-daily/blob/main/THIRD_PARTY_NOTICES.md")!)
                Link("Support", destination: URL(string: "https://puritysb.github.io/pocket-daily/support/")!)
            }
            .font(.caption.weight(.medium))
        }
    }
}

private struct ConnectionInspector: View {
    @ObservedObject var model: PocketModel
    @ObservedObject var nearby: NearbySyncController
    let onConnect: () -> Void

    var body: some View {
        InspectorCard(title: "DEVICE", symbol: "dot.radiowaves.left.and.right") {
            HStack {
                Circle().fill(model.readerStatus == nil ? Color.secondary : Color.green).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.readerStatus?.device ?? model.hardware.displayName).fontWeight(.semibold)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
            }
            Button(model.isDemoMode ? "Exit demo" : (model.readerStatus == nil ? "Find & Connect" : "Reconnect")) {
                if model.isDemoMode { model.exitDemoMode() } else { onConnect() }
            }
                .buttonStyle(.borderedProminent).tint(PocketPalette.ink).frame(maxWidth: .infinity)
            if model.readerStatus == nil, !model.isDemoMode {
                Button("Explore without a reader") { model.enterDemoMode() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            if case .connected = nearby.state {
                Button("Retry private transfer link") {
                    do { try nearby.requestHotspot() } catch { model.message = error.localizedDescription }
                }
                .buttonStyle(.bordered)
            }
            if let lease = nearby.hotspotLease, model.manualHotspotFallback {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Manual Wi-Fi fallback").font(.caption.weight(.semibold))
                    if model.locationPermissionRequired {
                        Text("Location access lets Pocket join this temporary network automatically. Pocket never reads your coordinates.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Location Settings") { model.openLocationSettings() }
                            .buttonStyle(.bordered)
                    }
                    Button("Retry automatic join") { model.useNearbyLease(lease) }
                        .buttonStyle(.borderedProminent)
                    Text(lease.ssid)
                    Text(lease.passphrase).textSelection(.enabled)
                    Button("Verify connection") {
                        Task { await model.verifyNearbyLease(lease) }
                    }
                }
                .font(.caption.monospaced())
                .padding(9)
                .background(PocketPalette.workspace, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var detail: String {
        if model.isDemoMode { return "Local demo · transfers disabled" }
        if let status = model.readerStatus { return "\(status.version) · \(status.mode) · \(status.ip)" }
        if model.manualHotspotFallback { return "Private Wi-Fi needs a manual join" }
        switch nearby.state {
        case .idle: return "Wake the reader to connect"
        case .bluetoothUnavailable: return "Bluetooth unavailable — hotspot still works"
        case .scanning: return "Checking Bluetooth and local Wi-Fi…"
        case let .connecting(name): return "Pairing securely with \(name)…"
        case let .connected(status): return "Bluetooth paired · \(status.deviceID)"
        case .switchingToHotspot: return "Starting private Wi-Fi…"
        case let .failed(message): return message
        }
    }
}

private struct TransferDropZone: View {
    let isEnabled: Bool
    let receive: ([URL]) -> Void
    let choose: () -> Void
    @State private var targeted = false

    var body: some View {
        InspectorCard(title: "SEND TO POCKET", symbol: "arrow.up.doc") {
            VStack(spacing: 10) {
                Image(systemName: targeted ? "arrow.down.doc.fill" : "doc.badge.plus").font(.title2)
                Text(targeted ? "Drop to send" : "Drop a book, study pack, or firmware")
                    .font(.callout.weight(.medium)).multilineTextAlignment(.center)
                Text("EPUB · PDL · BIN").font(.caption2.monospaced()).foregroundStyle(.secondary)
                Button("Choose file…", action: choose).buttonStyle(.bordered).disabled(!isEnabled)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(targeted ? PocketPalette.selection : .clear)
                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(.secondary.opacity(0.55)) }
            )
            .dropDestination(for: URL.self) { urls, _ in
                guard isEnabled else { return false }
                receive(urls)
                return true
            } isTargeted: { targeted = $0 }
            .opacity(isEnabled ? 1 : 0.55)
        }
    }
}

private struct DeviceSettingsInspector: View {
    @ObservedObject var model: PocketModel

    var body: some View {
        InspectorCard(title: "DEVICE SETTINGS", symbol: "slider.horizontal.3") {
            if let preferences = model.preferences {
                Toggle("Start on Pocket Daily", isOn: Binding(
                    get: { preferences.startupApp == 1 }, set: { model.setStartupPocketDaily($0) }
                ))
                Toggle("Keep Daily card while asleep", isOn: Binding(
                    get: { preferences.pocketDailySleepCover }, set: { model.setPocketDailySleepCover($0) }
                ))
                Stepper("Sleep after \(preferences.sleepTimeoutMinutes) min", value: Binding(
                    get: { preferences.sleepTimeoutMinutes }, set: { model.setSleepTimeout($0) }
                ), in: 1 ... 120)
                Picker("Reading size", selection: Binding(
                    get: { preferences.fontSize }, set: { model.setFontSize($0) }
                )) {
                    Text("S").tag(0); Text("M").tag(1); Text("L").tag(2); Text("XL").tag(3)
                }
                .pickerStyle(.segmented)
                Button(model.isDemoMode ? "Demo preview only" : "Apply to \(model.hardware.rawValue)") { model.savePreferences() }
                    .buttonStyle(.bordered).disabled(model.isDemoMode || !model.preferencesDirty || model.isWorking)
            } else {
                Text("Connect to load settings from the reader.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct TroubleshootingInspector: View {
    @ObservedObject var model: PocketModel
    @ObservedObject var nearby: NearbySyncController
    @State private var expanded = false

    var body: some View {
        InspectorCard(title: "TROUBLESHOOTING", symbol: "wrench.and.screwdriver") {
            Button {
                expanded.toggle()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Diagnostics & connection log").font(.callout.weight(.medium))
                        Text(model.crashDiagnostic == nil ? "Open only when a connection needs attention." : "A saved device crash report is available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if let diagnostic = model.crashDiagnostic {
                    DiagnosticsInspector(diagnostic: diagnostic)
                }
                ConnectionTraceInspector(nearby: nearby)
            }
        }
    }
}

private struct DiagnosticsInspector: View {
    let diagnostic: CrashDiagnostic
    @State private var expanded = false

    var body: some View {
        InspectorCard(title: "DIAGNOSTICS", symbol: "waveform.path.ecg") {
            Text("Recorded device crash").font(.callout.weight(.semibold))
            Text(diagnostic.version).font(.caption.monospaced()).textSelection(.enabled)
            Text("Reset: \(diagnostic.resetReason)").font(.caption).textSelection(.enabled)
            Text(diagnostic.reason).font(.caption).textSelection(.enabled)
            if let breadcrumb = diagnostic.breadcrumb {
                Text("Checkpoint: \(breadcrumb)").font(.caption.monospaced()).textSelection(.enabled)
            }
            Text(diagnostic.analysis).font(.caption).foregroundStyle(.secondary)
            Text("Last event: \(diagnostic.lastEvent)")
                .font(.caption2.monospaced()).textSelection(.enabled)
            HStack {
                Button(expanded ? "Hide raw report" : "Show raw report") { expanded.toggle() }
                    .buttonStyle(.bordered)
                ShareLink("Export report", item: diagnostic.report)
            }
            if expanded {
                ScrollView([.horizontal, .vertical]) {
                    Text(diagnostic.report)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                .padding(8)
                .background(PocketPalette.workspace, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct ConnectionTraceInspector: View {
    @ObservedObject var nearby: NearbySyncController
    @State private var expanded = false

    var body: some View {
        InspectorCard(title: "CONNECTION LOG", symbol: "point.3.connected.trianglepath.dotted") {
            Text(nearby.traceAnalysis).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(expanded ? "Hide log" : "Show log") { expanded.toggle() }.buttonStyle(.bordered)
                ShareLink("Export log", item: nearby.traceReport)
            }
            if expanded {
                ScrollView([.horizontal, .vertical]) {
                    Text(nearby.traceReport)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                .padding(8)
                .background(PocketPalette.workspace, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct InspectorCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .background(PocketPalette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).stroke(PocketPalette.line, lineWidth: 1) }
    }
}

enum PocketPalette {
    static let workspace = Color(red: 0.952, green: 0.946, blue: 0.925)
    static let stage = Color(red: 0.925, green: 0.918, blue: 0.888)
    static let panel = Color(red: 0.977, green: 0.973, blue: 0.956)
    static let card = Color.white.opacity(0.72)
    static let paper = Color(red: 0.94, green: 0.93, blue: 0.86)
    static let ink = Color(red: 0.105, green: 0.12, blue: 0.115)
    static let deviceTop = Color(red: 0.105, green: 0.125, blue: 0.12)
    static let deviceBottom = Color(red: 0.055, green: 0.065, blue: 0.062)
    static let accent = Color(red: 0.78, green: 0.46, blue: 0.12)
    static let signal = Color(red: 0.22, green: 0.58, blue: 0.38)
    static let line = Color.black.opacity(0.11)
    static let selection = accent.opacity(0.15)
}
