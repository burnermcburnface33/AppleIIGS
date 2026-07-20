import SwiftUI
import UniformTypeIdentifiers

struct DiskManagerView: View {
    @EnvironmentObject private var emu: EmulatorController
    @Environment(\.dismiss) private var dismiss
    @State private var pickerSlot: GSDiskSlot? = nil
    @State private var availableDisks: [URL] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Drives") {
                    ForEach(GSDiskSlot.allCases) { slot in
                        DriveRow(slot: slot, onInsert: {
                            pickerSlot = slot
                        }, onEject: {
                            emu.ejectDisk(slot: slot)
                        })
                    }
                }
                Section {
                    ForEach(availableDisks, id: \.self) { url in
                        HStack {
                            Image(systemName: "opticaldiscdrive.fill")
                            VStack(alignment: .leading) {
                                Text(url.lastPathComponent).font(.headline)
                                Text(humanByteSize(url)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                ForEach(GSDiskSlot.allCases) { slot in
                                    Button(slot.displayName) {
                                        _ = emu.mountDisk(url: url, slot: slot)
                                    }
                                }
                            } label: {
                                Image(systemName: "tray.and.arrow.down.fill")
                            }
                        }
                    }
                    .onDelete(perform: deleteDisks)
                } header: {
                    Text("Library")
                } footer: {
                    HStack(spacing: 6) {
                        Image(systemName: emu.iCloudAvailable ? "icloud.fill" : "internaldrive")
                        Text(emu.iCloudAvailable
                             ? "Synced via iCloud Drive — Apple IIGS folder"
                             : "Stored locally — sign into iCloud to sync across devices")
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Disks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        pickerSlot = .s5D1   // default slot, will be reset after pick
                    } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: Binding(get: { pickerSlot != nil }, set: { if !$0 { pickerSlot = nil } }),
                          allowedContentTypes: diskTypes,
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first, let slot = pickerSlot {
                    _ = emu.mountDisk(url: url, slot: slot)
                    refreshLibrary()
                }
            }
            .task { refreshLibrary() }
        }
    }

    private var diskTypes: [UTType] {
        // ProDOS, DOS 3.3, generic disk image extensions
        let exts = ["2mg", "dsk", "do", "po", "hdv", "nib", "woz"]
        return exts.compactMap { UTType(filenameExtension: $0) ?? UTType.data }
    }

    private func refreshLibrary() {
        let dir = emu.disksDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        availableDisks = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
                          ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }   // hide iCloud .placeholder files
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func deleteDisks(at offsets: IndexSet) {
        for i in offsets {
            try? FileManager.default.removeItem(at: availableDisks[i])
        }
        refreshLibrary()
    }

    private func humanByteSize(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

private struct DriveRow: View {
    @EnvironmentObject private var emu: EmulatorController
    let slot: GSDiskSlot
    let onInsert: () -> Void
    let onEject: () -> Void

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .font(.system(size: 20))
                .frame(width: 28)
            VStack(alignment: .leading) {
                Text(slot.displayName).font(.headline)
                if let name = emu.mountedDiskNames[slot.rawValue] {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Empty").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if emu.mountedDiskNames[slot.rawValue] != nil {
                Button { onEject() } label: {
                    Image(systemName: "eject.fill")
                }
            }
            Button { onInsert() } label: {
                Image(systemName: "tray.and.arrow.down")
            }
        }
    }

    private var iconName: String {
        switch slot {
        case .s5D1, .s5D2: return "opticaldiscdrive"
        case .s6D1, .s6D2: return "opticaldisc"
        case .s7D1, .s7D2: return "externaldrive"
        @unknown default:  return "opticaldiscdrive"
        }
    }
}
