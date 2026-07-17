import AVFoundation
import Combine
import Foundation
import Speech

final class SpeechRecognizerService: ObservableObject {
    @Published var partialText = ""
    @Published var level: Float = 0
    @Published var isRunning = false

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceWork: DispatchWorkItem?
    private var onSentence: ((String) -> Void)?
    private var restarting = false
    private var lastDelivered = ""
    private var lastDeliveredAt = Date.distantPast
    private var recognitionContext: [String] = []

    func start(localeIdentifier: String, contextualStrings: [String] = [], onSentence: @escaping (String) -> Void) async throws {
        guard !isRunning else { return }
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            throw NSError(domain: "SimulMeet", code: 1, userInfo: [NSLocalizedDescriptionKey: "请在 iPhone 设置中允许语音识别权限。"])
        }
        let microphoneAllowed = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard microphoneAllowed else {
            throw NSError(domain: "SimulMeet", code: 2, userInfo: [NSLocalizedDescriptionKey: "请在 iPhone 设置中允许麦克风权限。"])
        }

        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        guard recognizer?.isAvailable == true else {
            throw NSError(domain: "SimulMeet", code: 3, userInfo: [NSLocalizedDescriptionKey: "当前语言的 Apple 语音识别暂时不可用。"])
        }

        self.onSentence = onSentence
        lastDelivered = ""
        lastDeliveredAt = .distantPast
        recognitionContext = Array(contextualStrings.prefix(100))
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 768, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)
            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            Task { @MainActor in self.level = min(1, rms * 18) }
        }
        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true
        beginRecognitionTask()
    }

    func stop(deliverPending: Bool = true) {
        silenceWork?.cancel()
        if deliverPending { deliverCurrentSentence() }
        task?.cancel()
        request?.endAudio()
        task = nil
        request = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
        level = 0
    }

    private func beginRecognitionTask() {
        guard isRunning, !restarting else { return }
        restarting = true
        task?.cancel()
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .dictation
        newRequest.contextualStrings = recognitionContext
        request = newRequest
        partialText = ""

        task = recognizer?.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.partialText = text
                    let delay: TimeInterval
                    if result.isFinal {
                        delay = 0.18
                    } else if self.hasSentenceEndingPunctuation(text) {
                        delay = 0.42
                    } else {
                        delay = 1.15
                    }
                    self.scheduleSentenceDelivery(delay: delay)
                }
                if error != nil && self.isRunning {
                    self.deliverCurrentSentence()
                    self.restartRecognitionSoon()
                }
            }
        }
        restarting = false
    }

    private func hasSentenceEndingPunctuation(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".!?。！？".contains(last)
    }

    private func scheduleSentenceDelivery(delay: TimeInterval) {
        silenceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.deliverCurrentSentence()
                self?.restartRecognitionSoon()
            }
        }
        silenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func deliverCurrentSentence() {
        let value = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        partialText = ""
        guard value.count > 1 else { return }

        // Protection against the same finalized callback being delivered twice.
        let normalized = DuplicateDetector.normalize(value)
        let isImmediateCallbackDuplicate = normalized == DuplicateDetector.normalize(lastDelivered)
            && Date().timeIntervalSince(lastDeliveredAt) < 0.8
        guard !isImmediateCallbackDuplicate else { return }
        lastDelivered = value
        lastDeliveredAt = Date()
        onSentence?(value)
    }

    private func restartRecognitionSoon() {
        guard isRunning, !restarting else { return }
        restarting = true
        task?.cancel()
        request?.endAudio()
        task = nil
        request = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self else { return }
            self.restarting = false
            self.beginRecognitionTask()
        }
    }
}
