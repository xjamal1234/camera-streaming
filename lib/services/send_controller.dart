import 'dart:async';
import 'package:flutter/foundation.dart';
import 'websocket_manager.dart';

/// Controller for managing message sending with debouncing and validation
class SendController {
  final dynamic _webSocketManager; // Accept both WebSocketManager and WsServiceAdapter
  Timer? _debounceTimer;
  String? _lastMessage;
  DateTime? _lastSendTime;
  
  // Debounce window: 600ms
  static const Duration _debounceWindow = Duration(milliseconds: 600);
  
  SendController(this._webSocketManager);

  /// Send a chat message with debouncing
  /// Returns true if message was sent, false if debounced
  bool sendMessage({
    required String docId,
    required String text,
    String locale = 'ar',
  }) {
    // Trim and validate text
    final trimmedText = text.trim();
    if (trimmedText.isEmpty) {
      debugPrint('[SendController] Empty message, ignoring');
      return false;
    }

    // Check for duplicate within debounce window
    final now = DateTime.now();
    if (_lastMessage == trimmedText && 
        _lastSendTime != null && 
        now.difference(_lastSendTime!) < _debounceWindow) {
      debugPrint('[SendController] Duplicate message within debounce window, ignoring');
      return false;
    }

    // Cancel any existing debounce timer
    _debounceTimer?.cancel();

    // Set up debounce timer
    _debounceTimer = Timer(_debounceWindow, () {
      _sendMessageInternal(docId, trimmedText, locale);
    });

    // Update last message and time
    _lastMessage = trimmedText;
    _lastSendTime = now;

    debugPrint('[SendController] Message queued for sending: "$trimmedText"');
    return true;
  }

  /// Send message immediately (bypass debounce)
  void sendMessageImmediate({
    required String docId,
    required String text,
    String locale = 'ar',
  }) {
    final trimmedText = text.trim();
    if (trimmedText.isEmpty) {
      debugPrint('[SendController] Empty message, ignoring');
      return;
    }

    _sendMessageInternal(docId, trimmedText, locale);
  }

  /// Internal method to send message
  void _sendMessageInternal(String docId, String text, String locale) {
    try {
      debugPrint('[SendController] ===== SENDING MESSAGE INTERNAL =====');
      debugPrint('[SendController] DocId: $docId');
      debugPrint('[SendController] Text: $text');
      debugPrint('[SendController] Locale: $locale');
      debugPrint('[SendController] WebSocketManager type: ${_webSocketManager.runtimeType}');
      
      _webSocketManager.sendChatMessage(docId, text, locale: locale);
      debugPrint('[SendController] Message sent successfully: "$text"');
    } catch (e) {
      debugPrint('[SendController] Failed to send message: $e');
    }
  }

  /// Cancel any pending debounced message
  void cancelPending() {
    _debounceTimer?.cancel();
    _lastMessage = null;
    _lastSendTime = null;
    debugPrint('[SendController] Pending message cancelled');
  }

  /// Check if there's a pending message
  bool get hasPendingMessage => _debounceTimer?.isActive ?? false;

  /// Get the last message that was sent
  String? get lastMessage => _lastMessage;

  /// Dispose resources
  void dispose() {
    _debounceTimer?.cancel();
  }
}
