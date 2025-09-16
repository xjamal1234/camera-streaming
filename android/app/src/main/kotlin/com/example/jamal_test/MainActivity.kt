package com.example.jamal_test

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import android.util.Log

class MainActivity: FlutterActivity() {
    private val CHANNEL = "yuv_jpeg_converter"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "convert") {
                    try {
                        @Suppress("UNCHECKED_CAST")
                        val args = call.arguments as Map<String, Any>
                        @Suppress("UNCHECKED_CAST")
                        val img = args["image"] as Map<String, Any>

                        val width = (img["width"] as Number).toInt()
                        val height = (img["height"] as Number).toInt()
                        val yPlane = img["yPlane"] as ByteArray
                        val uPlane = img["uPlane"] as ByteArray
                        val vPlane = img["vPlane"] as ByteArray
                        val yRowStride = (img["yRowStride"] as Number).toInt()
                        val uRowStride = (img["uRowStride"] as Number).toInt()
                        val vRowStride = (img["vRowStride"] as Number).toInt()
                        val uPixelStride = (img["uPixelStride"] as Number).toInt()
                        val vPixelStride = (img["vPixelStride"] as Number).toInt()

                        var quality = (args["quality"] as Number).toInt()
                        if (quality < 50) quality = 50
                        if (quality > 100) quality = 100

                        // Validate input parameters
                        if (width <= 0 || height <= 0) {
                            result.error("INVALID_SIZE", "Invalid width or height: ${width}x${height}", null)
                            return@setMethodCallHandler
                        }
                        
                        if (yPlane.size < width * height) {
                            result.error("INVALID_Y_PLANE", "Y plane too small: ${yPlane.size} < ${width * height}", null)
                            return@setMethodCallHandler
                        }
                        
                        Log.d("YuvJpegConverter", "Converting ${width}x${height} image, Y:${yPlane.size}, U:${uPlane.size}, V:${vPlane.size}")
                        Log.d("YuvJpegConverter", "Strides - Y:${yRowStride}, U:${uRowStride}, V:${vRowStride}, UPix:${uPixelStride}, VPix:${vPixelStride}")

                        val nv21 = yuv420ToNv21(
                            yPlane, uPlane, vPlane,
                            width, height,
                            yRowStride, uRowStride, vRowStride,
                            uPixelStride, vPixelStride
                        )

                        val yuvImage = YuvImage(nv21, ImageFormat.NV21, width, height, intArrayOf(yRowStride))
                        val out = ByteArrayOutputStream()
                        if (!yuvImage.compressToJpeg(Rect(0, 0, width, height), quality, out)) {
                            result.error("ENCODE_FAIL", "compressToJpeg returned false", null)
                            return@setMethodCallHandler
                        }
                        val jpegData = out.toByteArray()
                        Log.d("YuvJpegConverter", "Successfully converted to JPEG: ${jpegData.size} bytes")
                        result.success(jpegData)
                    } catch (e: Throwable) {
                        result.error("CONVERT_ERROR", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun yuv420ToNv21(
        yPlane: ByteArray,
        uPlane: ByteArray,
        vPlane: ByteArray,
        width: Int,
        height: Int,
        yRowStride: Int,
        uRowStride: Int,
        vRowStride: Int,
        uPixelStride: Int,
        vPixelStride: Int
    ): ByteArray {
        val ySize = width * height
        val chromaSize = (width / 2) * (height / 2)
        val out = ByteArray(ySize + 2 * chromaSize)

        // Copy Y plane (respect row stride)
        var dst = 0
        for (row in 0 until height) {
            val src = row * yRowStride
            val copyLength = minOf(width, yPlane.size - src)
            if (copyLength > 0) {
                System.arraycopy(yPlane, src, out, dst, copyLength)
                dst += copyLength
            }
        }

        // Interleave V and U (NV21 = VU) with proper bounds checking
        var uvDst = ySize
        val chromaH = height / 2
        val chromaW = width / 2
        
        for (row in 0 until chromaH) {
            val vRow = row * vRowStride
            val uRow = row * uRowStride
            
            for (col in 0 until chromaW) {
                val vIndex = vRow + (col * vPixelStride)
                val uIndex = uRow + (col * uPixelStride)
                
                // Bounds checking for V plane
                if (vIndex < vPlane.size) {
                    out[uvDst++] = vPlane[vIndex]
                } else {
                    out[uvDst++] = 0.toByte() // Default value if out of bounds
                }
                
                // Bounds checking for U plane
                if (uIndex < uPlane.size) {
                    out[uvDst++] = uPlane[uIndex]
                } else {
                    out[uvDst++] = 128.toByte() // Default U value (neutral)
                }
            }
        }
        
        return out
    }
}
