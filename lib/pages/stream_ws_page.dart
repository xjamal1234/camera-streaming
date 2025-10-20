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
// OLD WebSocket imports removed - now using WsService

import 'cubit/stream_ws_cubit.dart';
import 'cubit/stream_ws_state.dart';
import 'utils/yuv_to_jpeg_fallback.dart';
import '../services/ws_service.dart';
import '../services/ws_service_adapter.dart';
import '../features/chat/screens/chat_screen.dart';

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
  // OLD WebSocket subscription removed - now using WsService
  // OLD WebSocket channel removed - now using WsService
  
  // Create cubit at state level
  late final StreamWsCubit _cubit;
  
  // Shared WebSocket service for chat integration
  final WsService _wsService = WsService();
  StreamSubscription? _wsServiceSubscription;

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
  int jpegQuality = 80;
  int _adaptiveQuality = 80;
  bool _networkSlow = false;
  
  // Server configuration
  String serverUrl = 'wss://c10d731adcf6.ngrok-free.app/ws/guidance';
  
  // Frame tracking
  int _frameCounter = 0;
  final List<SentFrame> _sentFrames = [];
  final List<ReceivedResult> _receivedResults = [];
  
  // Performance optimization: Separate processing queue
  final Queue<CameraImage> _frameQueue = Queue();
  bool _isProcessingQueue = false;
  
  // Frame sending control
  bool _allowFrameSend = true;
  bool _finalizedReceived = false;
  
  // Loading timeout handling
  Timer? _loadingTimeout;
  bool _showTimeoutError = false;
  String? _loadingErrorMessage;
  bool _isReconnectingBanner = false;
  int _reconnectAttempts = 0;
  
  // Perfect frame detection timeout
  Timer? _perfectFrameTimeout;
  DateTime? _lastPerfectFrameTime;
  
  // Network performance tracking
  int _lastNetworkCheck = 0;
  int _networkLatency = 0;
  int _consecutiveFailures = 0;

  @override
  void initState() {
    super.initState();
    _cubit = StreamWsCubit();
    _initializeCamera();
    
    // Listen to WS service for processing_completed
    _wsServiceSubscription = _wsService.onMessage.listen(_handleWsServiceMessage);
  }

  @override
  void dispose() {
    _cam?.dispose();
    // Old WebSocket subscription removed - WsService handles this
    // WsService cleanup handled in dispose()
    _reconnectTimer?.cancel();
    _loadingTimeout?.cancel();
    _perfectFrameTimeout?.cancel();
    _wsServiceSubscription?.cancel();
    _wsService.dispose();
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
    // Check if frame sending is allowed (not finalized)
    if (!_allowFrameSend) {
      _framesDropped++;
      return;
    }
    
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
    if (!_wsService.isConnected) {
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
    
    while (_frameQueue.isNotEmpty && _wsService.isConnected) {
      final image = _frameQueue.removeFirst();
      final startTime = DateTime.now().millisecondsSinceEpoch;
      
      try {
        // Use adaptive quality based on network conditions
        final quality = _networkSlow ? _adaptiveQuality - 10 : _adaptiveQuality;
        final clampedQuality = quality.clamp(80, 95);
        
        // Convert YUV to JPEG with performance tracking
        final jpegBytes = await _convertYuvToJpeg(image, clampedQuality);
        
        if (jpegBytes.isNotEmpty && _wsService.isConnected) {
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
            
            _wsService.sendJson(frameMeta);
            
            // Then send the JPEG data
            _wsService.sendBinary(jpegBytes);
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
      
      // Connect WsService for chat integration
      await _wsService.connectWs(url: serverUrl);
      
      // WebSocket connection is now handled by WsService
      debugPrint('WebSocket connection established via WsService');
      
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
         // Old WebSocket subscription removed - WsService handles this
         // WsService cleanup handled in dispose()
         // WsService cleanup handled in dispose()
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
    
    // Old WebSocket subscription removed - WsService handles this
    // WsService cleanup handled in dispose()
    // WsService cleanup handled in dispose()
    
    _cubit.setInitial();
  }



  /// Handle messages from WsService (for chat integration)
  void _handleWsServiceMessage(Map<String, dynamic> message) {
    final type = message['type'];
    final data = message['data'] as Map<String, dynamic>?;
    
    debugPrint('[StreamWsPage] WsService message: $type');
    debugPrint('[StreamWsPage] Full message: $message');
    
    if (type == 'guidance') {
      // Handle guidance messages
      final direction = message['class'] as String? ?? 'no_document';
      final coverage = (message['coverage'] ?? 0.0).toDouble();
      final confidence = (message['conf'] ?? 0.0).toDouble();
      final ready = message['ready'] as bool? ?? false;
      final skewDeg = (message['skew_deg'] ?? 0.0).toDouble();

      debugPrint('Received guidance (2s interval): $direction, coverage: $coverage, confidence: $confidence, ready: $ready');

      // Update guidance state
      _cubit.updateGuidance(
        direction: direction,
        coverage: coverage,
        confidence: confidence,
        ready: ready,
      );

      // Handle perfect frame detection
      if (direction == 'perfect' && ready == true) {
        debugPrint('PERFECT FRAME DETECTED: direction=$direction, ready=$ready, coverage=$coverage, confidence=$confidence');
        debugPrint('Waiting for server to send final_frame_captured message...');
        
        // Cancel any existing timeout
        _perfectFrameTimeout?.cancel();
        
        // Start a 10-second timeout for perfect frame
        _lastPerfectFrameTime = DateTime.now();
        _perfectFrameTimeout = Timer(const Duration(seconds: 10), () {
          if (mounted && !_finalizedReceived) {
            debugPrint('Perfect frame timeout: Server did not send final_frame_captured within 10 seconds');
            debugPrint('Triggering loading state manually...');
            
            // Manually trigger loading state
            _finalizedReceived = true;
            _allowFrameSend = false;
            _frameQueue.clear();
            
            if (_cam?.value.isStreamingImages == true) {
              _cam?.stopImageStream();
              debugPrint('Camera stream stopped (timeout)');
            }
            
            _cubit.setLoading(
              sessionId: 'timeout_${DateTime.now().millisecondsSinceEpoch}',
              savedPath: 'timeout_triggered',
            );
            
            _loadingErrorMessage = 'Server timeout: Perfect frame detected but no final_frame_captured received';
            
            // Start 30s timeout for loading
            _loadingTimeout = Timer(const Duration(seconds: 30), () {
              if (mounted && _cubit.state is LoadingState) {
                _showTimeoutError = true;
                setState(() {});
              }
            });
            
            if (mounted) setState(() {});
          }
        });
      }

      if (mounted) setState(() {});
      
    } else if (type == 'final_frame_captured') {
      // Handle final frame captured - stop streaming and show loading
      final sessionId = message['sessionId'] as String? ?? 'unknown';
      final savedPath = message['saved_path'];
      
      debugPrint('onFinalFrameCaptured sessionId=$sessionId action=stop_stream keep_ws=true');
      
      // Prevent duplicate processing
      if (!_finalizedReceived) {
        _finalizedReceived = true;
        _allowFrameSend = false;
        
        // Clear frame queue
        _frameQueue.clear();
        debugPrint('Frame queue cleared');
        
        // Stop camera stream
        if (_cam?.value.isStreamingImages == true) {
          _cam?.stopImageStream();
          debugPrint('Camera stream stopped');
        }
        
        // Transition to loading state
        _cubit.setLoading(
          sessionId: sessionId,
          savedPath: (savedPath is String) ? savedPath : '',
        );

        // If server failed to provide saved_path
        if (savedPath == null || savedPath.isEmpty) {
          _loadingErrorMessage = 'Server failed to provide saved_path';
        }

        // Start 30s timeout for loading
        _loadingTimeout = Timer(const Duration(seconds: 30), () {
          if (mounted && _cubit.state is LoadingState) {
            _showTimeoutError = true;
            setState(() {});
          }
        });
        
        if (mounted) setState(() {});
      }
      
    } else if (type == 'hb') {
      // Handle heartbeat
      debugPrint('Received heartbeat');
      
    } else if (type == 'error') {
      // Handle server error messages
      final errorMessage = message['message'] as String? ?? 'Unknown server error';
      final errorCode = message['code'] as String? ?? 'unknown';
      debugPrint('Server error: $errorCode - $errorMessage');
      
    } else if (type == 'processing_started') {
      // Handle processing started
      final docId = data?['docId'] as String?;
      debugPrint('Processing started for docId: $docId');
      
    } else if (type == 'processing_completed' && data != null) {
      final gptReady = data['gpt_ready'] as bool? ?? false;
      final docId = data['docId'] as String?;
      
      debugPrint('[StreamWsPage] ===== PROCESSING_COMPLETED RECEIVED =====');
      debugPrint('[StreamWsPage] gptReady: $gptReady, docId: $docId');
      debugPrint('[StreamWsPage] Data: $data');
      debugPrint('[StreamWsPage] Current state: ${_cubit.state.runtimeType}');
      debugPrint('[StreamWsPage] Is mounted: $mounted');
      debugPrint('[StreamWsPage] WebSocket connected: ${_wsService.isConnected}');
      debugPrint('[StreamWsPage] ===== END PROCESSING_COMPLETED =====');
      
      if (gptReady && docId != null && docId.isNotEmpty) {
        debugPrint('[StreamWsPage] GPT ready! Navigating to chat with docId: $docId');
        
        // Only navigate if we're in loading state
        if (_cubit.state is LoadingState) {
          // Cancel loading timeout
          _loadingTimeout?.cancel();
          _perfectFrameTimeout?.cancel();
          
          // Keep WebSocket connection alive for chat
          _wsService.keepAlive();
          debugPrint('[StreamWsPage] ===== CHAT TRANSITION =====');
          debugPrint('[StreamWsPage] WebSocket connection kept alive for chat');
          debugPrint('[StreamWsPage] DocId for chat: $docId');
          debugPrint('[StreamWsPage] WebSocket status: ${_wsService.connectionInfo}');
          
          // Create adapter and set docId
          final adapter = WsServiceAdapter(_wsService);
          adapter.setDocId(docId);
          
          debugPrint('[StreamWsPage] Navigating to chat screen...');
          // Navigate to chat screen
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => ChatScreen(
                docId: docId,
                webSocketManager: adapter,
              ),
            ),
          ).then((_) {
            // When returning from chat, go back to initial state
            _cancelLoading();
          });
        } else {
          debugPrint('[StreamWsPage] Not in loading state, cannot navigate to chat');
        }
      } else if (!gptReady) {
        debugPrint('[StreamWsPage] GPT not ready yet, staying on loading...');
      }
    } else {
      debugPrint('Unknown message type: $type, full message: $message');
    }
  }

  // OLD METHOD REMOVED - guidance handling moved to _handleWsServiceMessage
  void _handleWebSocketMessage_OLD(dynamic data) {
    try {
      // Handle JSON messages (NOOR API guidance responses)
      final m = jsonDecode(data.toString()) as Map<String, dynamic>;
      final type = m['type'];

      if (type == 'guidance') {
        // Parse NOOR guidance response with semantic class system
        // Server now responds every 2 seconds with the most frequent class from the last 2 seconds
        final direction = m['class'] as String? ?? 'no_document'; // Default to no document
        final coverage = (m['coverage'] ?? 0.0).toDouble();
        final confidence = (m['conf'] ?? 0.0).toDouble();
        final ready = m['ready'] as bool? ?? false;
        final skewDeg = (m['skew_deg'] ?? 0.0).toDouble();

        debugPrint('Received guidance (2s interval): $direction, coverage: $coverage, confidence: $confidence, ready: $ready');

        // Update guidance state with the most frequent class from the last 2 seconds
        _cubit.updateGuidance(
          direction: direction,
          coverage: coverage,
          confidence: confidence,
          ready: ready,
        );

        // Log when we receive perfect guidance with ready=true
        if (direction == 'perfect' && ready == true) {
          debugPrint('PERFECT FRAME DETECTED: direction=$direction, ready=$ready, coverage=$coverage, confidence=$confidence');
          debugPrint('Waiting for server to send final_frame_captured message...');
          
          // Cancel any existing timeout
          _perfectFrameTimeout?.cancel();
          
          // Start a 10-second timeout for perfect frame
          _lastPerfectFrameTime = DateTime.now();
          _perfectFrameTimeout = Timer(const Duration(seconds: 10), () {
            if (mounted && !_finalizedReceived) {
              debugPrint('Perfect frame timeout: Server did not send final_frame_captured within 10 seconds');
              debugPrint('Triggering loading state manually...');
              
              // Manually trigger loading state
              _finalizedReceived = true;
              _allowFrameSend = false;
              _frameQueue.clear();
              
              if (_cam?.value.isStreamingImages == true) {
                _cam?.stopImageStream();
                debugPrint('Camera stream stopped (timeout)');
              }
              
              _cubit.setLoading(
                sessionId: 'timeout_${DateTime.now().millisecondsSinceEpoch}',
                savedPath: 'timeout_triggered',
              );
              
              _loadingErrorMessage = 'Server timeout: Perfect frame detected but no final_frame_captured received';
              
              // Start 30s timeout for loading
              _loadingTimeout = Timer(const Duration(seconds: 30), () {
                if (mounted && _cubit.state is LoadingState) {
                  _showTimeoutError = true;
                  setState(() {});
                }
              });
              
        if (mounted) setState(() {});
            }
          });
        }

        if (mounted) setState(() {});
        
      } else if (type == 'final_frame_captured') {
        // Handle final frame captured - stop streaming and show loading
        final sessionId = m['sessionId'] as String? ?? 'unknown';
        final savedPath = m['saved_path'];
        
        debugPrint('onFinalFrameCaptured sessionId=$sessionId action=stop_stream keep_ws=true');
        
        // Prevent duplicate processing
        if (!_finalizedReceived) {
          _finalizedReceived = true;
          _allowFrameSend = false;
          
          // Clear frame queue
          _frameQueue.clear();
          debugPrint('Frame queue cleared');
          
          // Stop camera stream
          if (_cam?.value.isStreamingImages == true) {
            _cam?.stopImageStream();
            debugPrint('Camera stream stopped');
          }
          
          // Transition to loading state
          _cubit.setLoading(
            sessionId: sessionId,
            savedPath: (savedPath is String) ? savedPath : '',
          );

          // If server failed to provide saved_path
          if (savedPath == null) {
            _loadingErrorMessage = 'Failed to save the final frame on server.';
        } else {
            _loadingErrorMessage = null;
          }
          
          // Start 30s timeout
          _loadingTimeout = Timer(const Duration(seconds: 30), () {
            if (mounted && _cubit.state is LoadingState) {
              _showTimeoutError = true;
              setState(() {});
            }
          });
          
        if (mounted) setState(() {});
        }
        
      } else if (type == 'processing_done') {
        // Exit loading on success
        final sessionId = m['sessionId'];
        debugPrint('processing_done received for sessionId=$sessionId');
        _loadingTimeout?.cancel();
        _showTimeoutError = false;
        _loadingErrorMessage = null;
        // TODO: navigate or update UI for next phase (e.g., OCR)
        // For now, return to Idle to complete the flow
        _cancelLoading();
        
      } else if (type == 'hb') {
        // Handle heartbeat - no UI changes needed
        debugPrint('Received heartbeat');
        
      } else if (type == 'error') {
        // Handle server error messages
        final errorMessage = m['message'] as String? ?? 'Unknown server error';
        final errorCode = m['code'] as String? ?? 'unknown';
        debugPrint('Server error: $errorCode - $errorMessage');
        
        // Don't stop streaming for errors, just log them
        
      } else if (type == 'processing_start' || type == 'processing_progress' || 
                 type == 'stage_change' || type == 'processing_done') {
        // Future compatibility - placeholder for processing messages
        debugPrint('Received processing message: $type');
        
      } else {
        debugPrint('Unknown message type: $type, full message: $m');
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
      if (!mounted) return;
      final isLoading = _cubit.state is LoadingState;
      final shouldReconnect = (_cubit.state is StreamingState) || isLoading;
      if (shouldReconnect) {
        _isReconnectingBanner = true;
        _reconnectAttempts++;
        setState(() {});
        debugPrint('Attempting to reconnect... (attempt: $_reconnectAttempts)');
        // WsService handles reconnection automatically
      }
    });
  }
  
  // OLD RECONNECTION METHOD REMOVED - WsService handles reconnection automatically
  
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

  void _cancelLoading() {
    debugPrint('User cancelled loading - resetting to initial state');
    
    // Cancel timeouts
    _loadingTimeout?.cancel();
    _loadingTimeout = null;
    _perfectFrameTimeout?.cancel();
    _perfectFrameTimeout = null;
    _showTimeoutError = false;
    
    // Close WebSocket
    // Old WebSocket subscription removed - WsService handles this
    // WsService cleanup handled in dispose()
    // WsService cleanup handled in dispose()
    
    // Stop camera
    if (_cam?.value.isStreamingImages == true) {
      _cam?.stopImageStream();
    }
    
    // Reset flags
    _allowFrameSend = true;
    _finalizedReceived = false;
    _lastPerfectFrameTime = null;
    
    // Clear queues
    _frameQueue.clear();
    
    // Reset to initial state
    _cubit.cancelLoading();
    
    if (mounted) setState(() {});
  }

  void _retryAfterTimeout() {
    debugPrint('User retrying after timeout - resetting to initial state');
    
    // Same as cancel but with retry intent
    _cancelLoading();
  }

  // Helper methods for guidance display
  IconData _getDirectionIcon(String? direction) {
    switch (direction) {
      case 'top_left':
        return Icons.north_west;  // top-left corner
      case 'top_right':
        return Icons.north_east; // top-right corner
      case 'bottom_left':
        return Icons.south_west; // bottom-left corner
      case 'bottom_right':
        return Icons.south_east; // bottom-right corner
      case 'paper_face_only':
        return Icons.center_focus_strong; // partial framing
      case 'perfect':
        return Icons.check_circle; // perfect framing
      case 'no_document':
        return Icons.help_outline; // no document detected
      default:
        return Icons.center_focus_strong;
    }
  }

  Color _getDirectionColor(String? direction) {
    switch (direction) {
      case 'perfect':
        return Colors.green; // perfect framing
      case 'paper_face_only':
        return Colors.blue; // partial framing
      case 'no_document':
        return Colors.red; // no document
      default:
        return Colors.orange; // corner cases
    }
  }

  String _getClassDescription(String? direction) {
    switch (direction) {
      case 'top_left':
        return 'Move camera up and left';
      case 'top_right':
        return 'Move camera up and right';
      case 'bottom_right':
        return 'Move camera down and right';
      case 'bottom_left':
        return 'Move camera down and left';
      case 'paper_face_only':
        return 'Show more of the document';
      case 'perfect':
        return 'Perfect framing!';
      case 'no_document':
        return 'No document detected';
      default:
        return 'Unknown guidance';
    }
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
                      // Live camera preview with direction overlay
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // Camera preview - ensure it fills the entire space
                            _cam != null 
                              ? SizedBox.expand(
                                  child: FittedBox(
                                    fit: BoxFit.cover,
                                    child: SizedBox(
                                      width: _cam!.value.previewSize?.height ?? 0,
                                      height: _cam!.value.previewSize?.width ?? 0,
                                      child: CameraPreview(_cam!),
                                    ),
                                  ),
                                )
                              : const SizedBox(),
                            // Class ID overlay
                            Center(
                              child: Text(
                                state.guidanceDirection ?? 'no_document',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: _getDirectionColor(state.guidanceDirection),
                                  shadows: [
                                    Shadow(
                                      offset: Offset(1, 1),
                                      blurRadius: 3,
                                      color: Colors.black.withOpacity(0.8),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // Loading overlay for final_frame_captured
                            if (state is LoadingState)
                              Container(
                                color: Colors.black.withOpacity(0.8),
                                child: Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      if (_isReconnectingBanner)
                                        Padding(
                                          padding: const EdgeInsets.only(bottom: 12),
                                          child: Text(
                                            'Reconnecting… (attempt: $_reconnectAttempts)',
                                            style: const TextStyle(color: Colors.orange, fontSize: 12),
                                          ),
                                        ),
                                      const CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 3,
                                      ),
                                      const SizedBox(height: 20),
                                      const Text(
                                        'Processing...',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        'Session: ${(state as LoadingState).sessionId}',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const SizedBox(height: 30),
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          ElevatedButton(
                                            onPressed: _cancelLoading,
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.red,
                                              foregroundColor: Colors.white,
                                            ),
                                            child: const Text('Cancel'),
                                          ),
                                          if (_showTimeoutError) ...[
                                            const SizedBox(width: 20),
                                            ElevatedButton(
                                              onPressed: _retryAfterTimeout,
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: Colors.orange,
                                                foregroundColor: Colors.white,
                                              ),
                                              child: const Text('Retry'),
                                            ),
                                          ],
                                        ],
                                      ),
                                      if (_loadingErrorMessage != null)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 10),
                                          child: Text(
                                            _loadingErrorMessage!,
                                            style: const TextStyle(
                                              color: Colors.redAccent,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                      if (_showTimeoutError)
                                        const Padding(
                                          padding: EdgeInsets.only(top: 10),
                                          child: Text(
                                            'Processing is taking longer than expected',
                                            style: TextStyle(
                                              color: Colors.orange,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      
                      // Stats panel
                      Container(
                        padding: const EdgeInsets.all(16),
                        color: Colors.grey[100],
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            
                            const SizedBox(height: 8),
                            
                                                         // Performance metrics
                             Row(
                               children: [
                                 const Text('Performance: ', style: TextStyle(fontWeight: FontWeight.bold)),
                                 Text('FPS: ${_currentFps.toStringAsFixed(1)} | Dropped: $_framesDropped | Latency: ${_networkLatency}ms'),
                               ],
                             ),
                             
                             // Server response timing info
                               Row(
                                 children: [
                                   const Text('Server: ', style: TextStyle(fontWeight: FontWeight.bold)),
                                 const Text('Guidance every 2s | ', style: TextStyle(fontSize: 12)),
                                 Text('Class: ${state.guidanceDirection ?? 'no_document'}', 
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
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
                            
                            // Fixed settings display
                             Row(
                               children: [
                                const Text('Target FPS: ', style: TextStyle(fontWeight: FontWeight.bold)),
                                Text('${state.targetFps}'),
                                const SizedBox(width: 20),
                                 const Text('JPEG Quality: ', style: TextStyle(fontWeight: FontWeight.bold)),
                                 Text('$jpegQuality'),
                                const SizedBox(width: 20),
                                 const Text('Adaptive Quality: ', style: TextStyle(fontWeight: FontWeight.bold)),
                                 Text('$_adaptiveQuality', style: TextStyle(
                                   color: _networkSlow ? Colors.orange : Colors.green,
                                   fontWeight: FontWeight.bold,
                                 )),
                                 if (_networkSlow)
                                  const Text(' (Slow)', style: TextStyle(color: Colors.orange, fontSize: 12)),
                               ],
                             ),
                            
                            const SizedBox(height: 16),
                            
                            // Sent Frames Container
                            const Text('Sent Frames:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            const SizedBox(height: 8),
                            Container(
                              height: 120,
                              child: _sentFrames.isEmpty
                                  ? const Center(child: Text('No frames sent yet'))
                                  : ListView.builder(
                                      scrollDirection: Axis.horizontal,
                                      itemCount: _sentFrames.length,
                                      itemBuilder: (context, index) {
                                        final frame = _sentFrames[index];
                                        return Container(
                                          width: 120,
                                          margin: const EdgeInsets.only(right: 8),
                                          child: GestureDetector(
                                            onTap: () => _showImageModal(frame, null),
                                            child: Column(
                                              children: [
                                                Expanded(
                                                  child: Container(
                                                    decoration: BoxDecoration(
                                                      border: Border.all(color: Colors.grey),
                                                      borderRadius: BorderRadius.circular(8),
                                                    ),
                                                    child: ClipRRect(
                                                      borderRadius: BorderRadius.circular(8),
                                                      child: Image.memory(
                                                        frame.jpegData,
                                                        fit: BoxFit.cover,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  'Frame ${frame.id}',
                                                  style: const TextStyle(fontSize: 12),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
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