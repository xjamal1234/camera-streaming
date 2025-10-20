import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

/// WebSocket connection status
enum WebSocketStatus {
  disconnected,
  connecting,
  connected,
  reconnecting,
  error,
}

/// WebSocket event types
enum WebSocketEvent {
  connecting,
  open,
  close,
  message,
  error,
  reconnecting,
  reconnected,
}

/// WebSocket event data
class WebSocketEventData {
  final WebSocketEvent event;
  final dynamic data;
  final DateTime timestamp;

  WebSocketEventData({
    required this.event,
    this.data,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Envelope message format for chat
class Envelope<T> {
  final String type;
  final T data;

  Envelope({
    required this.type,
    required this.data,
  });

  Map<String, dynamic> toJson() => {
    'type': type,
    'data': data,
  };

  factory Envelope.fromJson(Map<String, dynamic> json) {
    return Envelope(
      type: json['type'] as String,
      data: json['data'] as T,
    );
  }
}

/// Chat user message payload
class ChatUserPayload {
  final String docId;
  final String text;
  final String locale;

  ChatUserPayload({
    required this.docId,
    required this.text,
    this.locale = 'ar',
  });

  Map<String, dynamic> toJson() => {
    'docId': docId,
    'text': text,
    'locale': locale,
  };
}

/// Chat assistant message payload
class ChatAssistantPayload {
  final String text;
  final Map<String, dynamic>? meta;

  ChatAssistantPayload({
    required this.text,
    this.meta,
  });

  factory ChatAssistantPayload.fromJson(Map<String, dynamic> json) {
    return ChatAssistantPayload(
      text: json['text'] as String,
      meta: json['meta'] as Map<String, dynamic>?,
    );
  }
}

/// Robust WebSocket manager with auto-reconnect, backoff, and session management
class WebSocketManager {
  static final WebSocketManager _instance = WebSocketManager._internal();
  factory WebSocketManager() => _instance;
  WebSocketManager._internal();

  WebSocketChannel? _channel;
  WebSocketStatus _status = WebSocketStatus.disconnected;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  int _reconnectAttempts = 0;
  final int _maxReconnectAttempts = 10;
  final List<Duration> _backoffDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
  ];

  // Event streams
  final StreamController<WebSocketEventData> _eventController = 
      StreamController<WebSocketEventData>.broadcast();
  final StreamController<Envelope> _messageController = 
      StreamController<Envelope>.broadcast();

  // Message queue for when disconnected
  final List<Envelope> _messageQueue = [];
  final int _maxQueueSize = 20;

  // Session data
  String? _currentDocId;
  String? _sessionToken;
  DateTime? _lastActivity;

  // Getters
  WebSocketStatus get status => _status;
  String get statusName => _status.name;
  bool get isConnected => _status == WebSocketStatus.connected;
  String? get currentDocId => _currentDocId;
  String? get sessionToken => _sessionToken;
  DateTime? get lastActivity => _lastActivity;

  // Event streams
  Stream<WebSocketEventData> get onEvent => _eventController.stream;
  Stream<Envelope> get onMessage => _messageController.stream;

  /// Connect to WebSocket with session management
  Future<void> connect({
    required String url,
    required String docId,
    String? sessionToken,
  }) async {
    if (_status == WebSocketStatus.connecting || 
        _status == WebSocketStatus.connected) {
      debugPrint('[WebSocketManager] Already connecting or connected');
      return;
    }

    _currentDocId = docId;
    _sessionToken = sessionToken;
    _reconnectAttempts = 0;

    await _connectInternal(url);
  }

  /// Internal connection method
  Future<void> _connectInternal(String url) async {
    try {
      _status = WebSocketStatus.connecting;
      _emitEvent(WebSocketEvent.connecting);

      // Build URL with optional session token
      String finalUrl = url;
      if (_sessionToken != null && _sessionToken!.isNotEmpty) {
        final separator = url.contains('?') ? '&' : '?';
        finalUrl = '$url${separator}token=$_sessionToken';
      }

      debugPrint('[WebSocketManager] Connecting to: $finalUrl');
      _channel = IOWebSocketChannel.connect(Uri.parse(finalUrl));

      // Wait for connection
      await _channel!.ready;
      
      _status = WebSocketStatus.connected;
      _reconnectAttempts = 0;
      _lastActivity = DateTime.now();

      _emitEvent(WebSocketEvent.open);
      debugPrint('[WebSocketManager] Connected successfully');

      // Set up message listener
      _channel!.stream.listen(
        _handleMessage,
        onError: _handleError,
        onDone: _handleClose,
      );

      // Flush queued messages
      _flushMessageQueue();

      // Start ping timer (optional)
      _startPingTimer();

    } catch (e) {
      debugPrint('[WebSocketManager] Connection failed: $e');
      _status = WebSocketStatus.error;
      _emitEvent(WebSocketEvent.error, e);
      _scheduleReconnect(url);
    }
  }

  /// Send envelope message
  void send(Envelope envelope) {
    if (_status != WebSocketStatus.connected || _channel == null) {
      debugPrint('[WebSocketManager] Cannot send, not connected. Queueing message.');
      _queueMessage(envelope);
      return;
    }

    try {
      final jsonString = jsonEncode(envelope.toJson());
      _channel!.sink.add(jsonString);
      _lastActivity = DateTime.now();
      debugPrint('[WebSocketManager] Sent: ${envelope.type}');
    } catch (e) {
      debugPrint('[WebSocketManager] Send error: $e');
      _queueMessage(envelope);
    }
  }

  /// Send chat user message
  void sendChatMessage(String docId, String text, {String locale = 'ar'}) {
    final payload = ChatUserPayload(
      docId: docId,
      text: text,
      locale: locale,
    );
    
    final envelope = Envelope<ChatUserPayload>(
      type: 'chat_user',
      data: payload,
    );
    
    send(envelope);
  }

  /// Disconnect WebSocket
  Future<void> disconnect() async {
    debugPrint('[WebSocketManager] Disconnecting...');
    
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    
    if (_channel != null) {
      await _channel!.sink.close();
      _channel = null;
    }
    
    _status = WebSocketStatus.disconnected;
    _emitEvent(WebSocketEvent.close);
    _messageQueue.clear();
  }

  /// Handle incoming messages
  void _handleMessage(dynamic data) {
    try {
      final Map<String, dynamic> json = jsonDecode(data.toString());
      final envelope = Envelope.fromJson(json);
      
      _lastActivity = DateTime.now();
      _messageController.add(envelope);
      debugPrint('[WebSocketManager] Received: ${envelope.type}');
      
    } catch (e) {
      debugPrint('[WebSocketManager] Message parse error: $e');
    }
  }

  /// Handle WebSocket errors
  void _handleError(error) {
    debugPrint('[WebSocketManager] WebSocket error: $error');
    _status = WebSocketStatus.error;
    _emitEvent(WebSocketEvent.error, error);
    _scheduleReconnect(_getCurrentUrl());
  }

  /// Handle WebSocket close
  void _handleClose() {
    debugPrint('[WebSocketManager] WebSocket closed');
    _status = WebSocketStatus.disconnected;
    _emitEvent(WebSocketEvent.close);
    _scheduleReconnect(_getCurrentUrl());
  }

  /// Schedule reconnection with exponential backoff
  void _scheduleReconnect(String url) {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint('[WebSocketManager] Max reconnect attempts reached');
      _status = WebSocketStatus.error;
      _emitEvent(WebSocketEvent.error, 'Max reconnect attempts reached');
      return;
    }

    _reconnectAttempts++;
    _status = WebSocketStatus.reconnecting;
    _emitEvent(WebSocketEvent.reconnecting);

    // Calculate backoff delay with jitter
    final delayIndex = (_reconnectAttempts - 1).clamp(0, _backoffDelays.length - 1);
    final baseDelay = _backoffDelays[delayIndex];
    final jitter = Duration(milliseconds: (baseDelay.inMilliseconds * 0.2 * (Random().nextDouble() - 0.5)).round());
    final finalDelay = baseDelay + jitter;

    debugPrint('[WebSocketManager] Scheduling reconnect attempt $_reconnectAttempts in ${finalDelay.inSeconds}s');
    
    _reconnectTimer = Timer(finalDelay, () {
      if (_status == WebSocketStatus.reconnecting) {
        _connectInternal(url);
      }
    });
  }

  /// Queue message when disconnected
  void _queueMessage(Envelope envelope) {
    if (_messageQueue.length >= _maxQueueSize) {
      _messageQueue.removeAt(0); // Remove oldest
    }
    _messageQueue.add(envelope);
    debugPrint('[WebSocketManager] Queued message: ${envelope.type}');
  }

  /// Flush queued messages when connected
  void _flushMessageQueue() {
    if (_messageQueue.isEmpty) return;
    
    debugPrint('[WebSocketManager] Flushing ${_messageQueue.length} queued messages');
    
    for (final envelope in _messageQueue) {
      send(envelope);
    }
    
    _messageQueue.clear();
  }

  /// Start ping timer (optional)
  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(Duration(seconds: 30), (timer) {
      if (_status == WebSocketStatus.connected && _channel != null) {
        try {
          _channel!.sink.add('ping');
          _lastActivity = DateTime.now();
        } catch (e) {
          debugPrint('[WebSocketManager] Ping failed: $e');
        }
      }
    });
  }

  /// Get current URL (for reconnection)
  String _getCurrentUrl() {
    // This would need to be stored from the original connection
    // For now, return a placeholder - in real implementation, store the original URL
    return 'wss://c10d731adcf6.ngrok-free.app/ws/guidance';
  }

  /// Emit event to listeners
  void _emitEvent(WebSocketEvent event, [dynamic data]) {
    _eventController.add(WebSocketEventData(
      event: event,
      data: data,
    ));
  }

  /// Dispose resources
  void dispose() {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _channel?.sink.close();
    _eventController.close();
    _messageController.close();
    _messageQueue.clear();
  }
}
