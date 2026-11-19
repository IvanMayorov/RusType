import AVFoundation
import SwiftUI

final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let control = DispatchQueue(label: "RusType.capture.control")
    private let samples = DispatchQueue(label: "RusType.capture.samples")
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    private var file: AVAudioFile?
    private var failure: Error?
    private var frames = 0
    private var lastUpdate = 0
    var level: ((Double) -> Void)?

    func start(device: AVCaptureDevice) {
        control.async {
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw self.error("Не удалось подключить микрофон") }
                self.session.addInput(input)
                guard self.session.canAddOutput(self.output) else { throw self.error("Недоступен аудиовыход") }
                self.output.audioSettings = self.format.settings
                self.output.setSampleBufferDelegate(self, queue: self.samples)
                self.session.addOutput(self.output)
                self.file = try AVAudioFile(forWriting: self.url, settings: self.format.settings)
                self.session.startRunning()
                if !self.session.isRunning { throw self.error("Микрофон не запустился") }
            } catch { self.samples.sync { self.failure = error } }
        }
    }
    private func error(_ message: String) -> NSError {
        NSError(domain: "RusType", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        let n = CMSampleBufferGetNumSamples(sample)
        guard n > 0, failure == nil, let file,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
        buffer.frameLength = buffer.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(n), into: buffer.mutableAudioBufferList) == noErr else {
            failure = error("Не удалось прочитать аудиоданные"); return
        }
        do { try file.write(from: buffer) } catch { failure = error; return }
        frames += n
        if lastUpdate == 0 || frames - lastUpdate >= 640 {
            let channel = buffer.floatChannelData![0]
            var sum: Float = 0
            for i in 0..<n { sum += channel[i] * channel[i] }
            let amplitude = min(1, max(0, (10 * log10(max(Double(sum)/Double(n), 1e-10)) + 55) / 48))
            lastUpdate = frames
            DispatchQueue.main.async { self.level?(amplitude) }
        }
    }
    func stop(_ done: @escaping (Result<Int, Error>) -> Void) {
        control.async {
            self.session.stopRunning()
            self.output.setSampleBufferDelegate(nil, queue: nil)
            let result: Result<Int, Error> = self.samples.sync {
                self.file = nil
                if let error = self.failure { return .failure(error) }
                return .success(self.frames)
            }
            DispatchQueue.main.async { done(result) }
        }
    }
}

final class Levels: ObservableObject {
    @Published var bars = Array(repeating: 0.0, count: 14)
    func append(_ amplitude: Double) { bars = Array(bars.dropFirst()) + [amplitude] }
}

struct RecordingBadge: View {
    static let size = CGSize(width: 80, height: 28)
    @ObservedObject var levels: Levels
    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.bars.indices, id: \.self) { i in
                Capsule().fill(.white).frame(width: 2, height: 2 + 16 * levels.bars[i])
            }
        }
        .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .white, location: 0.25),
            .init(color: .white, location: 0.75),
            .init(color: .clear, location: 1)
        ], startPoint: .leading, endPoint: .trailing))
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Запись")
    }
}
