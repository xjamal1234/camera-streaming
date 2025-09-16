import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as imglib;

class YuvToJpegFallback {
  static Future<Uint8List> convert(CameraImage image, int quality) async {
    final q = quality.clamp(50, 95);
    // Extract serializable payload (no CameraImage crossing isolates)
    final payload = {
      'width': image.width,
      'height': image.height,
      'y': image.planes[0].bytes,
      'u': image.planes[1].bytes,
      'v': image.planes[2].bytes,
      'yRowStride': image.planes[0].bytesPerRow,
      'uRowStride': image.planes[1].bytesPerRow,
      'vRowStride': image.planes[2].bytesPerRow,
      'uPixelStride': image.planes[1].bytesPerPixel ?? 1,
      'vPixelStride': image.planes[2].bytesPerPixel ?? 1,
      'quality': q,
    };
    return compute(_convertInIsolate, payload);
  }

  // Runs in isolate
  static Uint8List _convertInIsolate(Map<String, dynamic> p) {
    final width = p['width'] as int;
    final height = p['height'] as int;
    final y = p['y'] as Uint8List;
    final u = p['u'] as Uint8List;
    final v = p['v'] as Uint8List;
    final yRow = p['yRowStride'] as int;
    final uRow = p['uRowStride'] as int;
    final vRow = p['vRowStride'] as int;
    final uPix = p['uPixelStride'] as int;
    final vPix = p['vPixelStride'] as int;
    final quality = p['quality'] as int;

    final img = imglib.Image(width: width, height: height);

    // YUV420 → RGB (BT.601), respect strides
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        final yIdx = row * yRow + col;
        final uvRow = row >> 1;
        final uvCol = col >> 1;
        final uIdx = uvRow * uRow + uvCol * uPix;
        final vIdx = uvRow * vRow + uvCol * vPix;

        final yy = y[yIdx];
        final uu = u[uIdx] - 128;
        final vv = v[vIdx] - 128;

        int r = (yy + 1.402 * vv).round();
        int g = (yy - 0.344136 * uu - 0.714136 * vv).round();
        int b = (yy + 1.772 * uu).round();

        if (r < 0) r = 0; else if (r > 255) r = 255;
        if (g < 0) g = 0; else if (g > 255) g = 255;
        if (b < 0) b = 0; else if (b > 255) b = 255;

        img.setPixelRgb(col, row, r, g, b);
      }
    }

    return Uint8List.fromList(imglib.encodeJpg(img, quality: quality));
  }
}
