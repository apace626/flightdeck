import AppKit
import AVFoundation
import Speech

/// Push-to-talk dictation: taps the mic for a 0…1 level (visualizer) AND streams
/// the audio through on-device speech recognition for live + final transcripts.
final class Dictation {
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var onLevel: ((Float) -> Void)?
    var onPartial: ((String) -> Void)?
    private(set) var transcript = ""
    private(set) var running = false

    /// Request mic + speech permission, then start. Completion: are we listening?
    func start(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { [weak self] speechAuth in
            AVCaptureDevice.requestAccess(for: .audio) { micAuth in
                DispatchQueue.main.async {
                    guard let self, speechAuth == .authorized, micAuth else {
                        completion(false); return
                    }
                    completion(self.begin())
                }
            }
        }
    }

    private func begin() -> Bool {
        guard !running, let recognizer, recognizer.isAvailable else { return false }
        transcript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            self.transcript = result.bestTranscription.formattedString
            DispatchQueue.main.async { self.onPartial?(self.transcript) }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            let level = Dictation.rms(buffer)
            DispatchQueue.main.async { self?.onLevel?(level) }
        }
        engine.prepare()
        do {
            try engine.start()
            running = true
            return true
        } catch {
            FileHandle.standardError.write(Data("flightdeck: mic engine failed: \(error)\n".utf8))
            input.removeTap(onBus: 0)
            task?.cancel(); task = nil; self.request = nil
            return false
        }
    }

    /// Stop listening; returns the final transcript (empty if cancelled).
    @discardableResult
    func stop() -> String {
        guard running else { return "" }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.finish()
        request = nil; task = nil
        running = false
        return transcript
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { let s = ch[i]; sum += s * s }
        let rms = (sum / Float(n)).squareRoot()
        return min(1, rms * 12)   // gain so normal speech fills the meter
    }
}

/// A bottom-center HUD with a live, mirrored waveform of recent mic levels.
final class VisualizerOverlay: NSView {
    private let panel = NSView()
    private let wave = WaveView()
    private let label = NSTextField(labelWithString: "Listening…")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        wantsLayer = true

        // Solid dark Catppuccin panel (the HUD blur material read too light).
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 46 / 255, alpha: 0.98).cgColor
        panel.layer?.cornerRadius = 18
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor(srgbRed: 69 / 255, green: 71 / 255, blue: 90 / 255, alpha: 1).cgColor
        panel.shadow = NSShadow()
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.45
        panel.layer?.shadowRadius = 24
        panel.layer?.shadowOffset = CGSize(width: 0, height: -6)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        wave.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(srgbRed: 205 / 255, green: 214 / 255, blue: 244 / 255, alpha: 1) // text (matches console)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        label.stringValue = "Listening…  (⏎ insert · esc cancel)"
        label.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(wave)
        panel.addSubview(label)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -40),
            panel.widthAnchor.constraint(equalToConstant: 360),
            panel.heightAnchor.constraint(equalToConstant: 96),

            wave.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            wave.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            wave.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            wave.heightAnchor.constraint(equalToConstant: 44),

            label.topAnchor.constraint(equalTo: wave.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func push(level: Float) { wave.push(CGFloat(level)) }

    func setTranscript(_ text: String) {
        label.stringValue = text.isEmpty ? "Listening…  (⏎ insert · esc cancel)" : text
    }

    // Don't intercept clicks meant for panes underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Mirrored bar waveform driven by a scrolling history of levels.
    private final class WaveView: NSView {
        private var samples = [CGFloat](repeating: 0, count: 56)

        func push(_ level: CGFloat) {
            samples.removeFirst()
            samples.append(level)
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let w = bounds.width, h = bounds.height, mid = h / 2
            let count = samples.count
            let gap: CGFloat = 3
            let barW = (w - gap * CGFloat(count - 1)) / CGFloat(count)

            for (i, s) in samples.enumerated() {
                let x = CGFloat(i) * (barW + gap)
                let amp = max(2, s * (h * 0.9))            // min height so it's never empty
                let rect = CGRect(x: x, y: mid - amp / 2, width: barW, height: amp)
                // Catppuccin blue → green across the bars.
                let t = CGFloat(i) / CGFloat(count - 1)
                let color = NSColor(
                    srgbRed: 0.537 + 0.114 * t,
                    green: 0.706 + 0.184 * t,
                    blue: 0.980 - 0.349 * t,
                    alpha: 0.55 + 0.45 * s)
                ctx.setFillColor(color.cgColor)
                let path = CGPath(roundedRect: rect, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
    }
}
