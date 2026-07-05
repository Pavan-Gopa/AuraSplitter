// ContentView.swift
// Нативный macOS UI для KirtanSplitter

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Главный вид

struct ContentView: View {
    @StateObject private var bridge = PythonBridge()
    @State private var inputURL: URL? = nil
    @State private var outputDir: URL? = nil
    @State private var selectedPreset: String = "kirtan"
    @State private var results: [StemResult] = []
    @State private var isDropTargeted = false
    @State private var startupError: String? = nil
    
    let presets = [
        ("kirtan", "Киртан (3 ступени)", "Вокал → Основной/Бэк → Табла/Инструменты"),
        ("quick", "Быстрое (1 ступень)", "Только вокал / инструменты"),
        ("full", "Полное (6 stems)", "Вокал, барабаны, бас, другое, пианино, гитара"),
    ]
    
    var body: some View {
        HStack(spacing: 0) {
            // Левая панель — управление
            VStack(alignment: .leading, spacing: 20) {
                headerView
                dropZoneView
                presetPickerView
                outputDirView
                Divider()
                actionButtonView
                if bridge.isProcessing { progressView }
                Spacer()
            }
            .padding(24)
            .frame(width: 340)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Правая панель — результаты
            stemsListView
                .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 900, minHeight: 600)
        .task { await startBackend() }
        .alert("Ошибка запуска backend", isPresented: .constant(startupError != nil)) {
            Button("OK") { startupError = nil }
        } message: {
            Text(startupError ?? "")
        }
    }
    
    // MARK: - Subviews
    
    var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("KirtanSplitter")
                    .font(.title2.bold())
                Spacer()
                Circle()
                    .fill(bridge.isReady ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(bridge.isReady ? "Backend готов" : "Запуск...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("BSRoformer · MLX · Apple Silicon")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    var dropZoneView: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isDropTargeted ? Color.orange : Color.secondary.opacity(0.4),
                style: StrokeStyle(lineWidth: 2, dash: [6])
            )
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isDropTargeted ? Color.orange.opacity(0.05) : Color.clear)
            )
            .frame(height: 120)
            .overlay {
                VStack(spacing: 8) {
                    if let url = inputURL {
                        Image(systemName: "waveform")
                            .font(.title)
                            .foregroundStyle(.orange)
                        Text(url.lastPathComponent)
                            .font(.callout.bold())
                            .lineLimit(1)
                        Text("Нажмите чтобы изменить")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("Перетащите аудиофайл")
                            .font(.callout)
                        Text("WAV, FLAC, MP3, AIFF, M4A")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDrop(of: [.audio, .fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }
            .onTapGesture { pickInputFile() }
    }
    
    var presetPickerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Пресет разделения")
                .font(.callout.bold())
            ForEach(presets, id: \.0) { key, name, desc in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: selectedPreset == key ? "record.circle.fill" : "circle")
                        .foregroundStyle(selectedPreset == key ? .orange : .secondary)
                        .onTapGesture { selectedPreset = key }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.callout)
                        Text(desc).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { selectedPreset = key }
            }
        }
    }
    
    var outputDirView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Папка для результатов")
                .font(.callout.bold())
            HStack {
                Text(outputDir?.lastPathComponent ?? "Рядом с файлом")
                    .font(.callout)
                    .foregroundStyle(outputDir == nil ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                Button("Выбрать") { pickOutputDir() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(8)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
    
    var actionButtonView: some View {
        Button(action: startSeparation) {
            HStack {
                if bridge.isProcessing {
                    ProgressView().controlSize(.small)
                    Text("Обработка...")
                } else {
                    Image(systemName: "wand.and.stars")
                    Text("Разделить")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(!bridge.isReady || inputURL == nil || bridge.isProcessing)
        .controlSize(.large)
    }
    
    var progressView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(bridge.currentStage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ProgressView(value: bridge.progress)
                .progressViewStyle(.linear)
                .tint(.orange)
            Text("\(Int(bridge.progress * 100))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
    
    var stemsListView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Заголовок
            HStack {
                Text("Результаты")
                    .font(.headline)
                Spacer()
                if !results.isEmpty {
                    Button("Открыть в Finder") {
                        if let first = results.first {
                            NSWorkspace.shared.selectFile(
                                first.path,
                                inFileViewerRootedAtPath: ""
                            )
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                }
            }
            .padding()
            
            Divider()
            
            if results.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "music.note.tv")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary.opacity(0.4))
                    Text("После разделения здесь появятся файлы")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { stem in
                            StemRowView(stem: stem)
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Actions
    
    func startBackend() async {
        do {
            try await bridge.start()
        } catch {
            startupError = error.localizedDescription
        }
    }
    
    func startSeparation() {
        guard let inputURL else { return }
        
        // Определяем output dir
        let outDir: URL
        if let dir = outputDir {
            outDir = dir.appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent)
        } else {
            outDir = inputURL.deletingLastPathComponent()
                .appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent + "_stems")
        }
        
        Task {
            do {
                let result = try await bridge.separate(
                    inputPath: inputURL.path,
                    outputDir: outDir.path,
                    preset: selectedPreset
                )
                await MainActor.run {
                    results = result.stems.sorted { $0.name < $1.name }
                }
            } catch {
                await MainActor.run {
                    bridge.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { inputURL = url }
                }
                return true
            }
        }
        return false
    }
    
    func pickInputFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { inputURL = panel.url }
    }
    
    func pickOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { outputDir = panel.url }
    }
}

// MARK: - Строка с одним stem

struct StemRowView: View {
    let stem: StemResult
    @State private var isPlaying = false
    @State private var player: AVAudioPlayer? = nil
    
    var stemIcon: String {
        switch stem.name {
        case "vocals", "lead_vocals": return "mic.fill"
        case "backing_vocals": return "mic"
        case "instrumental": return "guitars.fill"
        case "drums": return "music.quarternote.3"
        case "bass": return "waveform.path.badge.minus"
        case "piano": return "pianokeys"
        case "guitar": return "guitars"
        case "no_drums": return "waveform"
        default: return "music.note"
        }
    }
    
    var stemColor: Color {
        switch stem.name {
        case "vocals", "lead_vocals": return .orange
        case "backing_vocals": return .yellow
        case "instrumental", "no_drums": return .blue
        case "drums": return .red
        case "bass": return .purple
        case "piano": return .green
        case "guitar": return .cyan
        default: return .gray
        }
    }
    
    var localizedName: String {
        let names: [String: String] = [
            "vocals": "Вокал",
            "lead_vocals": "Основной вокал",
            "backing_vocals": "Бэк-вокал",
            "instrumental": "Инструменты",
            "drums": "Барабаны (Табла)",
            "no_drums": "Без барабанов",
            "bass": "Бас",
            "piano": "Клавишные",
            "guitar": "Гитара",
            "other": "Другое",
        ]
        return names[stem.name] ?? stem.name
    }
    
    var body: some View {
        HStack(spacing: 14) {
            // Иконка и кнопка play
            ZStack {
                Circle()
                    .fill(stemColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: isPlaying ? "stop.fill" : stemIcon)
                    .foregroundStyle(stemColor)
                    .font(.system(size: 14))
            }
            .onTapGesture { togglePlay() }
            
            // Название и путь
            VStack(alignment: .leading, spacing: 2) {
                Text(localizedName)
                    .font(.callout.bold())
                Text(URL(fileURLWithPath: stem.path).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Кнопки действий
            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.selectFile(stem.path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Показать в Finder")
                
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(stem.path, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Скопировать путь")
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
    
    func togglePlay() {
        if isPlaying {
            player?.stop()
            isPlaying = false
        } else {
            let url = URL(fileURLWithPath: stem.path)
            player = try? AVAudioPlayer(contentsOf: url)
            player?.play()
            isPlaying = true
            // Автостоп когда файл закончится
            DispatchQueue.main.asyncAfter(deadline: .now() + (player?.duration ?? 0)) {
                isPlaying = false
            }
        }
    }
}

// MARK: - App Entry

@main
struct KirtanSplitterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
