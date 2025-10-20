import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

/// Shared WebSocket service for guidance and chat communication
/// 
/// This service provides a single WebSocket connection that can be reused
/// across multiple screens (Loading, Chat) to maintain state and reduce
/// connection overhead.
class WsService {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  final StreamController<Map<String, dynamic>> _messageController = 
      StreamController<Map<String, dynamic>>.broadcast();
  
  bool _isConnected = false;
  bool _isConnecting = false;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;
  static const Duration _reconnectDelay = Duration(seconds: 3);
  
  String? _lastUrl;
  DateTime? _lastHeartbeatAt;
  
  /// Whether the WebSocket is currently connected
  bool get isConnected => _isConnected;
  
  /// Last heartbeat timestamp for diagnostics
  DateTime? get lastHeartbeatAt => _lastHeartbeatAt;
  
  /// Get connection info for debugging
  Map<String, dynamic> get connectionInfo => {
    'isConnected': _isConnected,
    'isConnecting': _isConnecting,
    'lastUrl': _lastUrl,
    'reconnectAttempts': _reconnectAttempts,
    'maxReconnectAttempts': _maxReconnectAttempts,
    'lastHeartbeatAt': _lastHeartbeatAt?.toIso8601String(),
  };
  
  /// Stream of parsed WebSocket messages
  /// Messages are in the format: { "type": "...", "data": { ... } }
  Stream<Map<String, dynamic>> get onMessage => _messageController.stream;
  
  /// Connect to the WebSocket server
  /// 
  /// [url] - WebSocket URL (e.g., 'wss://host/ws/guidance')
  /// [token] - Optional authentication token (passed as query param)
  Future<void> connectWs({required String url, String? token}) async {
    if (_isConnecting) {
      debugPrint('[WsService] Already connecting, skipping...');
      return;
    }
    
    if (_isConnected && _lastUrl == url) {
      debugPrint('[WsService] Already connected to $url');
      return;
    }
    
    _isConnecting = true;
    _lastUrl = url;
    
    try {
      // Build URL with optional token
      final wsUrl = token != null && token.isNotEmpty 
          ? '$url?token=$token' 
          : url;
      
      debugPrint('[WsService] Connecting to $wsUrl');
      
      // Close existing connection if any
      await _closeConnection();
      
      // Create new connection
      _channel = IOWebSocketChannel.connect(Uri.parse(wsUrl));
      
      // Listen to messages
      _subscription = _channel!.stream.listen(
        _handleMessage,
        onError: _handleError,
        onDone: _handleDone,
        cancelOnError: false,
      );
      
      _isConnected = true;
      _isConnecting = false;
      _reconnectAttempts = 0;
      
      debugPrint('[WsService] ===== WEBSOCKET CONNECTED =====');
      debugPrint('[WsService] Connected successfully to $url');
      debugPrint('[WsService] Connection established at: ${DateTime.now()}');
      
      // Emit connection status
      _messageController.add({
        'type': '_ws_connected',
        'data': {'connected': true},
      });
      
    } catch (e) {
      _isConnecting = false;
      _isConnected = false;
      debugPrint('[WsService] Connection error: $e');
      
      _messageController.add({
        'type': '_ws_error',
        'data': {'error': e.toString()},
      });
      
      // Schedule reconnect
      _scheduleReconnect();
    }
  }
  
  /// Send JSON message to the server
  /// 
  /// [message] - Map to be sent as JSON
  void sendJson(Map<String, dynamic> message) {
    if (!_isConnected || _channel == null) {
      debugPrint('[WsService] Cannot send, not connected');
      _messageController.add({
        'type': '_ws_error',
        'data': {'error': 'Not connected'},
      });
      return;
    }
    
    try {
      final jsonString = jsonEncode(message);
      _channel!.sink.add(jsonString);
      debugPrint('[WsService] Sent: ${message['type']}');
    } catch (e) {
      debugPrint('[WsService] Send error: $e');
      _messageController.add({
        'type': '_ws_error',
        'data': {'error': 'Send failed: $e'},
      });
    }
  }

  void sendBinary(List<int> data) {
    if (!_isConnected || _channel == null) {
      debugPrint('[WsService] Cannot send binary, not connected');
      return;
    }
    
    try {
      _channel!.sink.add(data);
      debugPrint('[WsService] Sent binary data: ${data.length} bytes');
    } catch (e) {
      debugPrint('[WsService] Error sending binary data: $e');
    }
  }
  
  /// Handle incoming WebSocket messages
  void _handleMessage(dynamic data) {
    try {
      final Map<String, dynamic> message = jsonDecode(data.toString());
      final String type = message['type'] as String? ?? 'unknown';
      
      debugPrint('[WsService] Received: $type');
      debugPrint('[WsService] Full message: $message');
      
      // Track heartbeat for diagnostics
      if (type == 'hb') {
        _lastHeartbeatAt = DateTime.now();
        debugPrint('[WsService] Heartbeat received at: ${_lastHeartbeatAt?.toIso8601String()}');
      }
      
      // Emit parsed message to listeners
      _messageController.add(message);
      
    } catch (e) {
      debugPrint('[WsService] Message parse error: $e');
      debugPrint('[WsService] Raw data: $data');
    }
  }
  
  /// Handle WebSocket errors
  void _handleError(error) {
    debugPrint('[WsService] WebSocket error: $error');
    _isConnected = false;
    
    _messageController.add({
      'type': '_ws_error',
      'data': {'error': error.toString()},
    });
    
    _scheduleReconnect();
  }
  
  /// Handle WebSocket connection close
  void _handleDone() {
    debugPrint('[WsService] ===== WEBSOCKET CONNECTION CLOSED =====');
    debugPrint('[WsService] Connection closed at: ${DateTime.now()}');
    debugPrint('[WsService] Last URL: $_lastUrl');
    debugPrint('[WsService] Reconnect attempts: $_reconnectAttempts');
    _isConnected = false;
    
    _messageController.add({
      'type': '_ws_disconnected',
      'data': {'connected': false},
    });
    
    _scheduleReconnect();
  }
  
  /// Schedule automatic reconnection
  void _scheduleReconnect() {
    if (_reconnectTimer != null && _reconnectTimer!.isActive) {
      return;
    }
    
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint('[WsService] Max reconnect attempts reached');
      _messageController.add({
        'type': '_ws_max_reconnect',
        'data': {'message': 'Max reconnection attempts reached'},
      });
      return;
    }
    
    _reconnectAttempts++;
    debugPrint('[WsService] Scheduling reconnect attempt $_reconnectAttempts in ${_reconnectDelay.inSeconds}s');
    
    _messageController.add({
      'type': '_ws_reconnecting',
      'data': {'attempt': _reconnectAttempts, 'max': _maxReconnectAttempts},
    });
    
    _reconnectTimer = Timer(_reconnectDelay, () {
      if (_lastUrl != null) {
        connectWs(url: _lastUrl!);
      }
    });
  }
  
  /// Close the WebSocket connection
  Future<void> _closeConnection() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    
    await _subscription?.cancel();
    _subscription = null;
    
    _channel?.sink.close();
    _channel = null;
    
    _isConnected = false;
  }
  
  /// Keep connection alive (prevent automatic disconnection)
  void keepAlive() {
    debugPrint('[WsService] Keeping connection alive for chat');
    // Reset reconnect attempts to prevent disconnection
    _reconnectAttempts = 0;
  }

  /// Dispose the service and clean up resources
  Future<void> dispose() async {
    debugPrint('[WsService] Disposing...');
    await _closeConnection();
    await _messageController.close();
  }
}

