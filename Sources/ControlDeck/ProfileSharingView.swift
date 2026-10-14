import SwiftUI
import UniformTypeIdentifiers

struct ProfileSharingView: View {
    @ObservedObject var profiles: ProfileStore

    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportDocument = ProfileJSONDocument()
    @State private var importCandidate: ProfileImportCandidate?
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    var body: some View {
        GroupBox("Import and share") {
            HStack(spacing: 18) {
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 46)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Portable JSON profiles")
                        .font(.headline)
                    Text(
                        "Export \(profiles.editingProfile.displayName), or review a shared profile before importing it into any slot."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Import Profile…") {
                    showingImporter = true
                }
                Button("Export \(profiles.editingProfile.displayName)…") {
                    prepareExport()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(8)

            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }

            Divider()

            Label(
                "Imports are data only: the format has no fields for scripts, shell commands, URLs or downloaded code. Files are size-limited and every input, action and setting is validated.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: handleImportSelection
        )
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: ProfileTransfer.safeFilename(
                for: profiles.editingProfile
            )
        ) { result in
            switch result {
            case .success:
                statusMessage = String(localized: "Exported \(profiles.editingProfile.displayName).", bundle: AppResources.localizationBundle)
            case let .failure(error):
                errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $importCandidate) { candidate in
            ProfileImportReviewView(
                candidate: candidate,
                destinations: profiles.profiles,
                onCancel: { importCandidate = nil },
                onImport: { destination, importName, importApps in
                    profiles.importProfile(
                        candidate.shared.profile,
                        into: destination,
                        importName: importName,
                        importAppAssignments: importApps
                    )
                    statusMessage =
                        String(localized: "Imported \(candidate.shared.profile.displayName) into \(profiles.profile(for: destination).displayName).", bundle: AppResources.localizationBundle)
                    importCandidate = nil
                }
            )
        }
        .alert(
            "Couldn’t use this profile",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? String(localized: "The profile could not be read.", bundle: AppResources.localizationBundle))
        }
    }

    private func prepareExport() {
        do {
            exportDocument = ProfileJSONDocument(
                data: try ProfileTransfer.encode(
                    profile: profiles.editingProfile
                )
            )
            statusMessage = nil
            showingExporter = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleImportSelection(
        _ result: Result<[URL], Error>
    ) {
        do {
            guard let url = try result.get().first, url.isFileURL else {
                throw ProfileTransferError.invalidFormat
            }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
            }

            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true
            else {
                throw ProfileTransferError.invalidFormat
            }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(
                upToCount: ProfileTransfer.maximumFileSize + 1
            ) ?? Data()
            let shared = try ProfileTransfer.decode(data)
            statusMessage = nil
            importCandidate = ProfileImportCandidate(
                shared: shared,
                sourceName: url.lastPathComponent
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ProfileJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data = Data()

    init() {}

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw ProfileTransferError.invalidJSON
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct ProfileImportCandidate: Identifiable {
    let id = UUID()
    let shared: SharedControllerProfile
    let sourceName: String
}

private struct ProfileImportReviewView: View {
    let candidate: ProfileImportCandidate
    let destinations: [ControllerProfile]
    let onCancel: () -> Void
    let onImport: (ProfileKind, Bool, Bool) -> Void

    @State private var destination: ProfileKind
    @State private var importName = true
    @State private var importAppAssignments = false

    init(
        candidate: ProfileImportCandidate,
        destinations: [ControllerProfile],
        onCancel: @escaping () -> Void,
        onImport: @escaping (ProfileKind, Bool, Bool) -> Void
    ) {
        self.candidate = candidate
        self.destinations = destinations
        self.onCancel = onCancel
        self.onImport = onImport
        let suggested = destinations.contains {
            $0.kind == candidate.shared.profile.kind
        } ? candidate.shared.profile.kind : destinations.first?.kind ?? .codex
        _destination = State(initialValue: suggested)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review shared profile")
                        .font(.title2.weight(.semibold))
                    Text(candidate.sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("Validated", systemImage: "checkmark.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    reviewRow(String(localized: "Profile", bundle: AppResources.localizationBundle), candidate.shared.profile.displayName)
                    reviewRow(
                        String(localized: "Controls", bundle: AppResources.localizationBundle),
                        String(localized: "\(candidate.shared.profile.bindings.count) buttons · ", bundle: AppResources.localizationBundle) +
                            String(localized: "\(gestureCount) gestures", bundle: AppResources.localizationBundle)
                    )
                    reviewRow(
                        String(localized: "Sticks", bundle: AppResources.localizationBundle),
                        String(localized: "\(candidate.shared.profile.pointer.source.label) pointer · ", bundle: AppResources.localizationBundle) +
                            String(localized: "\(candidate.shared.profile.pointer.scrollSource.label) scroll", bundle: AppResources.localizationBundle)
                    )
                    reviewRow(
                        String(localized: "Exported", bundle: AppResources.localizationBundle),
                        candidate.shared.exportedAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                }
                .padding(8)
            }

            Picker("Import into", selection: $destination) {
                ForEach(destinations) { profile in
                    Text(profile.displayName).tag(profile.kind)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Use the shared profile name", isOn: $importName)
                Toggle(
                    "Import automatic app and window matching",
                    isOn: $importAppAssignments
                )
                Text(
                    importAppAssignments
                        ? String(localized: "The imported app identifiers can activate this profile automatically.", bundle: AppResources.localizationBundle)
                        : String(localized: "Recommended: keep this Mac’s existing app assignments.", bundle: AppResources.localizationBundle)
                )
                .font(.caption)
                .foregroundStyle(
                    importAppAssignments ? Color.orange : Color.secondary
                )
            }

            Label(
                "Importing replaces the controls and sensitivity settings in the selected destination. You can restore its defaults later.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import Profile") {
                    onImport(destination, importName, importAppAssignments)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var gestureCount: Int {
        candidate.shared.profile.touchpad.gestureBindings.count +
            candidate.shared.profile.gyro.gestureBindings.count
    }

    private func reviewRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value)
            Spacer()
        }
        .font(.system(size: 13))
    }
}
