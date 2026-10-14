import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import UIKit

enum CameraFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

/// All calls are confined to the processing queue. Idle monitoring uses developed
/// RAW; hardware recording skips RAW monitoring and uses the native preview layer.
/// Assists never modify the image passed to the writer.
final class RawProcessor {
    let context: CIContext
    let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let logKernel: CIColorKernel
    private let displayKernel: CIColorKernel
    private let assistKernel: CIColorKernel

    init() throws {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false
        ]
        if let gpu = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: gpu, options: options)
        } else { context = CIContext(options: options) }
        guard let libraryURL = Bundle.main.url(forResource: "default", withExtension: "metallib") else {
            throw CameraFailure.message("The compiled GPU color pipeline is missing.")
        }
        let library = try Data(contentsOf: libraryURL)
        logKernel = try CIColorKernel(functionName: "gateLog", fromMetalLibraryData: library)
        displayKernel = try CIColorKernel(functionName: "rec709", fromMetalLibraryData: library)
        assistKernel = try CIColorKernel(functionName: "exposureAssist", fromMetalLibraryData: library)
    }

    func develop(_ photo: AVCapturePhoto, settings: CameraSettings) throws -> CIImage {
        guard photo.isRawPhoto, let buffer = photo.pixelBuffer,
              let raw = CIRAWFilter(cvPixelBuffer: buffer, properties: photo.metadata) else {
            throw CameraFailure.message("The camera did not deliver a decodable Bayer RAW frame.")
        }
        // Select the deterministic, non-ML decoder where available.
        if raw.supportedDecoderVersions.contains(.version8) { raw.decoderVersion = .version8 }
        else if raw.supportedDecoderVersions.contains(.version8DNG) { raw.decoderVersion = .version8DNG }
        raw.orientation = .right
        raw.scaleFactor = min(1, Float(settings.longEdge) / Float(max(raw.nativeSize.width, raw.nativeSize.height)))
        raw.baselineExposure = 0
        raw.exposure = 0
        raw.shadowBias = 0
        raw.boostAmount = 0
        raw.boostShadowAmount = 0
        raw.isGamutMappingEnabled = false
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
        if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
        if raw.isContrastSupported { raw.contrastAmount = 0 }
        if raw.isDetailSupported { raw.detailAmount = 0 }
        if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = settings.noiseReduction }
        if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = settings.noiseReduction }
        if raw.isMoireReductionSupported { raw.moireReductionAmount = 0 }
        if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = settings.lensCorrection }
        raw.neutralTemperature = settings.whiteBalance
        raw.neutralTint = 0
        guard let image = raw.outputImage else { throw CameraFailure.message("RAW development failed.") }
        return frame(image, settings: settings)
    }

    func frame(_ image: CIImage, settings: CameraSettings) -> CIImage {
        let extent = image.extent
        let ratio = settings.framing.portraitRatio
        var width = extent.width
        var height = width / ratio
        if height > extent.height { height = extent.height; width = height * ratio }
        let crop = CGRect(x: extent.midX - width / 2, y: extent.midY - height / 2, width: width, height: height)
        let cropped = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let targetHeight = CGFloat(settings.longEdge)
        let targetWidth = floor(targetHeight * ratio / 2) * 2
        return cropped.transformed(by: CGAffineTransform(scaleX: targetWidth / width, y: targetHeight / height))
            .cropped(to: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    }

    func encoded(_ linear: CIImage, profile: ColorProfile) throws -> CIImage {
        let kernel = profile == .gateLog ? logKernel : displayKernel
        guard let result = kernel.apply(extent: linear.extent, arguments: [linear]) else {
            throw CameraFailure.message("Color encoding failed.")
        }
        return result
    }

    func preview(_ linear: CIImage, settings: CameraSettings) throws -> CGImage {
        let monitorProfile: ColorProfile = settings.gammaAssist ? .rec709 : settings.profile
        var image = try encoded(linear, profile: monitorProfile)
        let scale = min(1, 720 / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if settings.assist != .off {
            // The thresholds always refer to the Rec.709 display signal.
            let display = try encoded(linear, profile: .rec709)
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let assisted = assistKernel.apply(extent: display.extent, arguments: [display, settings.assist == .zebras ? 1.0 : 2.0]) else {
                throw CameraFailure.message("Exposure monitor failed.")
            }
            image = assisted
        }
        // The kernels already encoded the signal. Do not apply another gamma.
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: linearSpace) else {
            throw CameraFailure.message("The monitor could not render a frame.")
        }
        // Relabel the already encoded display samples for UIKit presentation.
        return cg.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? cg
    }

    func demoImage(time: Double, settings: CameraSettings) -> CIImage {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: 0)
        gradient.point1 = CGPoint(x: 1440, y: 1920)
        gradient.color0 = CIColor(red: 0.025, green: 0.075, blue: 0.09)
        gradient.color1 = CIColor(red: 0.5, green: 0.3, blue: 0.1)
        var image = gradient.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 1440, height: 1920))
        for i in 0..<7 {
            let x = CGFloat(i) * 240 - 200 + CGFloat(sin(time * 0.4) * 70)
            let block = CIImage(color: CIColor(red: 0.025 + Double(i) * 0.012, green: 0.07, blue: 0.08))
                .cropped(to: CGRect(x: x, y: 0, width: 145, height: CGFloat(460 + i * 145)))
            image = block.composited(over: image)
        }
        let sun = CIImage(color: CIColor(red: 1.2, green: 0.85, blue: 0.4))
            .cropped(to: CGRect(x: 900, y: 1320, width: 100, height: 100))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 45])
        return frame(sun.composited(over: image).cropped(to: image.extent), settings: settings)
    }
}
