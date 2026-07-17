import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            LiveView()
                .tabItem { Label("同传", systemImage: "waveform.and.mic") }
                .tag(0)
            HistoryView(tab: $tab)
                .tabItem { Label("历史", systemImage: "text.line.first.and.arrowtriangle.forward") }
                .tag(1)
            AssistantView()
                .tabItem { Label("助手", systemImage: "sparkles") }
                .tag(2)
            MaterialsView()
                .tabItem { Label("资料", systemImage: "doc.on.doc") }
                .tag(3)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(4)
        }
        .tint(Color(red: 0.10, green: 0.36, blue: 0.92))
    }
}

private struct ScreenBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.94, green: 0.97, blue: 1), .white], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

private struct BrandHeader: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SimulMeet").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.blue)
                    Text("iOS 同声传译 · 会议助手").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Label(vm.isListening ? "正在监听" : "未录音", systemImage: vm.isListening ? "mic.fill" : "mic.slash")
                        .font(.caption.bold()).foregroundStyle(vm.isListening ? .green : .orange)
                    Text("待处理 \(vm.pendingCount) · Token \(vm.tokenUsage.total)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 7) {
                Circle().fill(vm.isListening ? Color.green : Color.gray).frame(width: 7, height: 7)
                Text(vm.status).font(.caption).lineLimit(2)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(0.9), in: Capsule())
        }
    }
}

private struct LiveView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        ZStack {
            ScreenBackground()
            ScrollView {
                VStack(spacing: 14) {
                    BrandHeader()
                    VStack(spacing: 10) {
                        HStack {
                            Picker("源语言", selection: $vm.language) {
                                ForEach(SourceLanguage.allCases) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.menu)
                            Spacer()
                            Picker("翻译模型", selection: $vm.translationModel) {
                                ForEach(TranslationModel.allCases) { Text($0.title).tag($0) }
                            }.pickerStyle(.menu)
                        }
                        HStack(spacing: 9) {
                            PrimaryButton(title: vm.isListening ? "正在监听" : "开始连续字幕", icon: "play.fill", disabled: vm.isListening) { vm.start() }
                            SmallButton(title: vm.isPaused ? "继续" : "暂停", icon: vm.isPaused ? "playpause.fill" : "pause.fill") { vm.pauseOrResume() }
                            SmallButton(title: "停止", icon: "stop.fill", color: .red) { vm.stop() }
                        }
                        HStack(spacing: 9) {
                            SmallButton(title: "清理未翻译", icon: "xmark.circle") { vm.clearPending() }
                            SmallButton(title: "清除记录", icon: "trash", color: .purple) { vm.clearHistory() }
                        }
                    }
                    .padding(14).cardStyle()

                    CaptionCard(title: "原文 / Source", text: vm.speech.partialText.isEmpty ? vm.currentSource : vm.speech.partialText, tint: .primary)
                    CaptionCard(title: "中文翻译 / Chinese", text: vm.currentChinese, tint: Color(red: 0.06, green: 0.30, blue: 0.63))

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("麦克风音量").font(.caption.bold())
                            Spacer()
                            Text("临时原文实时显示；完整句进入历史后逐句翻译").font(.caption2).foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(vm.speech.level)).tint(.blue)
                    }
                    .padding(12).cardStyle()
                }
                .padding(16)
            }
        }
    }
}

private struct HistoryView: View {
    @EnvironmentObject private var vm: AppViewModel
    @Binding var tab: Int
    @State private var isAtBottom = true
    @State private var selectedEntry: HistoryEntry?

    var body: some View {
        ZStack {
            ScreenBackground()
            VStack(spacing: 9) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("翻译历史").font(.title2.bold())
                        Text("点击记录查看完整原文、译文与状态").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(vm.history.count) 句").font(.caption.bold()).padding(8).background(.white, in: Capsule())
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(vm.history) { item in
                                HistoryRow(item: item, ask: {
                                    vm.question = item.source
                                    tab = 2
                                }, retry: {
                                    vm.retryTranslation(item.id)
                                })
                                .contentShape(Rectangle())
                                .onTapGesture { selectedEntry = item }
                            }
                            Color.clear.frame(height: 3).id("history-bottom")
                                .onAppear { isAtBottom = true }
                                .onDisappear { isAtBottom = false }
                        }
                    }
                    .onChange(of: vm.history.count) { _ in
                        guard isAtBottom else { return }
                        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("history-bottom", anchor: .bottom) }
                    }
                    .onAppear { proxy.scrollTo("history-bottom", anchor: .bottom) }
                }
            }
            .padding(14)
        }
        .sheet(item: $selectedEntry) { item in
            HistoryDetailView(entryID: item.id, tab: $tab)
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryEntry
    let ask: () -> Void
    let retry: () -> Void

    private var stateColor: Color {
        switch item.resolvedState {
        case .pending: return .orange
        case .translating: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(item.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                Text(item.resolvedState.title).font(.caption2.bold()).foregroundStyle(stateColor)
                Spacer()
                if item.resolvedState == .failed {
                    Button(action: retry) { Image(systemName: "arrow.clockwise").font(.caption.bold()) }.buttonStyle(.borderless)
                }
                Button("提问", action: ask).font(.caption2.bold()).buttonStyle(.bordered)
            }
            Text(item.source).font(.subheadline).lineLimit(1)
            Group {
                switch item.resolvedState {
                case .pending: Text("等待翻译…")
                case .translating: Text("正在翻译…")
                case .completed: Text(item.chinese)
                case .failed: Text(item.errorMessage ?? "翻译失败，点击重试")
                }
            }
            .font(.subheadline)
            .foregroundStyle(item.resolvedState == .failed ? .red : Color(red: 0.06, green: 0.30, blue: 0.63))
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7).cardStyle()
    }
}

private struct HistoryDetailView: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    let entryID: UUID
    @Binding var tab: Int

    private var item: HistoryEntry? { vm.history.first { $0.id == entryID } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let item {
                    VStack(alignment: .leading, spacing: 16) {
                        LabeledContent("时间", value: item.date.formatted(date: .abbreviated, time: .standard))
                        LabeledContent("状态", value: item.resolvedState.title)
                        if !item.model.isEmpty { LabeledContent("模型", value: item.model) }
                        DetailBlock(title: "完整原文 / Source", text: item.source)
                        DetailBlock(title: "完整中文翻译 / Chinese", text: item.chinese.isEmpty ? (item.errorMessage ?? item.resolvedState.title) : item.chinese)
                        if item.resolvedState == .failed {
                            Button("重新翻译") { vm.retryTranslation(item.id) }
                                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                        }
                        Button("根据这句话提问") {
                            vm.question = item.source
                            dismiss()
                            tab = 2
                        }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    }.padding(18)
                }
            }
            .navigationTitle("翻译详情")
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}

private struct DetailBlock: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(14).cardStyle()
    }
}

private struct AssistantView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        ZStack {
            ScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("手动会议 / 面试助手").font(.title2.bold())
                    Text("只有点击回答或总结时才消耗助手 Token，回答固定包含中文和英文。")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("助手模型", selection: $vm.assistantModel) {
                        ForEach(TranslationModel.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu).padding(10).cardStyle()
                    TextEditor(text: $vm.question)
                        .frame(minHeight: 100).padding(8).scrollContentBackground(.hidden).background(.white, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(alignment: .topLeading) {
                            if vm.question.isEmpty { Text("输入会议问题或面试问题…").foregroundStyle(.secondary).padding(16).allowsHitTesting(false) }
                        }
                    HStack {
                        PrimaryButton(title: "中英文回答", icon: "sparkles", disabled: vm.isAssistantBusy) { vm.ask() }
                        SmallButton(title: "会议总结", icon: "list.bullet.clipboard") { vm.summarize() }
                    }
                    if vm.isAssistantBusy { ProgressView().frame(maxWidth: .infinity) }
                    Text(vm.assistantAnswer.isEmpty ? "回答将在这里显示。" : vm.assistantAnswer)
                        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                        .padding(14).cardStyle()
                }.padding(16)
            }
        }
    }
}

private struct MaterialsView: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var importing = false

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()
                List {
                    Section("已添加 \(vm.materials.count)/10") {
                        ForEach(vm.materials) { item in
                            VStack(alignment: .leading) {
                                Text(item.name).font(.headline)
                                Text("已提取 \(item.text.count) 个字符").font(.caption).foregroundStyle(.secondary)
                            }
                        }.onDelete { indexes in
                            indexes.map { vm.materials[$0] }.forEach { vm.removeMaterial($0) }
                        }
                    }
                }.scrollContentBackground(.hidden)
            }
            .navigationTitle("会议资料")
            .toolbar { Button { importing = true } label: { Label("添加", systemImage: "plus") } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .pdf, .commaSeparatedText, .json], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { vm.importMaterial(from: url) }
            }
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("API Keys（保存在 iPhone Keychain）") {
                    SecureField("豆包 API Key", text: $vm.doubaoKey)
                    SecureField("DeepSeek API Key", text: $vm.deepSeekKey)
                }
                Section("模型 ID") {
                    TextField("Doubao Seed 1.6 Flash", text: $vm.flashModelID)
                    TextField("Doubao Seed 2.0 Mini", text: $vm.miniModelID)
                    TextField("DeepSeek V4 Flash", text: $vm.deepSeekModelID)
                }
                Section("准确度增强") {
                    TextField("术语、姓名、课程名（逗号分隔）", text: $vm.customTerms, axis: .vertical)
                        .lineLimit(2...5)
                    Toggle("接口失败时自动切换模型", isOn: $vm.automaticFailover)
                    Text("开始录音前保存。术语会同时帮助 Apple 语音识别和翻译纠错。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Token 用量") {
                    LabeledContent("请求次数", value: "\(vm.tokenUsage.requests)")
                    LabeledContent("输入 Token", value: "\(vm.tokenUsage.input)")
                    LabeledContent("输出 Token", value: "\(vm.tokenUsage.output)")
                    LabeledContent("总 Token", value: "\(vm.tokenUsage.total)")
                }
                Button("保存配置") { vm.saveSettings() }.frame(maxWidth: .infinity)
            }
            .navigationTitle("设置")
        }
    }
}

private struct CaptionCard: View {
    let title: String
    let text: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text.isEmpty ? "等待语音…" : text)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(text.isEmpty ? Color.secondary : tint)
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        }.padding(14).cardStyle()
    }
}

private struct PrimaryButton: View {
    let title: String
    let icon: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label(title, systemImage: icon).font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 11) }
            .buttonStyle(.plain).foregroundStyle(.white).background(disabled ? Color.gray : Color.blue, in: RoundedRectangle(cornerRadius: 12)).disabled(disabled)
    }
}

private struct SmallButton: View {
    let title: String
    let icon: String
    var color: Color = .blue
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label(title, systemImage: icon).font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 11) }
            .buttonStyle(.plain).foregroundStyle(color).background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }
}

private extension View {
    func cardStyle() -> some View {
        background(.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.055), radius: 10, y: 4)
    }
}
