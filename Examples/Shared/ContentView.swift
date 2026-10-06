import SwiftUI
import IrodoriTTS
import UniformTypeIdentifiers

private enum StudioStyle {
    static let accent = adaptive(light: (0.08, 0.43, 0.39), dark: (0.42, 0.79, 0.71))
    static let buttonInk = adaptive(light: (1, 1, 1), dark: (0.06, 0.15, 0.13))
    static let mutedAccent = Color(red: 0.68, green: 0.87, blue: 0.79)
    static let canvas = adaptive(light: (0.955, 0.963, 0.960), dark: (0.085, 0.095, 0.098))
    static let surface = adaptive(light: (1, 1, 1), dark: (0.125, 0.138, 0.140))
    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        #if os(iOS)
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.0, green: value.1, blue: value.2, alpha: 1)
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        })
        #endif
    }
}

struct ContentView: View {
    @StateObject private var model = SampleModel()
    @State private var importing = false
    @State private var importKind: ImportKind = .model
    @State private var downloadExpanded = false
    @State private var managingModels = false
    @State private var modelToDelete: SampleModel.InstalledModel?
    @State private var deletingPartial = false
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @State private var exportingWAV = false
    @State private var wavDocument: SampleWAVDocument?
    #endif
    @FocusState private var focusedField: Field?
    private enum Field { case text, caption, url }
    private enum ImportKind { case model, reference }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if model.needsSetup || model.shouldShowDownload { modelSetup }
                    if geometry.size.width >= 840 {
                        HStack(alignment: .top, spacing: 24) {
                            workspace.frame(maxWidth: .infinity)
                            settings.frame(width: 310)
                        }
                    } else {
                        workspace
                        settings
                    }
                    Text("Irodori TTS v4.1 Small MF · Community Core ML")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .padding(geometry.size.width >= 840 ? 32 : 20)
                .frame(maxWidth: 1160)
                .frame(maxWidth: .infinity)
            }
            .background(StudioStyle.canvas)
            .scrollDismissesKeyboard(.interactively)
        }
        .tint(StudioStyle.accent)
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.pauseDownload() }
        }
        #endif
        .sheet(isPresented: $managingModels) { modelManager }
        .confirmationDialog("中断した取得データを削除しますか？", isPresented: $deletingPartial) {
            Button("取得データを削除", role: .destructive) { model.discardPendingDownload() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("途中まで取得したファイルを削除します。保存済みモデルと登録音声は削除しません。")
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: importKind == .model ? [.folder] : [.audio]) { result in
            switch result {
            case .success(let url):
                if importKind == .model { model.importModel(url) }
                else { model.importReference(url) }
            case .failure(let error): model.report(error)
            }
        }
        #if os(macOS)
        .fileExporter(isPresented: $exportingWAV, document: wavDocument,
                      contentType: .wav, defaultFilename: "irodori") { result in
            switch result {
            case .success: model.status = "WAVを保存しました。"
            case .failure(let error): model.report(error)
            }
        }
        #endif
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") { focusedField = nil }
            }
        }
        #endif
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(StudioStyle.accent)
                .frame(width: 54, height: 54)
                .background(StudioStyle.mutedAccent.opacity(0.45), in: RoundedRectangle(cornerRadius: 17))
            VStack(alignment: .leading, spacing: 3) {
                Text("Irodori").font(.system(size: 32, weight: .bold, design: .rounded))
                Text("オンデバイス音声合成").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("Core ML")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.primary.opacity(0.05), in: Capsule())
        }
    }

    private var modelSetup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(model.needsSetup ? "はじめにモデルを準備" : "モデルの取得", systemImage: "arrow.down.circle")
                .font(.title3.weight(.semibold))
            if model.needsSetup {
                Text("モデルを取得したら、下の文章を「生成して再生」で読み上げられます。声の登録はあとから追加できます。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if model.downloading {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(model.downloadPhase).font(.subheadline.weight(.medium))
                        Spacer()
                        if let progress = model.downloadProgress, progress.totalBytes > 0 {
                            Text(progress.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                                .font(.caption.monospacedDigit())
                        }
                    }
                    if let progress = model.downloadProgress, progress.totalBytes > 0 {
                        ProgressView(value: progress.fractionCompleted)
                            .accessibilityIdentifier("downloadProgress")
                        Text(model.downloadAmount).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else { ProgressView().controlSize(.small) }
                    Text("完了までアプリを開いたままお待ちください。画面を切り替えると取得を中断し、戻ってから再開できます。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("ダウンロードを中断", action: model.pauseDownload).buttonStyle(.bordered)
                        .accessibilityIdentifier("pauseDownload")
                }
            } else if !model.pendingDownloadURL.isEmpty {
                Label("ダウンロードを再開できます", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
                Text("アプリを開いたまま再開してください。通信エラーの場合は接続も確認してください。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("検証済みのファイルは再利用します。中断したファイルは先頭から取得します。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("再開する", action: model.retryDownload)
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("retryDownload")
                    Button("取得データを削除", role: .destructive) { deletingPartial = true }
                        .buttonStyle(.bordered).accessibilityIdentifier("discardDownload")
                }.font(.subheadline).disabled(model.busy || model.recording)
            } else { downloadControls }
        }.studioCard()
    }

    private var downloadControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("取得するモデル", selection: $model.downloadVariant) {
                ForEach(ModelVariant.allCases) { variant in
                    Text("\(variant.title) · \(SampleModel.bytes(variant.approximateBytes))").tag(variant)
                }
            }
            .pickerStyle(.menu).accessibilityIdentifier("downloadVariant")
            Text(model.downloadVariant == .standard
                 ? "標準FP32版。音質比較の基準となるモデルです。"
                 : "容量を抑えたINT8版。モデルの選択後も音声登録と話し方の指定が使えます。")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(model.downloadVariant.minimumOS)以降 · Wi-Fiでの取得をおすすめします。")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.downloadSpaceGuidance).font(.caption2).foregroundStyle(.secondary)
            Button(action: model.downloadSelectedVariant) {
                Label("モデルをダウンロード", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent).accessibilityIdentifier("downloadModel")
            .disabled(!model.downloadVariant.isSupported)
        }.disabled(model.busy || model.recording || !model.pendingDownloadURL.isEmpty)
    }

    private var modelManager: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("保存済みモデル").font(.title3.weight(.semibold))
                Spacer()
                Button("閉じる") { managingModels = false }.disabled(model.busy)
            }
            Text("使わないモデルを削除して空き容量を確保できます。削除したモデルは再取得できます。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.installedModels) { installed in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(installed.information.description).font(.subheadline.weight(.medium))
                                Text(installed.id == model.modelPath ? "使用中" : "保存済み")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if installed.id != model.modelPath {
                                Button("使う") { model.selectModel(installed.id) }
                            }
                            if model.canDeleteModel(installed) {
                                Button(role: .destructive) {
                                    modelToDelete = installed
                                } label: { Image(systemName: "trash") }
                                .accessibilityLabel("\(installed.information.description)を削除")
                            }
                        }.disabled(model.busy || model.recording)
                        Divider()
                    }
                    if model.installedModels.isEmpty { Text("保存済みモデルはありません。").font(.subheadline) }
                }
            }
        }
        .padding(24).frame(idealWidth: 520, maxWidth: 680, minHeight: 260, idealHeight: 420)
        .confirmationDialog("保存済みモデルを削除しますか？", isPresented: Binding(
            get: { modelToDelete != nil }, set: { if !$0 { modelToDelete = nil } }), presenting: modelToDelete) { installed in
                Button("モデルを削除", role: .destructive) { model.deleteModel(installed); modelToDelete = nil }
                Button("キャンセル", role: .cancel) { modelToDelete = nil }
            } message: { installed in
                Text("\(installed.information.description)をこのアプリから削除します。再度ダウンロードできます。登録音声と書き出したWAVは削除しません。")
            }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 18) {
            composer
            if let result = model.result {
                metrics(result)
                playback
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("読み上げるテキスト", systemImage: "text.alignleft").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.text.count) 文字").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text("声にしたい文章を入力してください。")
                        .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.text)
                    .accessibilityIdentifier("speechText")
                    .font(.system(size: 18)).lineSpacing(7)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180, maxHeight: 240)
                    .focused($focusedField, equals: .text)
                    .disabled((model.busy && !model.downloading) || model.recording)
            }
            Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
            HStack(spacing: 12) {
                Button {
                    focusedField = nil
                    model.speak()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "waveform")
                        Text(model.busy ? "処理中…" : "生成して再生")
                    }
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                }
                .buttonStyle(GenerateButtonStyle())
                .accessibilityIdentifier("speak")
                .disabled(model.busy || model.recording || model.modelPath.isEmpty || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.busy || model.isPlaying {
                    Button(action: model.stop) {
                        Image(systemName: "stop.fill").frame(width: 48, height: 48)
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14))
                    .accessibilityLabel("停止").accessibilityIdentifier("stop")
                }
            }
            HStack(alignment: .top, spacing: 9) {
                if model.busy { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: model.errorMessage != nil ? "exclamationmark.circle" : "circle.fill")
                        .font(.system(size: model.errorMessage != nil ? 14 : 6))
                        .padding(.top, model.errorMessage != nil ? 1 : 5)
                }
                Text(model.status).accessibilityIdentifier("status")
                    .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(model.errorMessage != nil ? Color.red : Color.secondary)
        }
        .studioCard()
    }

    private func metrics(_ result: SynthesisResult) -> some View {
        HStack(spacing: 0) {
            metric("RTF", value: String(format: "%.3f", result.rtf))
            Divider().frame(height: 34)
            metric("生成時間", value: String(format: "%.2f s", result.synthesisMilliseconds / 1000))
            Divider().frame(height: 34)
            metric("音声の長さ", value: String(format: "%.2f s", result.audioSeconds))
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("statistics")
        .accessibilityElement(children: .combine)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity)
    }

    private var playback: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("生成した音声").font(.subheadline.weight(.semibold))
                Spacer()
                if let url = model.outputURL {
                    #if os(macOS)
                    Button {
                        do {
                            wavDocument = SampleWAVDocument(data: try Data(contentsOf: url))
                            exportingWAV = true
                        } catch { model.report(error) }
                    } label: { Label("WAVを保存", systemImage: "square.and.arrow.down") }
                    .accessibilityIdentifier("saveOutput")
                    .font(.caption.weight(.medium)).disabled(model.busy || model.recording)
                    #else
                    ShareLink(item: url) { Label("WAVを保存", systemImage: "square.and.arrow.up") }
                        .font(.caption.weight(.medium)).disabled(model.busy || model.recording)
                    #endif
                }
            }
            HStack(spacing: 14) {
                Button(action: model.togglePlayback) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .background(StudioStyle.accent.opacity(0.09), in: Circle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("playOutput")
                .accessibilityLabel(model.isPlaying ? "一時停止" : "生成音声を再生")
                .disabled(model.busy || model.recording)
                GeometryReader { geometry in
                    HStack(spacing: 3) {
                        ForEach(Array(model.waveform.enumerated()), id: \.offset) { index, value in
                            Capsule()
                                .fill(Double(index) / Double(max(model.waveform.count, 1)) < model.playbackFraction
                                      ? StudioStyle.accent : StudioStyle.accent.opacity(0.2))
                                .frame(width: max(2, (geometry.size.width - 3 * CGFloat(model.waveform.count - 1)) / CGFloat(max(model.waveform.count, 1))),
                                       height: max(4, CGFloat(value) * 36))
                        }
                    }.frame(height: 40)
                }.frame(height: 40)
                Text(model.playbackTime).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("AIによる合成音声 · AudioSeal透かし付き · 48 kHz / WAV")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .studioCard()
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            modelSettings
            voiceSettings
            DisclosureGroup("プライバシーと利用条件") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("入力した文章、録音、参照音声は端末内で処理し、外部へ送信しません。モデル取得時はHugging Faceへ接続します。共有・保存は自分で選んだときに行います。")
                    Text("自分の声、または明示的に許可を得た声を登録してください。生成音声にはAudioSealの透かしを付与します。")
                    Link("モデルと利用条件", destination: URL(string: "https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML")!)
                    Link("SDK・サンプルとライセンス", destination: URL(string: "https://github.com/Corvelis/irodori-tts-coreml")!)
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 10)
            }.font(.caption).studioCard()
        }
    }

    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("モデル", systemImage: "cpu").font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.modelPath.isEmpty ? "未取得" : model.ready ? "準備済み" : "選択済み")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.modelPath.isEmpty ? Color.secondary : StudioStyle.accent)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(StudioStyle.accent.opacity(0.07), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Irodori v4.1 Small MF").font(.subheadline.weight(.medium))
                Text(model.modelDetail).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("modelDetail")
            }
            if !model.installedModels.isEmpty {
                Picker("保存済みモデル", selection: Binding(get: { model.modelPath }, set: { model.selectModel($0) })) {
                    if model.modelPath.isEmpty { Text("選択してください").tag("") }
                    ForEach(model.installedModels) { installed in
                        Text(installed.information.description).tag(installed.id)
                    }
                }
                .pickerStyle(.menu).font(.caption)
                .accessibilityIdentifier("installedModels")
                .disabled(model.busy || model.recording)
            }
            HStack {
                Button(action: model.refreshInstalledModels) { Label("更新", systemImage: "arrow.clockwise") }
                Spacer()
                Button { managingModels = true } label: { Label("モデルを管理", systemImage: "externaldrive") }
                    .accessibilityIdentifier("manageModels")
            }.font(.caption).buttonStyle(.plain).disabled(model.busy || model.recording)
            HStack {
                Button {
                    focusedField = nil; importKind = .model; importing = true
                } label: { Label(model.modelPath.isEmpty ? "フォルダを選ぶ" : "モデルを変更", systemImage: "folder") }
                    .accessibilityIdentifier("importModel")
                Spacer(minLength: 8)
                Button("準備", action: model.prepare).accessibilityIdentifier("prepare")
                    .disabled(model.modelPath.isEmpty)
            }
            .font(.caption.weight(.medium)).buttonStyle(.bordered)
            .disabled(model.busy || model.recording)
            if !model.needsSetup && !model.shouldShowDownload { downloadControls }
            DisclosureGroup("URLからダウンロード", isExpanded: $downloadExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("manifest.json のHTTPS URL", text: $model.manifestURL)
                        .textFieldStyle(.roundedBorder).focused($focusedField, equals: .url)
                    Button("ダウンロードして検証", action: model.download)
                        .buttonStyle(.bordered).disabled(model.manifestURL.isEmpty)
                }.padding(.top, 10)
            }
            .font(.caption).disabled(model.busy || model.recording || !model.pendingDownloadURL.isEmpty)
            if let milliseconds = model.modelPreparationMilliseconds {
                Text(String(format: "準備 %.0f ms · 参照 %.0f ms%@", milliseconds,
                            model.referencePreparationMilliseconds ?? 0, model.referenceCacheHit ? "（キャッシュ）" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("初回の準備には時間がかかることがあります。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.studioCard()
    }

    private var voiceSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("声と話し方", systemImage: "person.wave.2").font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.referencePath.isEmpty ? "参照なし" : "登録音声あり")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("落ち着いた、やさしい話し方。", text: $model.caption, axis: .vertical)
                .accessibilityIdentifier("voiceCaption").lineLimit(2...4).textFieldStyle(.plain)
                .focused($focusedField, equals: .caption)
                .padding(12).background(StudioStyle.canvas, in: RoundedRectangle(cornerRadius: 12))
                .disabled(model.busy || model.recording)
            Text("声や話し方を短く指定できます。空欄でも生成できます。")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            Toggle(isOn: $model.consent) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("利用できる声を登録").font(.caption.weight(.medium))
                    Text("自分の声、または明示的に許可を得た声")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("voiceConsent").toggleStyle(.switch)
            .disabled(model.busy || model.recording)
            HStack {
                Button {
                    focusedField = nil; importKind = .reference; importing = true
                } label: { Label("音声を選ぶ", systemImage: "waveform.badge.plus") }
                    .accessibilityIdentifier("importReference")
                    .disabled(model.recording || !model.consent)
                Spacer(minLength: 4)
                Button(action: model.toggleRecording) {
                    Label(model.recording ? "録音を停止" : "録音する", systemImage: model.recording ? "stop.circle" : "mic")
                }
                .accessibilityIdentifier("recordReference")
                .tint(model.recording ? .red : StudioStyle.accent)
                .disabled(!model.recording && !model.consent)
            }
            .font(.caption.weight(.medium)).buttonStyle(.bordered).disabled(model.busy)
            if model.recording {
                Label("録音中 · 3〜10秒を目安に停止してください", systemImage: "record.circle")
                    .font(.caption).foregroundStyle(.red)
            }
            if !model.referencePath.isEmpty {
                Button(role: .destructive, action: model.deleteReference) {
                    Label("登録音声とキャッシュを削除", systemImage: "trash")
                }
                .font(.caption).buttonStyle(.plain).accessibilityIdentifier("deleteReference")
                .disabled(model.busy || model.recording)
            }
        }.studioCard()
    }
}

private struct GenerateButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? StudioStyle.buttonInk : Color.secondary)
            .background(enabled ? StudioStyle.accent : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private extension View {
    func studioCard() -> some View {
        padding(22)
            .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.045), lineWidth: 1))
    }
}

#if os(macOS)
/// Export the completed WAV without changing its header or PCM bytes.
private struct SampleWAVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.wav] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif
