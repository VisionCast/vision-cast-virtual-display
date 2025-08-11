import Cocoa
import Foundation

class NDISender {
    private var sendInstance: NDIlib_send_instance_t?
    private var videoFrame: NDIlib_video_frame_v2_t
    private var width: Int
    private var height: Int
    private var nameCString: UnsafeMutablePointer<CChar>?

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
        createDesc.clock_audio = false

        sendInstance = NDIlib_send_create(&createDesc)
        guard let sendInstance else {
            print("❌ Failed to create NDI sender instance")
            return nil
        }

        // Configura o frame para BGRA
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
    }

    func send(image: CGImage) {
        guard let sendInstance else { return }

        let bytesPerRow = width * 4
        let bufferSize = bytesPerRow * height
        guard let bitmapData = malloc(bufferSize) else {
            print("❌ Failed to allocate memory for bitmapData")
            return
        }

        // BGRA: little-endian + premultipliedFirst
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)! // sRGB consistente
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

        // Desenha a imagem no buffer BGRA
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        videoFrame.p_data = bitmapData.assumingMemoryBound(to: UInt8.self)
        NDIlib_send_send_video_v2(sendInstance, &videoFrame)

        free(bitmapData)
    }

    deinit {
        if let sendInstance {
            NDIlib_send_destroy(sendInstance)
        }
        if let nameCString {
            free(nameCString)
        }
    }
}
