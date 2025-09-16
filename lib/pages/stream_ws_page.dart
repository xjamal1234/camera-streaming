import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:collection';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image/image.dart' as img;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

import 'cubit/stream_ws_cubit.dart';
import 'cubit/stream_ws_state.dart';
import 'utils/yuv_to_jpeg_fallback.dart';

// Data classes for frame tracking
class SentFrame {
  final int id;
  final Uint8List jpegData;
  final DateTime timestamp;
  
  SentFrame({
    required this.id,
    required this.jpegData,
    required this.timestamp,
  });
}

class ReceivedResult {
  final int frameId;
  final Uint8List processedImage;
  final String ocrText;
  final List<List<double>>? boundingBoxes;
  final DateTime timestamp;
  
  ReceivedResult({
    required this.frameId,
    required this.processedImage,
    required this.ocrText,
    this.boundingBoxes,
    required this.timestamp,
  });
}

class StreamWsPage extends StatefulWidget {
  const StreamWsPage({super.key});

  @override
  State<StreamWsPage> createState() => _StreamWsPageState();
}

class _StreamWsPageState extends State<StreamWsPage> {
  CameraController? _cam;
  StreamSubscription? _wsSubscription;
  WebSocketChannel? _ch;
  
  // Create cubit at state level
  late final StreamWsCubit _cubit;

  // Frame processing with performance optimizations
  CameraImage? _latest;
  bool _busy = false;
  int lastSentMs = 0;
  int get minGapMs => (1000 ~/ (_cubit.state.targetFps));
  
  // Performance tracking
  int _framesProcessed = 0;
  int _framesDropped = 0;
  int _lastFpsCheck = 0;
  double _currentFps = 0.0;
  
  // Adaptive quality for network conditions
  int jpegQuality = 75;
  int _adaptiveQuality = 75;
  bool _networkSlow = false;
  
  // Server configuration
  String serverUrl = 'ws://10.7.0.250:8080/ws/guidance';
  
  // Frame tracking
  int _frameCounter = 0;
  final List<SentFrame> _sentFrames = [];
  final List<ReceivedResult> _receivedResults = [];
  
  // Performance optimization: Separate processing queue
  final Queue<CameraImage> _frameQueue = Queue();
  bool _isProcessingQueue = false;
  
  // Network performance tracking
  int _lastNetworkCheck = 0;
  int _networkLatency = 0;
  int _consecutiveFailures = 0;

  @override
  void initState() {
    super.initState();
    _cubit = StreamWsCubit();
    _initializeCamera();
  }

  @override
  void dispose() {
    _cam?.dispose();
    _wsSubscription?.cancel();
    _ch?.sink.close();
    _reconnectTimer?.cancel();
    _frameQueue.clear();
    _cubit.close();
    super.dispose();
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      // Don't access cubit here since it's not available yet
      debugPrint('No cameras available');
      return;
    }

    _cam = CameraController(
      cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back),
      ResolutionPreset.medium,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _cam?.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      // Don't access cubit here since it's not available yet
      debugPrint('Camera initialization failed: $e');
    }
  }

  void _onFrame(CameraImage image) {
    // Performance optimization: Frame rate control with frame dropping
    final now = DateTime.now().millisecondsSinceEpoch;
    
    // Update FPS tracking
    _framesProcessed++;
    if (now - _lastFpsCheck >= 1000) {
      _currentFps = _framesProcessed * 1000.0 / (now - _lastFpsCheck);
      _framesProcessed = 0;
      _lastFpsCheck = now;
    }
    
    // Check if WebSocket is connected
    if (_ch == null) {
      _framesDropped++;
      return;
    }
    
    // Adaptive frame rate control
    final targetGap = _networkSlow ? minGapMs * 1.5 : minGapMs;
    if (now - lastSentMs < targetGap) {
      _framesDropped++;
      return;
    }
    
    // Queue management for performance
    if (_frameQueue.length >= 3) {
      // Drop oldest frame if queue is full (frame dropping)
      _frameQueue.removeFirst();
      _framesDropped++;
    }
    
    _frameQueue.add(image);
    
    // Process queue if not already processing
    if (!_isProcessingQueue) {
      _processQueue();
    }
  }

  Future<void> _processQueue() async {
    if (_isProcessingQueue || _frameQueue.isEmpty) return;
    
    _isProcessingQueue = true;
    
    while (_frameQueue.isNotEmpty && _ch != null) {
      final image = _frameQueue.removeFirst();
      final startTime = DateTime.now().millisecondsSinceEpoch;
      
      try {
        // Use adaptive quality based on network conditions
        final quality = _networkSlow ? _adaptiveQuality - 10 : _adaptiveQuality;
        final clampedQuality = quality.clamp(50, 90);
        
        // Convert YUV to JPEG with performance tracking
        final jpegBytes = await _convertYuvToJpeg(image, clampedQuality);
        
        if (jpegBytes.isNotEmpty && _ch != null) {
          _frameCounter++;
          final sentFrame = SentFrame(
            id: _frameCounter,
            jpegData: jpegBytes,
            timestamp: DateTime.now(),
          );
          _sentFrames.add(sentFrame);
          
          // Track network performance
          final sendStart = DateTime.now().millisecondsSinceEpoch;
          try {
            // Send frame metadata first (NOOR API format)
            final frameMeta = {
              'type': 'frame_meta',
              'seq': _frameCounter,
              'ts': DateTime.now().millisecondsSinceEpoch,
              'w': image.width,
              'h': image.height,
              'rotation_degrees': 0,
              'jpeg_quality': clampedQuality,
            };
            
            _ch?.sink.add(jsonEncode(frameMeta));
            
            // Then send the JPEG data
            _ch?.sink.add(jpegBytes);
            final sendEnd = DateTime.now().millisecondsSinceEpoch;
            _networkLatency = sendEnd - sendStart;
            
            lastSentMs = sendEnd;
            _consecutiveFailures = 0;
            
            // Adaptive quality adjustment
            if (_networkLatency > 100) {
              _networkSlow = true;
              _adaptiveQuality = (_adaptiveQuality - 5).clamp(50, 90);
            } else if (_networkLatency < 50) {
              _networkSlow = false;
              _adaptiveQuality = (_adaptiveQuality + 2).clamp(50, 90);
            }
            
            debugPrint('Sent frame ${_frameCounter}: ${jpegBytes.length} bytes, latency: ${_networkLatency}ms, quality: $clampedQuality');
            
            // Update UI periodically
            if (_frameCounter % 5 == 0 && mounted) {
              setState(() {});
            }
          } catch (e) {
            _consecutiveFailures++;
            debugPrint('Failed to send frame ${_frameCounter}: $e');
            
            // Reduce quality on consecutive failures
            if (_consecutiveFailures > 3) {
              _adaptiveQuality = (_adaptiveQuality - 10).clamp(50, 90);
              _networkSlow = true;
            }
          }
        }
        
        // Performance monitoring
        final processingTime = DateTime.now().millisecondsSinceEpoch - startTime;
        if (processingTime > 50) {
          debugPrint('Frame processing slow: ${processingTime}ms');
        }
        
      } catch (e) {
        debugPrint('Frame processing error: $e');
        _consecutiveFailures++;
      }
      
      // Small delay to prevent overwhelming the system
      if (_frameQueue.isNotEmpty) {
        await Future.delayed(const Duration(milliseconds: 1));
      }
    }
    
    _isProcessingQueue = false;
  }

  Future<Uint8List> _convertYuvToJpeg(CameraImage? image, int quality) async {
    if (image == null) return Uint8List(0);
    
    // Try native conversion first (fastest)
    try {
      final methodChannel = const MethodChannel('yuv_jpeg_converter');
      
      final imageData = {
        'width': image.width,
        'height': image.height,
        'yPlane': image.planes[0].bytes,
        'uPlane': image.planes[1].bytes,
        'vPlane': image.planes[2].bytes,
        'yRowStride': image.planes[0].bytesPerRow,
        'uRowStride': image.planes[1].bytesPerRow,
        'vRowStride': image.planes[2].bytesPerRow,
        'uPixelStride': image.planes[1].bytesPerPixel ?? 1,
        'vPixelStride': image.planes[2].bytesPerPixel ?? 1,
      };
      
      final result = await methodChannel.invokeMethod('convert', {
        'image': imageData,
        'quality': quality,
      });
      
      return result as Uint8List;
    } catch (e) {
      // Native conversion failed, use optimized Dart fallback with isolate
      return await _convertYuvToJpegInIsolate(image, quality);
    }
  }
  
    Future<Uint8List> _convertYuvToJpegInIsolate(CameraImage image, int quality) async {
    try {
      // For now, use synchronous conversion to avoid isolate complexity
      // TODO: Implement proper isolate conversion later
      return await YuvToJpegFallback.convert(image, quality);
    } catch (e) {
      debugPrint('Conversion failed: $e');
      return Uint8List(0);
    }
  }



  Future<void> _startStreaming() async {
    debugPrint('Starting streaming...');
    _cubit.setConnecting();
    
    // Check if camera is initialized
    if (_cam == null || !(_cam?.value.isInitialized ?? false)) {
      _cubit.setFailure('Camera not initialized');
      return;
    }
    
    try {
      debugPrint('Connecting to WebSocket...');
      
      // Test network connectivity first
      try {
        _ch = IOWebSocketChannel.connect(
          Uri.parse(serverUrl),
        );
        debugPrint('WebSocket connection established');
      } catch (e) {
        debugPrint('WebSocket connection failed: $e');
        _cubit.setFailure('Cannot connect to server at ${serverUrl.replaceFirst('ws://', '')}. Please check if the server is running and accessible.');
        return;
      }
      
      debugPrint('WebSocket connected, setting up listener...');
      
                           if (_ch != null) {
                _wsSubscription = _ch!.stream.listen(
                  _handleWebSocketMessage,
                  onError: (error) {
                    debugPrint('WebSocket error: $error');
                    // Don't stop streaming, just schedule reconnection
                    _scheduleReconnect();
                  },
                  onDone: () {
                    debugPrint('WebSocket connection closed');
                    // Don't stop streaming, just schedule reconnection
                    _scheduleReconnect();
                  },
                );
              } else {
                _cubit.setFailure('Failed to establish WebSocket connection');
                return;
              }
      
             debugPrint('Starting camera image stream...');
       try {
         // Check if camera is already streaming
         if (_cam?.value.isStreamingImages == true) {
           debugPrint('Camera is already streaming, stopping first...');
           await _cam?.stopImageStream();
         }
         await _cam?.startImageStream(_onFrame);
         debugPrint('Camera stream started, setting streaming state...');
         _cubit.setStreaming();
         debugPrint('Streaming started successfully!');
       } catch (e) {
         debugPrint('Failed to start camera stream: $e');
         _cubit.setFailure('Failed to start camera stream: $e');
         // Clean up WebSocket connection
         _wsSubscription?.cancel();
         _ch?.sink.close();
         _ch = null;
         return;
       }
      
    } catch (e) {
      debugPrint('Failed to start streaming: $e');
      _cubit.setFailure('Failed to start streaming: $e');
    }
  }

  Future<void> _stopStreaming() async {
    try {
      // Only stop image stream if it's actually streaming
      if (_cam?.value.isStreamingImages == true) {
        await _cam?.stopImageStream();
      }
    } catch (e) {
      debugPrint('Error stopping camera stream: $e');
    }
    
    _wsSubscription?.cancel();
    _ch?.sink.close();
    _ch = null;
    
    _cubit.setInitial();
  }



  void _handleWebSocketMessage(dynamic data) {
    try {
      // Handle JSON messages (NOOR API guidance responses)
      final m = jsonDecode(data.toString()) as Map<String, dynamic>;
      final type = m['type'];

      if (type == 'guidance') {
        // Parse NOOR guidance response
        final direction = m['dir'] as String? ?? 'steady';
        final magnitude = (m['magnitude'] ?? 0.0).toDouble();
        final coverage = (m['coverage'] ?? 0.0).toDouble();
        final confidence = (m['conf'] ?? 0.0).toDouble();
        final ready = m['ready'] as bool? ?? false;
        final skewDeg = (m['skew_deg'] ?? 0.0).toDouble();

        debugPrint('Received guidance: $direction, magnitude: $magnitude, coverage: $coverage, confidence: $confidence, ready: $ready');

        // Update guidance state
        _cubit.updateGuidance(
          direction: direction,
          magnitude: magnitude,
          coverage: coverage,
          confidence: confidence,
          ready: ready,
        );

        if (mounted) setState(() {});
        
      } else {
        debugPrint('Unknown message type: $type');
      }
    } catch (e) {
      debugPrint('WebSocket message parse error: $e');
    }
  }
  
  // Add reconnection logic
  bool _isReconnecting = false;
  Timer? _reconnectTimer;
  
  void _scheduleReconnect() {
    if (_isReconnecting) return;
    
    _isReconnecting = true;
    debugPrint('Scheduling reconnection in 3 seconds...');
    
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      _isReconnecting = false;
      if (mounted && _cubit.state is StreamingState) {
        debugPrint('Attempting to reconnect...');
        _reconnectWebSocket();
      }
    });
  }
  
  Future<void> _reconnectWebSocket() async {
    try {
      debugPrint('Reconnecting to WebSocket...');
      
      // Close existing connection
      _wsSubscription?.cancel();
      _ch?.sink.close();
      _ch = null;
      
      // Try to reconnect
      _ch = IOWebSocketChannel.connect(Uri.parse(serverUrl));
      debugPrint('Reconnection successful');
      
      // Set up listener again
      if (_ch != null) {
        _wsSubscription = _ch!.stream.listen(
          _handleWebSocketMessage,
          onError: (error) {
            debugPrint('WebSocket reconnection error: $error');
            _scheduleReconnect();
          },
          onDone: () {
            debugPrint('WebSocket reconnection closed');
            _scheduleReconnect();
          },
        );
      }
    } catch (e) {
      debugPrint('Reconnection failed: $e');
      _scheduleReconnect();
    }
  }
  
  void _handleProcessedImage(Uint8List imageData) {
    // Find the most recent sent frame that doesn't have a result yet
    for (int i = _sentFrames.length - 1; i >= 0; i--) {
      final sentFrame = _sentFrames[i];
      final hasResult = _receivedResults.any((result) => result.frameId == sentFrame.id);
      
      if (!hasResult) {
        // Create a temporary result with the processed image
        // OCR text will be added when we receive the JSON message
        final result = ReceivedResult(
          frameId: sentFrame.id,
          processedImage: imageData,
          ocrText: '', // Will be updated when text arrives
          boundingBoxes: null,
          timestamp: DateTime.now(),
        );
        
        _receivedResults.add(result);
        if (mounted) setState(() {});
        break;
      }
    }
  }
  
  void _storeOcrResult(int frameId, String ocrText, List<List<double>>? boxes) {
    // Find the corresponding result and update it with OCR text
    for (int i = 0; i < _receivedResults.length; i++) {
      if (_receivedResults[i].frameId == frameId) {
        _receivedResults[i] = ReceivedResult(
          frameId: frameId,
          processedImage: _receivedResults[i].processedImage,
          ocrText: ocrText,
          boundingBoxes: boxes,
          timestamp: _receivedResults[i].timestamp,
        );
        if (mounted) setState(() {});
        break;
      }
    }
  }

  // Helper methods for guidance display
  IconData _getDirectionIcon(String? direction) {
    switch (direction) {
      case 'up':
        return Icons.keyboard_arrow_up;
      case 'down':
        return Icons.keyboard_arrow_down;
      case 'left':
        return Icons.keyboard_arrow_left;
      case 'right':
        return Icons.keyboard_arrow_right;
      case 'steady':
        return Icons.center_focus_strong;
      default:
        return Icons.center_focus_strong; // fallback
    }
  }

  Color _getDirectionColor(String? direction) {
    if (direction == 'steady') return Colors.green;
    return Colors.orange; // for up/down/left/right
  }
  
  void _showImageModal(SentFrame? sentFrame, ReceivedResult? receivedResult) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          child: Container(
            width: MediaQuery.of(context).size.width * 0.9,
            height: MediaQuery.of(context).size.height * 0.8,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header with frame info
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Frame ${sentFrame?.id ?? receivedResult?.frameId ?? 0}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                Text(
                  'Captured: ${sentFrame?.timestamp.toString().substring(0, 19) ?? receivedResult?.timestamp.toString().substring(0, 19) ?? ''}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                
                // Image display
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        sentFrame?.jpegData ?? receivedResult?.processedImage ?? Uint8List(0),
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
                
                // OCR text (only for received results)
                if (receivedResult != null && receivedResult.ocrText.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'OCR Results:',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      receivedResult.ocrText,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
  
  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _cubit,
      child: BlocBuilder<StreamWsCubit, StreamWsState>(
        builder: (context, state) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('NOOR Guidance Camera'),
              backgroundColor: Theme.of(context).colorScheme.inversePrimary,
            ),
            body: _cam?.value.isInitialized == true
                ? Column(
                    children: [
                      // Live camera preview
                      Expanded(
                        child: _cam != null ? CameraPreview(_cam!) : const SizedBox(),
                      ),
                      
                      // Stats panel
                      Container(
                        padding: const EdgeInsets.all(16),
                        color: Colors.grey[100],
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Guidance display
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.blue[50],
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.blue[200]!),
                              ),
                              child: Column(
                                children: [
                                  // Direction arrow
                                  Icon(
                                    _getDirectionIcon(state.guidanceDirection),
                                    size: 48,
                                    color: _getDirectionColor(state.guidanceDirection),
                                  ),
                                  const SizedBox(height: 8),
                                  // Direction text
                                  Text(
                                    'Direction: ${state.guidanceDirection?.toUpperCase() ?? 'STEADY'}',
                                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 8),
                                  // Metrics row
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                    children: [
                                      Column(
                                        children: [
                                          Text(
                                            'Confidence',
                                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                          ),
                                          Text(
                                            '${(state.confidence * 100).toStringAsFixed(1)}%',
                                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                          ),
                                        ],
                                      ),
                                      Column(
                                        children: [
                                          Text(
                                            'Coverage',
                                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                          ),
                                          Text(
                                            '${(state.coverage * 100).toStringAsFixed(1)}%',
                                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                          ),
                                        ],
                                      ),
                                      Column(
                                        children: [
                                          Text(
                                            'Magnitude',
                                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                          ),
                                          Text(
                                            state.guidanceMagnitude.toStringAsFixed(2),
                                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  // Ready indicator
                                  if (state.readyForCapture)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: Colors.green,
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: const Text(
                                        'READY FOR CAPTURE!',
                                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            
                            const SizedBox(height: 8),
                            
                                                         // Performance metrics
                             Row(
                               children: [
                                 const Text('Performance: ', style: TextStyle(fontWeight: FontWeight.bold)),
                                 Text('FPS: ${_currentFps.toStringAsFixed(1)} | Dropped: $_framesDropped | Latency: ${_networkLatency}ms'),
                               ],
                             ),
                             
                            // Server status
                            if (state is IntervalUpdateState)
                              Row(
                                children: [
                                  const Text('Server: ', style: TextStyle(fontWeight: FontWeight.bold)),
                                  Text('FPS: ${state.fps.toStringAsFixed(1)} | Frames: ${state.frames}'),
                                ],
                              ),
                            
                            const SizedBox(height: 12),
                            
                            // Target FPS slider
                            Row(
                              children: [
                                const Text('Target FPS: ', style: TextStyle(fontWeight: FontWeight.bold)),
                                Expanded(
                                  child: Slider(
                                    value: state.targetFps.toDouble(),
                                    min: 1, max: 15, divisions: 14,
                                    label: state.targetFps.toString(),
                                    onChanged: (value) => _cubit.setTargetFps(value.round()),
                                  ),
                                ),
                                Text('${state.targetFps}'),
                              ],
                            ),
                            
                                                         // JPEG Quality slider
                             Row(
                               children: [
                                 const Text('JPEG Quality: ', style: TextStyle(fontWeight: FontWeight.bold)),
                                 Expanded(
                                   child: Slider(
                                     value: jpegQuality.toDouble(),
                                     min: 50, max: 90, divisions: 40,
                                     label: jpegQuality.toString(),
                                     onChanged: (value) => setState(() => jpegQuality = value.round()),
                                   ),
                                 ),
                                 Text('$jpegQuality'),
                               ],
                             ),
                             
                             // Adaptive quality indicator
                             Row(
                               children: [
                                 const Text('Adaptive Quality: ', style: TextStyle(fontWeight: FontWeight.bold)),
                                 Text('$_adaptiveQuality', style: TextStyle(
                                   color: _networkSlow ? Colors.orange : Colors.green,
                                   fontWeight: FontWeight.bold,
                                 )),
                                 if (_networkSlow)
                                   const Text(' (Network Slow)', style: TextStyle(color: Colors.orange, fontSize: 12)),
                               ],
                             ),
                            
                            const SizedBox(height: 16),
                            
                            // Error message
                            if (state is FailureState)
                              Container(
                                padding: const EdgeInsets.all(8),
                                margin: const EdgeInsets.only(top: 8),
                                decoration: BoxDecoration(
                                  color: Colors.red[100],
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  state.message,
                                  style: TextStyle(color: Colors.red[900]),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  )
                : const Center(
                    child: CircularProgressIndicator(),
                  ),
            floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
            floatingActionButton: FloatingActionButton.extended(
              onPressed: state is StreamingState ? _stopStreaming : _startStreaming,
              label: Text(state is StreamingState ? 'Stop' : 'Start'),
              icon: Icon(state is StreamingState ? Icons.stop : Icons.play_arrow),
              tooltip: state is StreamingState ? 'Stop streaming' : 'Start streaming',
            ),
          );
        },
      ),
    );
  }
}