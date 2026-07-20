import SwiftUI

struct SaveStatesView: View {
    @EnvironmentObject private var emu: EmulatorController
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            VStack {
                HStack {
                    TextField("Save name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        let name = newName.isEmpty ? defaultName() : newName
                        emu.saveCurrentState(named: name)
                        newName = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()

                List {
                    ForEach(emu.saveStates, id: \.id) { state in
                        SaveStateRow(state: state)
                    }
                }
            }
            .navigationTitle("Save States")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func defaultName() -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return "State \(f.string(from: Date()))"
    }
}

struct SaveStateRow: View {
    @EnvironmentObject private var emu: EmulatorController
    @Environment(\.dismiss) private var dismiss
    let state: EmulatorController.SaveState

    var body: some View {
        HStack {
            Group {
                if let thumb = state.thumbnailURL,
                   let data = try? Data(contentsOf: thumb),
                   let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 80, height: 50)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading) {
                Text(state.name).font(.headline)
                Text(state.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Load") {
                emu.loadSaveState(state)
                dismiss()
            }
            .buttonStyle(.bordered)
        }
    }
}
