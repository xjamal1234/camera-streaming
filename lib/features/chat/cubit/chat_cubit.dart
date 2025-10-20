import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../services/websocket_manager.dart';
import '../../../services/send_controller.dart';
import '../../../services/session_manager.dart';
import '../../../services/envelope_validator.dart';
import '../models/chat_message.dart';
import 'chat_state.dart';

/// Enhanced Cubit for managing chat state with robust WebSocket communication
/// 
/// Features:
/// - Auto-reconnect with exponential backoff
/// - Message debouncing and queuing
/// - Session persistence
/// - Typing indicators
/// - Retry mechanisms
class ChatCubit extends Cubit<ChatState> {
  late final dynamic _webSocketManager;
  late final SendController _sendController;
  StreamSubscription? _wsEventSubscription;
  StreamSubscription? _wsMessageSubscription;
  
  // Message history limit
  static const int _maxMessages = 200;
  
  ChatCubit({dynamic webSocketManager}) : super(const ChatInitialState()) {
    // Handle the case where webSocketManager is null
    if (webSocketManager == null) {
      _webSocketManager = WebSocketManager();
      _sendController = SendController(_webSocketManager);
    } else {
      _webSocketManager = webSocketManager;
      _sendController = SendController(webSocketManager);
    }
  }
  
  /// Initialize chat with a document ID and connect to WebSocket
  Future<void> initialize(String docId, {String? sessionToken}) async {
    debugPrint('[ChatCubit] Initializing with docId: $docId');
    
    // Set up WebSocket event listeners
    _wsEventSubscription = _webSocketManager.onEvent.listen(_handleWebSocketEvent);
    _wsMessageSubscription = _webSocketManager.onMessage.listen(_handleWebSocketMessage);
    
    // Save session data
    await SessionManager.saveLastDocId(docId);
    if (sessionToken != null) {
      await SessionManager.saveSessionToken(sessionToken);
    }
    
    // Connect to WebSocket
    await _connectToWebSocket(docId, sessionToken);
    
    emit(ChatReadyState(
      docId: docId,
      isConnected: _webSocketManager.isConnected,
      messages: [],
      status: _webSocketManager.statusName,
    ));
  }

  /// Connect to WebSocket with the given parameters
  Future<void> _connectToWebSocket(String docId, String? sessionToken) async {
    try {
      // Use the same URL as the main app
      const serverUrl = 'wss://c10d731adcf6.ngrok-free.app/ws/guidance';
      
      await _webSocketManager.connect(
        url: serverUrl,
        docId: docId,
        sessionToken: sessionToken,
      );
      
      debugPrint('[ChatCubit] WebSocket connection initiated');
    } catch (e) {
      debugPrint('[ChatCubit] Failed to connect WebSocket: $e');
      emit(ChatDisconnectedState(
        docId: docId,
        isConnected: false,
        messages: state.messages,
        error: 'Failed to connect: $e',
      ));
    }
  }
  
  /// Handle WebSocket events (connection status changes)
  void _handleWebSocketEvent(WebSocketEventData eventData) {
    debugPrint('[ChatCubit] WebSocket event: ${eventData.event}');
    
    switch (eventData.event) {
      case WebSocketEvent.open:
        _handleConnected();
        break;
      case WebSocketEvent.close:
        _handleDisconnected();
        break;
      case WebSocketEvent.reconnecting:
        _handleReconnecting();
        break;
      case WebSocketEvent.reconnected:
        _handleReconnected();
        break;
      case WebSocketEvent.error:
        _handleError(eventData.data);
        break;
      default:
        debugPrint('[ChatCubit] Unhandled WebSocket event: ${eventData.event}');
    }
  }

  /// Handle incoming WebSocket messages (chat messages)
  void _handleWebSocketMessage(Envelope envelope) {
    debugPrint('[ChatCubit] ===== MESSAGE RECEIVED =====');
    debugPrint('[ChatCubit] Type: ${envelope.type}');
    debugPrint('[ChatCubit] Data: ${envelope.data}');
    debugPrint('[ChatCubit] Data type: ${envelope.data.runtimeType}');
    debugPrint('[ChatCubit] Timestamp: ${DateTime.now().toIso8601String()}');
    
    // Validate envelope
    if (!EnvelopeValidator.isValid(envelope)) {
      debugPrint('[ChatCubit] Invalid envelope received, ignoring');
      return;
    }
    
    switch (envelope.type) {
      case 'chat_assistant':
        debugPrint('[ChatCubit] ✅ Processing chat_assistant message');
        _handleAssistantMessage(envelope);
        break;
      case 'system':
        debugPrint('[ChatCubit] Processing system message');
        _handleSystemMessage(envelope);
        break;
      case 'error':
        debugPrint('[ChatCubit] Processing error message');
        _handleErrorMessage(envelope);
        break;
      case 'hb':
        debugPrint('[ChatCubit] Heartbeat received - ignoring');
        break;
      default:
        debugPrint('[ChatCubit] Unhandled message type: ${envelope.type}');
    }
    debugPrint('[ChatCubit] ===== MESSAGE PROCESSED =====');
  }
  
  /// Handle assistant message from server
  void _handleAssistantMessage(Envelope envelope) {
    try {
      debugPrint('[ChatCubit] Parsing assistant message data: ${envelope.data}');
      final payload = ChatAssistantPayload.fromJson(envelope.data as Map<String, dynamic>);
      
      debugPrint('[ChatCubit] Assistant message received: ${payload.text}');
      debugPrint('[ChatCubit] Assistant message meta: ${payload.meta}');
      
      final assistantMessage = ChatMessage.assistant(
        text: payload.text,
        meta: payload.meta,
      );
      
      final updatedMessages = _addMessage(assistantMessage);
      
      debugPrint('[ChatCubit] Updated messages count: ${updatedMessages.length}');
      
      emit(ChatReadyState(
        docId: state.docId,
        isConnected: _webSocketManager.isConnected,
        messages: updatedMessages,
        status: _webSocketManager.statusName,
        typing: false, // Hide typing indicator
      ));
    } catch (e) {
      debugPrint('[ChatCubit] Error handling assistant message: $e');
      debugPrint('[ChatCubit] Envelope data type: ${envelope.data.runtimeType}');
    }
  }

  /// Handle system message
  void _handleSystemMessage(Envelope envelope) {
    try {
      final data = envelope.data as Map<String, dynamic>;
      final text = data['text'] as String? ?? 'System message';
      
      debugPrint('[ChatCubit] System message: $text');
      
      final systemMessage = ChatMessage.assistant(
        text: text,
        meta: {'type': 'system'},
      );
      
      final updatedMessages = _addMessage(systemMessage);
      
      emit(ChatReadyState(
        docId: state.docId,
        isConnected: _webSocketManager.isConnected,
        messages: updatedMessages,
        status: _webSocketManager.statusName,
        typing: false,
      ));
    } catch (e) {
      debugPrint('[ChatCubit] Error handling system message: $e');
    }
  }

  /// Handle error message
  void _handleErrorMessage(Envelope envelope) {
    try {
      final data = envelope.data as Map<String, dynamic>;
      final text = data['text'] as String? ?? 'Error occurred';
      
      debugPrint('[ChatCubit] Error message: $text');
      
      final errorMessage = ChatMessage.assistant(
        text: text,
        meta: {'type': 'error'},
      );
      
      final updatedMessages = _addMessage(errorMessage);
      
      emit(ChatReadyState(
        docId: state.docId,
        isConnected: _webSocketManager.isConnected,
        messages: updatedMessages,
        status: _webSocketManager.statusName,
        typing: false,
      ));
    } catch (e) {
      debugPrint('[ChatCubit] Error handling error message: $e');
    }
  }

  /// Add message to history with size limit
  List<ChatMessage> _addMessage(ChatMessage message) {
    final updatedMessages = List<ChatMessage>.from(state.messages)..add(message);
    
    // Limit message history
    if (updatedMessages.length > _maxMessages) {
      updatedMessages.removeRange(0, updatedMessages.length - _maxMessages);
    }
    
    return updatedMessages;
  }
  
  /// Handle WebSocket connected event
  void _handleConnected() {
    debugPrint('[ChatCubit] WebSocket connected');
    
    emit(ChatReadyState(
      docId: state.docId,
      isConnected: true,
      messages: state.messages,
      status: _webSocketManager.statusName,
      typing: state.typing,
    ));
  }
  
  /// Handle WebSocket disconnected event
  void _handleDisconnected() {
    debugPrint('[ChatCubit] WebSocket disconnected');
    
    emit(ChatDisconnectedState(
      docId: state.docId,
      isConnected: false,
      messages: state.messages,
      status: _webSocketManager.statusName,
    ));
  }
  
  /// Handle WebSocket reconnecting event
  void _handleReconnecting() {
    debugPrint('[ChatCubit] WebSocket reconnecting');
    
    emit(ChatReconnectingState(
      docId: state.docId,
      messages: state.messages,
      status: _webSocketManager.statusName,
    ));
  }

  /// Handle WebSocket reconnected event
  void _handleReconnected() {
    debugPrint('[ChatCubit] WebSocket reconnected');
    
    emit(ChatReadyState(
      docId: state.docId,
      isConnected: true,
      messages: state.messages,
      status: _webSocketManager.statusName,
      typing: state.typing,
    ));
  }
  
  /// Handle WebSocket error event
  void _handleError(dynamic error) {
    debugPrint('[ChatCubit] WebSocket error: $error');
    
    emit(ChatDisconnectedState(
      docId: state.docId,
      isConnected: false,
      messages: state.messages,
      status: _webSocketManager.statusName,
      error: error?.toString(),
    ));
  }
  
  /// Send a user message to the server with debouncing
  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) {
      debugPrint('[ChatCubit] Cannot send empty message');
      return;
    }
    
    final docId = state.docId;
    if (docId == null || docId.isEmpty) {
      debugPrint('[ChatCubit] Cannot send message: no docId');
      return;
    }
    
    debugPrint('[ChatCubit] ===== SENDING MESSAGE =====');
    debugPrint('[ChatCubit] Text: $text');
    debugPrint('[ChatCubit] Text preview: ${text.length > 64 ? text.substring(0, 64) + '...' : text}');
    debugPrint('[ChatCubit] WebSocket connected: ${_webSocketManager.isConnected}');
    debugPrint('[ChatCubit] WebSocket status: ${_webSocketManager.statusName}');
    debugPrint('[ChatCubit] DocId: $docId');
    debugPrint('[ChatCubit] WebSocketManager type: ${_webSocketManager.runtimeType}');
    debugPrint('[ChatCubit] Connection info: ${_webSocketManager.connectionInfo}');
    
    // Check if we can send the message
    if (!_webSocketManager.isConnected) {
      debugPrint('[ChatCubit] ERROR: WebSocket is not connected! Cannot send message.');
      debugPrint('[ChatCubit] Connection info: ${_webSocketManager.connectionInfo}');
      return;
    }
    
    // Add user message to list immediately
    final userMessage = ChatMessage.user(text: text.trim());
    final updatedMessages = _addMessage(userMessage);
    
    // Save last message for retry functionality
    await SessionManager.saveLastMessage(text.trim());
    
    // Show typing indicator
    emit(ChatSendingState(
      docId: docId,
      isConnected: _webSocketManager.isConnected,
      messages: updatedMessages,
      status: _webSocketManager.statusName,
      typing: true,
    ));
    
    // Send via SendController (handles debouncing)
    final wasSent = _sendController.sendMessage(
      docId: docId,
      text: text.trim(),
    );
    
    debugPrint('[ChatCubit] Message send result: $wasSent');
    
    if (!wasSent) {
      debugPrint('[ChatCubit] Message was debounced, sending immediately');
      // If debounced, send immediately
      _sendController.sendMessageImmediate(
        docId: docId,
        text: text.trim(),
      );
    }
    
    // Always return to ready state after sending
    emit(ChatReadyState(
      docId: docId,
      isConnected: _webSocketManager.isConnected,
      messages: updatedMessages,
      status: _webSocketManager.statusName,
      typing: false,
    ));
  }

  /// Retry sending the last message
  Future<void> retryLastMessage() async {
    final lastMessage = await SessionManager.getLastMessage();
    if (lastMessage != null && lastMessage.isNotEmpty) {
      debugPrint('[ChatCubit] Retrying last message: $lastMessage');
      await sendMessage(lastMessage);
    } else {
      debugPrint('[ChatCubit] No last message to retry');
    }
  }

  /// Reconnect to WebSocket
  Future<void> reconnect() async {
    final docId = state.docId;
    if (docId == null || docId.isEmpty) {
      debugPrint('[ChatCubit] Cannot reconnect: no docId');
      return;
    }
    
    debugPrint('[ChatCubit] Manual reconnect requested');
    
    final sessionToken = await SessionManager.getSessionToken();
    await _connectToWebSocket(docId, sessionToken);
  }

  /// Disconnect from WebSocket
  Future<void> disconnect() async {
    debugPrint('[ChatCubit] Disconnecting WebSocket');
    await _webSocketManager.disconnect();
  }

  /// Test method to send a simple message (for debugging)
  Future<void> sendTestMessage() async {
    final docId = state.docId ?? 'test123';
    debugPrint('[ChatCubit] Sending test message with docId: $docId');
    
    // Log connection status before sending
    debugPrint('[ChatCubit] Connection status before test: ${_webSocketManager.connectionInfo}');
    
    try {
      _webSocketManager.sendChatMessage(docId, 'كم عدد الفقرات؟');
      debugPrint('[ChatCubit] Test message sent successfully');
    } catch (e) {
      debugPrint('[ChatCubit] Error sending test message: $e');
    }
  }

  /// Check and log connection status
  void checkConnectionStatus() {
    debugPrint('[ChatCubit] ===== CONNECTION STATUS CHECK =====');
    debugPrint('[ChatCubit] Connection info: ${_webSocketManager.connectionInfo}');
    debugPrint('[ChatCubit] Current state: ${state.runtimeType}');
    debugPrint('[ChatCubit] DocId: ${state.docId}');
    debugPrint('[ChatCubit] ===== END STATUS CHECK =====');
  }
  
  /// Clear all messages
  void clearMessages() {
    debugPrint('[ChatCubit] Clearing messages');
    
    emit(ChatReadyState(
      docId: state.docId,
      isConnected: _webSocketManager.isConnected,
      messages: [],
      status: _webSocketManager.statusName,
      typing: false,
    ));
  }
  
  @override
  Future<void> close() {
    _wsEventSubscription?.cancel();
    _wsMessageSubscription?.cancel();
    _sendController.dispose();
    return super.close();
  }
}

