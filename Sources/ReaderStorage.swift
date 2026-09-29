import Foundation
import SwiftUI

struct ReaderFilePage: Decodable {
    struct Entry: Decodable, Identifiable {
        let name: String
        let directory: Bool
        let size: Int64
        let deletable: Bool
        var id: String { name }
    }
    let deviceID: String
    let path: String
    let entries: [Entry]
    let nextCursor: Int

    func validate(identity: String, folder: String, cursor: Int) throws {
        guard deviceID == identity, path == folder, entries.count <= 12,
              nextCursor == 0 || (nextCursor > cursor && nextCursor <= 8 * 1024 * 1024 && nextCursor % 32 == 0),
              Set(entries.map(\.name)).count == entries.count,
              entries.allSatisfy({ !$0.name.isEmpty && !$0.name.hasPrefix(".") && !$0.name.contains("/")
                  && !$0.name.contains("\\") && !$0.name.contains("%")
                  && !$0.name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) && $0.size >= 0 }) else {
            throw CrossPointClient.ClientError.unexpectedMessage("Invalid reader file list. Reconnect and try again.")
        }
    }
}
struct ReaderSpaceChunk: Decodable {
    let deviceID: String
    let totalBytes: Int64
    let freeBytes: Int64
    let nextCursor: Int
    let supported: Bool
}
struct ReaderSpaceUsage {
    let deviceID: String
    let total: Int64
    let free: Int64?
}

struct ReaderStoragePanel: View {
    @ObservedObject var model: PocketModel
    @State private var browsing = false
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .binary) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let status = model.readerStatus {
                HStack {
                    Label("RAM", systemImage: "memorychip")
                    Spacer()
                    Text("\(bytes(Int64(max(0, status.freeHeap)))) free")
                        .font(.caption.monospacedDigit())
                }
                if let total = status.totalHeap, total > 0, status.freeHeap >= 0, status.freeHeap <= total {
                    ProgressView(value: Double(total - status.freeHeap), total: Double(total))
                        .progressViewStyle(.pocketBar(tint: .secondary))
                        .accessibilityLabel("RAM used")
                        .accessibilityValue("\(Int(100 * Double(total - status.freeHeap) / Double(total))) percent")
                    Text("\(Int(100 * Double(total - status.freeHeap) / Double(total)))% used · working memory")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Working memory · this firmware reports free space only")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Label("SD card · books & articles", systemImage: "sdcard")
                if model.isDemoMode {
                    ProgressView(value: 0.25).progressViewStyle(.pocketBar)
                    Text("Example · 2 GB used / 8 GB").font(.caption).foregroundStyle(.secondary)
                } else if let usage = model.readerSpace, usage.deviceID == status.deviceID {
                    if let free = usage.free, usage.total > 0 {
                        ProgressView(value: Double(usage.total - free), total: Double(usage.total)).progressViewStyle(.pocketBar)
                        Text("\(bytes(usage.total - free)) used / \(bytes(usage.total))")
                            .font(.caption.monospacedDigit())
                    } else {
                        Text("\(bytes(usage.total)) capacity · usage unavailable for this format")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.isReadingStorage {
                    ProgressView("Reading SD card…").font(.caption)
                    Button("Cancel") { model.cancelStorageRead() }
                } else if model.isDemoMode {
                    Text("Connect a reader to browse its SD card.").font(.caption).foregroundStyle(.secondary)
                } else if status.readerFiles == 1 {
                    HStack {
                        Button("Browse files") { browsing = true }.accessibilityIdentifier("reader-browse-files")
                        Spacer()
                        Button(model.readerSpace?.deviceID == status.deviceID ? "Refresh usage" : "Check usage") { model.refreshReaderSpace() }.font(.caption)
                    }
                    .disabled(model.isWorking || model.isDemoMode)
                } else {
                    Text("Update reader firmware to view SD usage and manage files in Sync.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.readerFilesError { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .font(.callout)
        .sheet(isPresented: $browsing) { ReaderFileBrowser(model: model) }
    }
}

private struct ReaderFileBrowser: View {
    @ObservedObject var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    @State private var folder = "/"
    @State private var deletion: ReaderFilePage.Entry?
    @State private var deletionIdentity: String?
    private var page: ReaderFilePage? {
        guard model.readerFilePage?.deviceID == model.readerStatus?.deviceID,
              model.readerFilePage?.path == folder else { return nil }
        return model.readerFilePage
    }
    private func path(_ name: String) -> String { folder == "/" ? "/" + name : folder + "/" + name }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Label("SD card \(folder)", systemImage: "folder").font(.headline)
                Text("Books you send appear here. Deleting a reading file also removes its reader progress; your app’s original stays.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if folder != "/" {
                        Button("Parent folder", systemImage: "arrow.up") {
                            folder = (folder as NSString).deletingLastPathComponent
                            if folder.isEmpty { folder = "/" }
                            model.loadReaderFiles(folder)
                        }
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") { model.loadReaderFiles(folder) }
                    Spacer()
                    if model.isWorking { ProgressView() }
                }.disabled(model.isWorking)
                if model.isReadingStorage { Button("Cancel") { model.cancelStorageRead() } }
                if let error = model.readerFilesError { Text(error).font(.callout).foregroundStyle(.red) }
                List {
                    ForEach(page?.entries ?? []) { entry in
                        HStack {
                            Image(systemName: entry.directory ? "folder" : "doc.text")
                            VStack(alignment: .leading) {
                                Text(entry.name).lineLimit(2)
                                if !entry.directory {
                                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if entry.directory {
                                Button("Open") { folder = path(entry.name); model.loadReaderFiles(folder) }
                            } else if entry.deletable {
                                Button("Delete", role: .destructive) { deletionIdentity = page?.deviceID; deletion = entry }
                            } else { Text("Read only").font(.caption).foregroundStyle(.secondary) }
                        }.disabled(model.isWorking || model.readerStatus == nil)
                    }
                    if let page, page.nextCursor > 0 {
                        Button("Next files") { model.loadReaderFiles(folder, cursor: page.nextCursor) }
                            .disabled(model.isWorking)
                    } else if page?.entries.isEmpty == true {
                        Text("No visible files in this folder.").foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .navigationTitle("Reader files")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { model.loadReaderFiles(folder) }
            .confirmationDialog("Delete from SD card?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
                if let entry = deletion {
                    Button("Delete \(entry.name)", role: .destructive) {
                        model.deleteReaderFile(path(entry.name), size: entry.size, folder: folder, identity: deletionIdentity)
                        deletion = nil
                    }
                }
            } message: {
                Text(deletion.map { "SD card \(path($0.name))\nThis cannot be undone on the reader." } ?? "")
            }
        }
        .frame(minWidth: 320, minHeight: 420)
    }
}
