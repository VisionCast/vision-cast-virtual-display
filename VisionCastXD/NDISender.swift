import AVFoundation
import Cocoa

class NDISender {
    private var sendInstance: NDIlib_send_instance_t?
    private var videoFrame: NDIlib_video_frame_v2_t
    private var width: Int
    private var height: Int
    private var nameCString: UnsafeMutablePointer<CChar>?

    // Buffer de áudio reutilizável
    private var audioInterleaved: UnsafeMutablePointer<Float>?
    private var audioCapacity: Int = 0

    private let audioEngine = AVAudioEngine()

    init?(name: String, width: Int, height: Int) {
        self.width = width
        self.height = height

        nameCString = strdup(name)
        guard let nameCString else { return nil }

        var createDesc = NDIlib_send_create_t()
        createDesc.p_ndi_name = UnsafePointer(nameCString)
        createDesc.p_groups = nil
        createDesc.clock_video = true
        createDesc.clock_audio = true

        sendInstance = NDIlib_send_create(&createDesc)
        guard let sendInstance else { return nil }

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

    // Envia ponteiro BGRA já pronto (sem alocação/cópia extra)
    func sendBGRA(bytes: UnsafePointer<UInt8>, bytesPerRow: Int) {
        guard let sendInstance else { return }
        var vf = videoFrame
        vf.p_data = UnsafeMutablePointer<UInt8>(mutating: bytes)
        vf.line_stride_in_bytes = Int32(bytesPerRow)
        NDIlib_send_send_video_v2(sendInstance, &vf)
    }

    // Compatibilidade (menos eficiente)
    func send(image: CGImage) {
        guard let sendInstance else { return }
        let bytesPerRow = width * 4
        let bufferSize = bytesPerRow * height
        guard let bitmapData = malloc(bufferSize) else { return }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        if let context = CGContext(data: bitmapData, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo)
        {
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var vf = videoFrame
            vf.p_data = bitmapData.assumingMemoryBound(to: UInt8.self)
            vf.line_stride_in_bytes = Int32(bytesPerRow)
            NDIlib_send_send_video_v2(sendInstance, &vf)
        }
        free(bitmapData)
    }

    private func startAudioCapture() {
        let inputNode = audioEngine.inputNode
        let bus = 0

        let inputFormat = inputNode.inputFormat(forBus: bus)
        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: inputFormat.sampleRate,
                                          channels: 2,
                                          interleaved: true)!

        inputNode.installTap(onBus: bus, bufferSize: 1024, format: desiredFormat) { [weak self] buffer, _ in
            self?.sendAudio(buffer: buffer)
        }

        do { try audioEngine.start() } catch { print("❌ Erro ao iniciar áudio: \(error)") }
    }

    private func sendAudio(buffer: AVAudioPCMBuffer) {
        guard let sendInstance else { return }
        guard let channelData = buffer.floatChannelData else { return }

        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let needed = frames * 2 // stereo

        // Garante capacidade do buffer
        if audioCapacity < needed {
            audioInterleaved?.deallocate()
            audioInterleaved = UnsafeMutablePointer<Float>.allocate(capacity: needed)
            audioCapacity = needed
        }
        guard let interleaved = audioInterleaved else { return }

        if channels == 2 {
            let left = channelData[0]
            let right = channelData[1]
            var dst = 0
            for i in 0 ..< frames {
                interleaved[dst] = left[i]
                interleaved[dst + 1] = right[i]
                dst += 2
            }
        } else { // mono -> stereo
            let mono = channelData[0]
            var dst = 0
            for i in 0 ..< frames {
                let s = mono[i]
                interleaved[dst] = s
                interleaved[dst + 1] = s
                dst += 2
            }
        }

        var audioFrame = NDIlib_audio_frame_v2_t()
        audioFrame.sample_rate = Int32(buffer.format.sampleRate)
        audioFrame.no_channels = 2
        audioFrame.no_samples = Int32(frames)
        audioFrame.timecode = NDIlib_send_timecode_synthesize
        audioFrame.p_data = interleaved

        NDIlib_send_send_audio_v2(sendInstance, &audioFrame)
    }

    // Torna explícito para permitir encerrar de fora (MultiDisplayNDIManager)
    func shutdown() {
        // áudio
        audioEngine.stop()
        if let inter = audioInterleaved {
            inter.deallocate()
            audioInterleaved = nil
            audioCapacity = 0
        }
        // NDI
        if let sendInstance {
            NDIlib_send_destroy(sendInstance)
            self.sendInstance = nil
        }
        // nome
        if let nameCString {
            free(nameCString)
            self.nameCString = nil
        }
    }

    deinit {
        shutdown()
    }
}
