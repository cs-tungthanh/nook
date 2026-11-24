import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreAudio
import CoreImage

/// Places each recorded source side by side, left to right and vertically
/// centered, scaled down if needed to fit what the video encoder supports.
struct CanvasLayout {
    let canvasSize: CGSize
    /// One rect per source, in pixels with a bottom-left origin (Core Image's)
    let tiles: [CGRect]
    let codec: AVVideoCodecType

    init(sourceSizes: [CGSize]) {
        let width = sourceSizes.reduce(0) { $0 + $1.width }
        let height = sourceSizes.map(\.height).max() ?? 0
        let h264Max = Constants.Recording.h264MaxSize
        let fitsH264 = width <= h264Max.width && height <= h264Max.height
        // H.264 tops out around 4K; wider canvases (two Retina screens) use HEVC
        codec = fitsH264 ? .h264 : .hevc
        let limit = fitsH264 ? h264Max : Constants.Recording.hevcMaxSize
        let scale = min(1, limit.width / max(width, 1), limit.height / max(height, 1))

        let canvasHeight = Self.even(height * scale)
        var x: CGFloat = 0
        tiles = sourceSizes.map { size in
            let tileWidth = Self.even(size.width * scale)
            let tileHeight = min(canvasHeight, Self.even(size.height * scale))
            let tile = CGRect(x: x, y: Self.even((canvasHeight - tileHeight) / 2), width: tileWidth, height: tileHeight)
            x += tileWidth
            return tile
        }
        canvasSize = CGSize(width: x, height: canvasHeight)
    }

    /// Video encoders need even dimensions
    private static func even(_ value: CGFloat) -> CGFloat {
        max(0, (value / 2).rounded(.down) * 2)
    }
}

/// Writes samples from one or more streams into a single movie. With several
/// streams, each frame is drawn into its tile on a shared canvas. Pauses leave
/// no gap: samples after a resume are shifted back to continue where the
/// movie left off. Everything after `init` runs on the sample queue.
final class RecordingWriter {
    let url: URL
    var onFailure: ((Error) -> Void)?

    private let queue: DispatchQueue
    private let layout: CanvasLayout
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let frameDuration = CMTime(value: 1, timescale: Constants.Recording.framesPerSecond)

    private var latestFrames: [CVPixelBuffer?]
    private var isAccepting = false
    private var needsResync = false
    private var failed = false
    private var sessionStartTime = CMTime.invalid
    /// Total length of the pauses so far, subtracted from every sample's time
    private var timeOffset = CMTime.zero
    /// End of the last sample written, on the capture clock
    private var lastSourceTime = CMTime.invalid
    /// End of the last sample written, on the movie's clock
    private var lastOutputTime = CMTime.invalid
    private var lastVideoTime = CMTime.invalid

    init(url: URL, layout: CanvasLayout, queue: DispatchQueue, systemAudio: Bool, microphone: Bool) throws {
        self.url = url
        self.layout = layout
        self.queue = queue
        latestFrames = Array(repeating: nil, count: layout.tiles.count)

        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = Int(layout.canvasSize.width)
        let height = Int(layout.canvasSize.height)
        let fps = Int(Constants.Recording.framesPerSecond)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: layout.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2
            ]
        ])
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        systemAudioInput = systemAudio ? Self.makeAudioInput() : nil
        microphoneInput = microphone ? Self.makeAudioInput() : nil

        for input in [videoInput, systemAudioInput, microphoneInput].compactMap({ $0 }) where writer.canAdd(input) {
            writer.add(input)
        }
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    private static func makeAudioInput() -> AVAssetWriterInput {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Constants.Recording.audioSampleRate,
            AVNumberOfChannelsKey: Constants.Recording.audioChannelCount,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            AVEncoderBitRateKey: Constants.Recording.audioBitRate
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    /// Starts or stops taking samples; a restart closes the gap since the stop.
    func setAccepting(_ accepting: Bool) {
        queue.async {
            if accepting, !self.isAccepting {
                self.needsResync = self.lastSourceTime.isValid
            }
            if !accepting {
                // Let go of the capture buffers so the stopped streams can be freed
                self.latestFrames = Array(repeating: nil, count: self.layout.tiles.count)
            }
            self.isAccepting = accepting
        }
    }

    func append(_ sample: CMSampleBuffer, of type: SCStreamOutputType, from index: Int) {
        guard isAccepting, !failed, sample.isValid else { return }
        let sourceTime = sample.presentationTimeStamp
        guard sourceTime.isValid else { return }

        if needsResync {
            needsResync = false
            if sourceTime > lastSourceTime {
                timeOffset = timeOffset + (sourceTime - lastSourceTime)
            }
        }

        switch type {
        case .screen:
            appendVideo(sample, from: index, at: sourceTime)
        case .audio:
            appendAudio(sample, to: systemAudioInput)
        default:
            if #available(macOS 15.0, *), type == .microphone {
                appendAudio(sample, to: microphoneInput)
            }
        }
    }

    private func appendVideo(_ sample: CMSampleBuffer, from index: Int, at sourceTime: CMTime) {
        // Only complete frames carry an image; idle frames mean nothing changed
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let frame = sample.imageBuffer,
              latestFrames.indices.contains(index) else { return }
        latestFrames[index] = frame

        let time = sourceTime - timeOffset
        if !sessionStartTime.isValid {
            writer.startSession(atSourceTime: time)
            sessionStartTime = time
        } else if lastVideoTime.isValid, time <= lastVideoTime {
            return
        }
        guard videoInput.isReadyForMoreMediaData else { return }

        let buffer = layout.tiles.count == 1 ? frame : compose()
        guard let buffer = buffer else { return }
        guard adaptor.append(buffer, withPresentationTime: time) else {
            reportFailure()
            return
        }
        lastVideoTime = time
        noteWritten(sourceEnd: sourceTime + frameDuration, outputEnd: time + frameDuration)
    }

    /// Draws the latest frame from every stream into its tile on a fresh canvas.
    private func compose() -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output = output else { return nil }

        let canvas = CGRect(origin: .zero, size: layout.canvasSize)
        var image = CIImage(color: .black).cropped(to: canvas)
        for (frame, tile) in zip(latestFrames, layout.tiles) {
            guard let frame = frame else { continue }
            let source = CIImage(cvPixelBuffer: frame)
            let transform = CGAffineTransform(scaleX: tile.width / source.extent.width, y: tile.height / source.extent.height)
                .concatenating(CGAffineTransform(translationX: tile.minX, y: tile.minY))
            image = source.transformed(by: transform).composited(over: image)
        }
        ciContext.render(image, to: output, bounds: canvas, colorSpace: colorSpace)
        return output
    }

    private func appendAudio(_ sample: CMSampleBuffer, to input: AVAssetWriterInput?) {
        // Audio waits for the first video frame so the movie doesn't open on black
        guard let input = input, sessionStartTime.isValid, input.isReadyForMoreMediaData,
              let retimed = retime(sample) else { return }
        let time = retimed.presentationTimeStamp
        guard time >= sessionStartTime else { return }
        guard input.append(retimed) else {
            reportFailure()
            return
        }
        let duration = sample.duration.isValid ? sample.duration : .zero
        noteWritten(sourceEnd: sample.presentationTimeStamp + duration, outputEnd: time + duration)
    }

    private func retime(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard timeOffset != .zero else { return sample }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - timeOffset
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - timeOffset
            }
        }
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count,
            sampleTimingArray: &timing, sampleBufferOut: &retimed
        )
        return retimed
    }

    private func noteWritten(sourceEnd: CMTime, outputEnd: CMTime) {
        if !lastSourceTime.isValid || sourceEnd > lastSourceTime { lastSourceTime = sourceEnd }
        if !lastOutputTime.isValid || outputEnd > lastOutputTime { lastOutputTime = outputEnd }
    }

    private func reportFailure() {
        guard !failed else { return }
        failed = true
        let error = writer.error ?? CocoaError(.fileWriteUnknown)
        DispatchQueue.main.async { self.onFailure?(error) }
    }

    /// Closes the movie; `completion` gets its URL on the main queue, or nil if nothing was written.
    func finish(completion: @escaping (URL?) -> Void) {
        queue.async {
            self.isAccepting = false
            self.latestFrames = Array(repeating: nil, count: self.layout.tiles.count)
            guard self.sessionStartTime.isValid, self.writer.status == .writing else {
                self.discardFile()
                DispatchQueue.main.async { completion(nil) }
                return
            }
            for input in [self.videoInput, self.systemAudioInput, self.microphoneInput].compactMap({ $0 }) {
                input.markAsFinished()
            }
            if self.lastOutputTime.isValid {
                self.writer.endSession(atSourceTime: self.lastOutputTime)
            }
            self.writer.finishWriting {
                let saved = self.writer.status == .completed
                if !saved {
                    NSLog("Nook: finishing recording failed: \(self.writer.error?.localizedDescription ?? "unknown error")")
                    try? FileManager.default.removeItem(at: self.url)
                }
                DispatchQueue.main.async { completion(saved ? self.url : nil) }
            }
        }
    }

    /// Stops writing and deletes the file.
    func cancel() {
        queue.async {
            self.isAccepting = false
            self.latestFrames = Array(repeating: nil, count: self.layout.tiles.count)
            self.discardFile()
        }
    }

    private func discardFile() {
        if writer.status == .writing {
            writer.cancelWriting()
        }
        try? FileManager.default.removeItem(at: url)
    }
}
