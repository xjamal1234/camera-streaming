import Flutter
import UIKit
import CoreImage
import CoreGraphics

class YuvJpegConverter: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "yuv_jpeg_converter", binaryMessenger: registrar.messenger())
        let instance = YuvJpegConverter()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "convert":
            guard let args = call.arguments as? [String: Any],
                  let imageData = args["image"] as? [String: Any],
                  let quality = args["quality"] as? Int else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Invalid arguments", details: nil))
                return
            }
            
            do {
                let jpegData = try convertYuvToJpeg(imageData: imageData, quality: quality)
                result(jpegData)
            } catch {
                result(FlutterError(code: "CONVERSION_ERROR", message: "Failed to convert YUV to JPEG: \(error)", details: nil))
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func convertYuvToJpeg(imageData: [String: Any], quality: CGFloat) throws -> Data {
        guard let width = imageData["width"] as? Int,
              let height = imageData["height"] as? Int,
              let yPlane = imageData["yPlane"] as? FlutterStandardTypedData,
              let uPlane = imageData["uPlane"] as? FlutterStandardTypedData,
              let vPlane = imageData["vPlane"] as? FlutterStandardTypedData else {
            throw ConversionError.invalidData
        }
        
        let yRowStride = imageData["yRowStride"] as? Int ?? width
        let uRowStride = imageData["uRowStride"] as? Int ?? width / 2
        let vRowStride = imageData["vRowStride"] as? Int ?? width / 2
        let uPixelStride = imageData["uPixelStride"] as? Int ?? 1
        let vPixelStride = imageData["vPixelStride"] as? Int ?? 1
        
        // Convert YUV420 to RGB
        let rgbData = yuv420ToRgb(
            yPlane: yPlane.data,
            uPlane: uPlane.data,
            vPlane: vPlane.data,
            width: width,
            height: height,
            yRowStride: yRowStride,
            uRowStride: uRowStride,
            vRowStride: vRowStride,
            uPixelStride: uPixelStride,
            vPixelStride: vPixelStride
        )
        
        // Create CGImage from RGB data
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: rgbData,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 3,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              ),
              let cgImage = context.makeImage() else {
            throw ConversionError.imageCreationFailed
        }
        
        // Convert to JPEG
        guard let jpegData = cgImage.jpegData(compressionQuality: quality) else {
            throw ConversionError.jpegCompressionFailed
        }
        
        return jpegData
    }
    
    private func yuv420ToRgb(
        yPlane: Data,
        uPlane: Data,
        vPlane: Data,
        width: Int,
        height: Int,
        yRowStride: Int,
        uRowStride: Int,
        vRowStride: Int,
        uPixelStride: Int,
        vPixelStride: Int
    ) -> UnsafeMutablePointer<UInt8> {
        let rgbData = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 3)
        
        for y in 0..<height {
            for x in 0..<width {
                let yIndex = y * yRowStride + x
                let uvY = y / 2
                let uvX = x / 2
                let uIndex = uvY * uRowStride + uvX * uPixelStride
                let vIndex = uvY * vRowStride + uvX * vPixelStride
                
                let yVal = Int(yPlane[yIndex])
                let uVal = Int(uPlane[uIndex]) - 128
                let vVal = Int(vPlane[vIndex]) - 128
                
                // YUV to RGB conversion
                var r = yVal + (1.370705 * Double(vVal)).rounded()
                var g = yVal - (0.698001 * Double(vVal)).rounded() - (0.337633 * Double(uVal)).rounded()
                var b = yVal + (1.732446 * Double(uVal)).rounded()
                
                r = max(0, min(255, r))
                g = max(0, min(255, g))
                b = max(0, min(255, b))
                
                let rgbIndex = (y * width + x) * 3
                rgbData[rgbIndex] = UInt8(r)
                rgbData[rgbIndex + 1] = UInt8(g)
                rgbData[rgbIndex + 2] = UInt8(b)
            }
        }
        
        return rgbData
    }
}

enum ConversionError: Error {
    case invalidData
    case imageCreationFailed
    case jpegCompressionFailed
}

extension CGImage {
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let data = NSMutableData() as CFMutableData?,
              let destination = CGImageDestinationCreateWithData(data, kUTTypeJPEG, 1, nil) else {
            return nil
        }
        
        CGImageDestinationAddImage(destination, self, [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        
        return data as Data
    }
}
