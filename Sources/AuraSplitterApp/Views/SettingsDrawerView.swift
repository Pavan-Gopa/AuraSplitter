import SwiftUI

struct SettingsDrawerView: View {
    @ObservedObject var backend: BackendClient
    @ObservedObject var processPresetStore: ProcessSettingsPresetStore
    @Binding var settings: SeparationSettings
    @Binding var selectedProcessPresetID: String
    @Binding var selectedSection: SettingsDrawerSection
    let applyProcessPresetAction: (String) -> Void
    let closeAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sectionPicker
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Group {
                switch selectedSection {
                case .process:
                    processSection
                case .models:
                    DiagnosticsInspectorView(backend: backend, section: .models)
                case .run:
                    DiagnosticsInspectorView(backend: backend, section: .run)
                case .logs:
                    DiagnosticsInspectorView(backend: backend, section: .logs)
                }
            }
        }
        .background(.regularMaterial)
    }

    private var processSection: some View {
        ControlPaneView(
            backend: backend,
            processPresetStore: processPresetStore,
            settings: $settings,
            selectedProcessPresetID: $selectedProcessPresetID,
            applyProcessPresetAction: applyProcessPresetAction
        )
    }

    private var sectionPicker: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 6),
                count: WorkspaceLayoutMetrics.settingsDrawerTabColumnCount
            ),
            spacing: 6
        ) {
            ForEach(SettingsDrawerSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    Label(section.title, systemImage: section.systemImage)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(selectedSection == section ? .orange : .secondary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sidebar.trailing")
                .foregroundStyle(.secondary)
            Text("Settings")
                .font(.headline)
            Spacer()
            Button(action: closeAction) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Hide settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
