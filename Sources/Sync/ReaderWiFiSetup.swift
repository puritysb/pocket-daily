import Foundation
import SwiftUI

/// User-selected credentials exist only for this foreground operation. Never
/// Codable, persisted in app defaults, included in diagnostics, or sent over HTTP.
struct ReaderWiFiCredentials {
    let ssid: String
    let password: String

    var validationMessage: String? {
        guard (1...32).contains(ssid.utf8.count),
              !ssid.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return "Enter a Wi-Fi name of 1–32 UTF-8 bytes, without control characters."
        }
        let bytes = Array(password.utf8)
        guard bytes.isEmpty || ((8...63).contains(bytes.count) && bytes.allSatisfy { (32...126).contains($0) })
                || (bytes.count == 64 && bytes.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            return "Use an 8–63 character Wi-Fi password, or a 64-digit hexadecimal key."
        }
        return nil
    }

    func command(requestID: String) -> Data? {
        guard validationMessage == nil, NearbySyncProtocol.startWifi(requestID: requestID) != nil else { return nil }
        func hex(_ text: String) -> String { text.utf8.map { String(format: "%02X", $0) }.joined() }
        let body = "WIFI_JOIN \(requestID) \(hex(ssid)) \(password.isEmpty ? "-" : hex(password))"
        let data = Data(body.utf8)
        return data.count <= NearbySyncProtocol.maximumRecordBytes ? data : nil
    }
}

struct ReaderWiFiSetupReceipt: Codable, Equatable {
    let requestID: String
    let state: String

    func message(for expectedID: String) -> String? {
        guard requestID == expectedID else { return nil }
        switch state {
        case "saved": return "Wi-Fi connected and saved on your reader."
        case "failed": return "The reader could not join that Wi-Fi. Check the name and password. Its previous saved networks are unchanged."
        case "save_failed": return "The reader joined Wi-Fi, but could not save it. Check the reader’s SD card and saved-network limit, then try again."
        default: return nil
        }
    }
}

struct ReaderWiFiSetupView: View {
    @ObservedObject var model: PocketModel
    @ObservedObject var nearby: NearbySyncController
    @ObservedObject var link: ReaderBluetoothLink
    @Environment(\.dismiss) private var dismiss
    @State private var ssid = ""
    @State private var password = ""
    @State private var openNetwork = false
    @State private var submitted = false
    @StateObject private var currentWiFi = CurrentWiFiName()
    @State private var lookupID = 0
    @State private var isFillingWiFi = false
    @State private var autofillMessage: String?

    private var credentials: ReaderWiFiCredentials {
        ReaderWiFiCredentials(ssid: ssid, password: openNetwork ? "" : password)
    }
    private var validation: String? {
        if !openNetwork && password.isEmpty { return "Enter the Wi-Fi password." }
        return credentials.validationMessage
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Reader Wi-Fi").font(PocketDesign.pageTitle)
                Spacer()
                Button("Done") { dismiss() }.disabled(model.isWorking)
            }
            Text("Enter the same Wi-Fi name this device uses. Pocket Daily sends it securely over Bluetooth and saves it on the reader only after it connects.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Use Current Wi-Fi") { isFillingWiFi = true; lookupID += 1 }
                    .accessibilityIdentifier("reader-wifi-use-current")
                    .disabled(isFillingWiFi || model.isWorking || model.isDemoMode)
                if isFillingWiFi { ProgressView().controlSize(.small) }
            }
#if os(macOS)
            Text("Fill in this Mac’s Wi-Fi name and saved password. macOS may ask you to allow keychain access. Location permission is required for the name; your coordinates are not read. You can also enter both yourself.")
                .font(.caption).foregroundStyle(.secondary)
#else
            Text("To fill in the name, Apple requires location permission. Pocket Daily does not read your coordinates. You can also enter the name yourself.")
                .font(.caption).foregroundStyle(.secondary)
#endif
            if let message = currentWiFi.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("reader-wifi-name-result")
            }
            if let autofillMessage {
                Text(autofillMessage).font(.caption).foregroundStyle(.secondary)
            }
            TextField("Wi-Fi name", text: $ssid)
                .textContentType(.none).autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
                .accessibilityIdentifier("reader-wifi-name")
                .disabled(isFillingWiFi || model.isConfiguringReaderWiFi)
            if !openNetwork {
                SecureField("Wi-Fi password", text: $password)
                    .textContentType(.none)
                    .accessibilityIdentifier("reader-wifi-password")
                    .disabled(isFillingWiFi || model.isConfiguringReaderWiFi)
            }
            Toggle("Open network (no password)", isOn: $openNetwork)
                .disabled(isFillingWiFi || model.isConfiguringReaderWiFi)
                .onChange(of: openNetwork) { _, _ in password = "" }
            Text("Use a 2.4 GHz personal Wi-Fi network. Networks requiring a browser sign-in or enterprise account are not supported. Your Mac or iPhone stays on its current Wi-Fi.")
                .font(.caption).foregroundStyle(.secondary)
            if link.rememberedReader == nil {
                Text("Pair once: open Sync → Direct connection on the reader, then enter its pairing code in the system prompt. You do not need to type Wi-Fi details on the reader.")
                    .font(.callout)
                Button("Pair Reader") { nearby.scan() }
                    .disabled(model.isDemoMode || model.isWorking || nearby.ownsBluetooth)
                if let failure = nearby.state.failureMessage { Text(failure).foregroundStyle(.red) }
            } else {
                Text("Keep the paired reader nearby in Bluetooth standby or Direct connection. If it is already connected here over Wi-Fi, the app opens Bluetooth setup for you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let validation, !ssid.isEmpty { Text(validation).font(.caption).foregroundStyle(.secondary) }
            if submitted || model.isConfiguringReaderWiFi {
                Text(model.readerWiFiSetupMessage).font(.callout)
                    .accessibilityIdentifier("reader-wifi-result")
            }
            HStack {
                if model.isConfiguringReaderWiFi { ProgressView().controlSize(.small) }
                Button("Save and Connect") {
                    let value = credentials
                    password = ""
                    submitted = true
                    nearby.disconnect()
                    model.configureReaderWiFi(value)
                }
                .buttonStyle(.borderedProminent).tint(PocketPalette.accent)
                .accessibilityIdentifier("reader-wifi-submit")
                .disabled(isFillingWiFi || validation != nil || link.rememberedReader == nil || model.isWorking || model.isDemoMode || model.hasDirectSession)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(PocketDesign.pageInset)
        }
        .frame(idealWidth: 460, idealHeight: 620)
        .interactiveDismissDisabled(model.isWorking)
        .task(id: lookupID) {
            guard lookupID > 0, !model.isDemoMode else { return }
            isFillingWiFi = true
            autofillMessage = nil
            defer { isFillingWiFi = false }
            if let name = await currentWiFi.read(), !Task.isCancelled {
                if name != ssid {
                    password = ""
                    openNetwork = false
                }
                ssid = name
#if os(macOS)
                autofillMessage = "Waiting for macOS keychain approval. Approve or cancel the system request to continue."
                let saved = await CurrentWiFiName.savedPassword(for: name)
                guard !Task.isCancelled else { return }
                if let saved {
                    password = saved
                    openNetwork = false
                    autofillMessage = "Saved password filled in. Choose Save and Connect when you’re ready."
                } else {
                    autofillMessage = "Wi-Fi name filled in. macOS did not provide a saved password; enter it yourself, or select Open network if it has no password."
                }
#endif
            }
        }
        .onDisappear { password = ""; nearby.disconnect() }
    }
}
