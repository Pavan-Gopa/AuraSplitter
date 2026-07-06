import SwiftUI

struct SettingsDrawerView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case process = "Process"
        case system = "System"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .process: return "slider.horizontal.3"
            case .system: return "gauge"
            }
        }
    }

    @ObservedObject var backend: BackendClient
    @Binding var outputDirectory: URL?
    @Binding var settings: SeparationSettings
    @Binding var isDropTargeted: Bool

    let sources: [BatchSourceItem]
    let chooseFilesAction: ([URL]) -> Void
    let chooseFolderAction: (URL) -> Void
    let droppedURLAction: (URL) -> Void
    let startAction: () -> Void
    let closeAction: () -> Void
    @State private var selectedSection: Section = .process

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
                case .system:
                    systemSection
                }
            }
        }
        .background(.regularMaterial)
    }

    private var processSection: some View {
        ControlPaneView(
            backend: backend,
            outputDirectory: $outputDirectory,
            settings: $settings,
            isDropTargeted: $isDropTargeted,
            sources: sources,
            chooseFilesAction: chooseFilesAction,
            chooseFolderAction: chooseFolderAction,
            droppedURLAction: droppedURLAction,
            startAction: startAction,
            showsHeader: false
        )
    }

    private var systemSection: some View {
        DiagnosticsInspectorView(backend: backend)
    }

    private var sectionPicker: some View {
        HStack(spacing: 6) {
            ForEach(Section.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    Label(section.rawValue, systemImage: section.systemImage)
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
