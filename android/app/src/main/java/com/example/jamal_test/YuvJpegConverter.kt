package com.example.jamal_test

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.Image
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

class YuvJpegConverter: FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "yuv_jpeg_converter")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "convert" -> {
                try {
                    val imageData = call.argument<Map<String, Any>>("image")
                    val quality = call.argument<Int>("quality") ?: 75
                    
                    if (imageData == null) {
                        result.error("INVALID_ARGUMENT", "Image data is required", null)
                        return
                    }
                    
                    val jpegBytes = convertYuvToJpeg(imageData, quality)
                    result.success(jpegBytes)
                } catch (e: Exception) {
                    result.error("CONVERSION_ERROR", "Failed to convert YUV to JPEG: ${e.message}", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun convertYuvToJpeg(imageData: Map<String, Any>, quality: Int): ByteArray {
        val width = imageData["width"] as Int
        val height = imageData["height"] as Int
        
        val yPlane = imageData["yPlane"] as ByteArray
        val uPlane = imageData["uPlane"] as ByteArray
        val vPlane = imageData["vPlane"] as ByteArray
        
        val yRowStride = imageData["yRowStride"] as Int
        val uRowStride = imageData["uRowStride"] as Int
        val vRowStride = imageData["vRowStride"] as Int
        
        val uPixelStride = imageData["uPixelStride"] as Int
        val vPixelStride = imageData["vPixelStride"] as Int
        
        // Convert YUV420 to NV21 format (required by YuvImage)
        val nv21 = yuv420ToNv21(
            yPlane, uPlane, vPlane,
            width, height,
            yRowStride, uRowStride, vRowStride,
            uPixelStride, vPixelStride
        )
        
        // Create YuvImage and compress to JPEG
        val yuvImage = YuvImage(nv21, ImageFormat.NV21, width, height, null)
        val outputStream = ByteArrayOutputStream()
        
        yuvImage.compressToJpeg(Rect(0, 0, width, height), quality, outputStream)
        
        return outputStream.toByteArray()
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
        val nv21 = ByteArray(width * height * 3 / 2)
        
        // Copy Y plane
        var yIndex = 0
        var nv21Index = 0
        for (row in 0 until height) {
            System.arraycopy(yPlane, yIndex, nv21, nv21Index, width)
            yIndex += yRowStride
            nv21Index += width
        }
        
        // Interleave U and V planes
        var uIndex = 0
        var vIndex = 0
        for (row in 0 until height / 2) {
            for (col in 0 until width / 2) {
                nv21[nv21Index++] = vPlane[vIndex]
                nv21[nv21Index++] = uPlane[uIndex]
                uIndex += uPixelStride
                vIndex += vPixelStride
            }
            uIndex += uRowStride - (width / 2) * uPixelStride
            vIndex += vRowStride - (width / 2) * vPixelStride
        }
        
        return nv21
    }
}
