import 'dart:async';
import 'package:flutter/foundation.dart';
import 'ws_service.dart';
import 'websocket_manager.dart';

/// Adapter to make WsService compatible with WebSocketManager interface
/// This allows the existing WsService to work with the new ChatScreen
class WsServiceAdapter {
  final WsService _wsService;
  StreamSubscription? _messageSubscription;
  StreamSubscription? _statusSubscription;
  final StreamController<Envelope> _messageController = 
      StreamController<Envelope>.broadcast();
  
  // Store docId for chat messages
  String? _currentDocId;

  WsServiceAdapter(this._wsService) {
    _setupListeners();
  }

  void _setupListeners() {
    // Listen to WsService messages and convert them to WebSocketManager format
    _messageSubscription = _wsService.onMessage.listen((message) {
      try {
        // Convert WsService message format to Envelope format
        final envelope = Envelope<Map<String, dynamic>>.fromJson(message);
        _messageController.add(envelope);
        debugPrint('[WsServiceAdapter] Received message: ${envelope.type}');
      } catch (e) {
        debugPrint('[WsServiceAdapter] Error converting message: $e');
        debugPrint('[WsServiceAdapter] Raw message: $message');
      }
    });
  }

  WebSocketStatus get status {
    if (_wsService.isConnected) {
      return WebSocketStatus.connected;
    } else {
      return WebSocketStatus.disconnected;
    }
  }

  // Add a name property to match WebSocketManager interface
  String get statusName => status.name;

  bool get isConnected => _wsService.isConnected;

  String? get currentDocId => _currentDocId;

  String? get sessionToken => null; // WsService doesn't track session token

  DateTime? get lastActivity => null; // WsService doesn't track activity

  Stream<WebSocketEventData> get onEvent {
    // Create a simple event stream based on connection status
    return Stream.periodic(const Duration(seconds: 1)).map((_) {
      if (_wsService.isConnected) {
        return WebSocketEventData(event: WebSocketEvent.open);
      } else {
        return WebSocketEventData(event: WebSocketEvent.close);
      }
    }).distinct((prev, next) => prev.event == next.event);
  }

  Stream<Envelope> get onMessage => _messageController.stream;

  Future<void> connect({
    required String url,
    required String docId,
    String? sessionToken,
  }) async {
    // Store the docId for chat messages
    _currentDocId = docId;
    debugPrint('[WsServiceAdapter] Stored docId: $docId');
    
    // Use WsService's connect method
    await _wsService.connectWs(url: url, token: sessionToken);
  }

  /// Set the docId for chat messages
  void setDocId(String docId) {
    _currentDocId = docId;
    debugPrint('[WsServiceAdapter] Set docId: $docId');
  }

  /// Get connection info for debugging
  Map<String, dynamic> get connectionInfo => {
    'isConnected': isConnected,
    'status': statusName,
    'docId': _currentDocId,
    'wsServiceInfo': _wsService.connectionInfo,
  };

  void send(Envelope envelope) {
    // Convert Envelope to WsService format
    final message = envelope.toJson();
    debugPrint('[WsServiceAdapter] Sending message: $message');
    _wsService.sendJson(message);
  }

  void sendChatMessage(String docId, String text, {String locale = 'ar'}) {
    // Use provided docId or fall back to stored docId
    final finalDocId = docId.isNotEmpty ? docId : (_currentDocId ?? '');
    
    if (finalDocId.isEmpty) {
      debugPrint('[WsServiceAdapter] ERROR: No docId available for chat message');
      return;
    }
    
    final payload = {
      'docId': finalDocId,
      'text': text,
      'locale': locale,
    };
    
    debugPrint('[WsServiceAdapter] Creating chat message with payload: $payload');
    
    final envelope = Envelope<Map<String, dynamic>>(
      type: 'chat_user',
      data: payload,
    );
    
    debugPrint('[WsServiceAdapter] Created envelope: ${envelope.toJson()}');
    send(envelope);
  }

  Future<void> disconnect() async {
    _messageSubscription?.cancel();
    _statusSubscription?.cancel();
    // Note: We don't disconnect WsService as it might be used by other parts
  }

  void dispose() {
    _messageSubscription?.cancel();
    _statusSubscription?.cancel();
    _messageController.close();
  }
}
