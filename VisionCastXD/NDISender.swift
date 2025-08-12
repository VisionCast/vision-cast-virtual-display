import AVFoundation
import Cocoa

class NDISender {
    private var sendInstance: NDIlib_send_instance_t?
    private var videoFrame: NDIlib_video_frame_v2_t
    private var width: Int
    private var height: Int
    private var nameCString: UnsafeMutablePointer<CChar>?
    private let audioEngine = AVAudioEngine()

    init?(name: String, width: Int, height: Int) {
        self.width = width
        self.height = height

        nameCString = strdup(name)
        guard let nameCString else {
            print("❌ Falha ao alocar C string para nome NDI")
            return nil
        }

        var createDesc = NDIlib_send_create_t()
        createDesc.p_ndi_name = UnsafePointer(nameCString)
        createDesc.p_groups = nil
        createDesc.clock_video = true
        createDesc.clock_audio = true

        sendInstance = NDIlib_send_create(&createDesc)
        guard let sendInstance else {
            print("❌ Failed to create NDI sender instance")
            return nil
        }

        videoFrame = NDIlib_video_frame_v2_t()
        videoFrame.xres = Int32(width)
        videoFrame.yres = Int32(height)
        videoFrame.FourCC = NDIlib_FourCC_type_BGRA
        videoFrame.frame_rate_N = 30000
        videoFrame.frame_rate_D = 1001
        videoFrame.picture_aspect_ratio = Float(width) / Float(height)
        videoFrame.frame_format_type = NDIlib_frame_format_type_progressive
        videoFrame.p_data = nil
        videoFrame.line_stride_in_bytes = Int32(width * 4)
        videoFrame.timecode = NDIlib_send_timecode_synthesize

        startAudioCapture()
    }

    func send(image: CGImage) {
        guard let sendInstance else { return }

        let bytesPerRow = width * 4
        let bufferSize = bytesPerRow * height
        guard let bitmapData = malloc(bufferSize) else {
            print("❌ Failed to allocate memory for bitmapData")
            return
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: bitmapData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            free(bitmapData)
            print("❌ Failed to create CGContext")
            return
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        videoFrame.p_data = bitmapData.assumingMemoryBound(to: UInt8.self)
        NDIlib_send_send_video_v2(sendInstance, &videoFrame)

        free(bitmapData)
    }

    // Encerra imediatamente o anúncio NDI e captura de áudio
    func shutdown() {
        audioEngine.stop()
        if let sendInstance {
            NDIlib_send_destroy(sendInstance)
            self.sendInstance = nil
        }
        if let nameCString {
            free(nameCString)
            self.nameCString = nil
        }
    }

    private func startAudioCapture() {
        let inputNode = audioEngine.inputNode
        let bus = 0

        let inputFormat = inputNode.inputFormat(forBus: bus)
        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: inputFormat.sampleRate,
                                          channels: 2,
                                          interleaved: true)!

        inputNode.installTap(onBus: bus, bufferSize: 1024, format: desiredFormat) { buffer, _ in
            self.sendAudio(buffer: buffer)
        }

        do {
            try audioEngine.start()
            print("🎤 Captura de áudio iniciada")
        } catch {
            print("❌ Erro ao iniciar áudio: \(error)")
        }
    }

    private func sendAudio(buffer: AVAudioPCMBuffer) {
        guard let sendInstance else { return }
        guard let channelData = buffer.floatChannelData else { return }

        print("📢 Enviando áudio: frames=\(buffer.frameLength), canais=\(buffer.format.channelCount)")

        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let samplesCount = frames * 2 // stereo

        let interleaved = UnsafeMutablePointer<Float>.allocate(capacity: samplesCount)

        if channels == 2 {
            let left = channelData[0]
            let right = channelData[1]
            for frame in 0 ..< frames {
                interleaved[frame * 2] = left[frame]
                interleaved[frame * 2 + 1] = right[frame]
            }
        } else if channels == 1 {
            let mono = channelData[0]
            for frame in 0 ..< frames {
                let sample = mono[frame]
                interleaved[frame * 2] = sample
                interleaved[frame * 2 + 1] = sample
            }
        } else {
            interleaved.deallocate()
            print("⚠️ Número de canais não suportado: \(channels)")
            return
        }

        var audioFrame = NDIlib_audio_frame_v2_t()
        audioFrame.sample_rate = Int32(buffer.format.sampleRate)
        audioFrame.no_channels = 2
        audioFrame.no_samples = Int32(frames)
        audioFrame.timecode = NDIlib_send_timecode_synthesize
        audioFrame.p_data = interleaved

        NDIlib_send_send_audio_v2(sendInstance, &audioFrame)

        interleaved.deallocate()
    }

    deinit {
        shutdown()
    }
}
