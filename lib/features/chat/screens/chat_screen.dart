import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../cubit/chat_cubit.dart';
import '../cubit/chat_state.dart';
import '../models/chat_message.dart';

/// Enhanced chat screen with robust WebSocket communication
/// 
/// Features:
/// - RTL support for Arabic text
/// - Message list with user/assistant bubbles
/// - Input field with send button and debouncing
/// - Connection status indicator with auto-reconnect
/// - Typing indicator
/// - Retry CTA for failed messages
/// - Status snackbars for connection events
/// - Auto-scroll to latest message
class ChatScreen extends StatefulWidget {
  final String docId;
  final dynamic webSocketManager; // Accept both WebSocketManager and WsServiceAdapter
  
  const ChatScreen({
    super.key,
    required this.docId,
    this.webSocketManager,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late ChatCubit _chatCubit;
  bool _showDebugOverlay = false;
  
  @override
  void initState() {
    super.initState();
    _chatCubit = ChatCubit(webSocketManager: widget.webSocketManager);
    _initializeChat();
  }

  /// Initialize chat with session token if available
  Future<void> _initializeChat() async {
    try {
      await _chatCubit.initialize(widget.docId);
    } catch (e) {
      debugPrint('[ChatScreen] Failed to initialize chat: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to initialize chat: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
  
  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _chatCubit.close();
    super.dispose();
  }
  
  /// Scroll to the bottom of the message list
  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 100), () {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      });
    }
  }
  
  /// Handle send button press
  void _handleSend() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    
    _chatCubit.sendMessage(text);
    _textController.clear();
    _scrollToBottom();
  }
  
  /// Show status message (concise snackbar)
  void _showStatusMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        backgroundColor: message.contains('انقطع') ? Colors.red : Colors.blue,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  /// Handle retry button press
  void _handleRetry() {
    final state = _chatCubit.state;
    if (state is ChatDisconnectedState) {
      _chatCubit.reconnect();
    } else {
      _chatCubit.retryLastMessage();
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _chatCubit,
      child: Directionality(
        textDirection: TextDirection.rtl, // RTL for Arabic
        child: Scaffold(
          appBar: AppBar(
            title: const Text('محادثة مع المساعد'),
            backgroundColor: Theme.of(context).colorScheme.inversePrimary,
            actions: [
              // Debug overlay toggle
              IconButton(
                onPressed: () {
                  setState(() {
                    _showDebugOverlay = !_showDebugOverlay;
                  });
                },
                icon: Icon(_showDebugOverlay ? Icons.visibility_off : Icons.visibility),
                tooltip: 'Toggle debug overlay',
              ),
              // Connection status button for debugging
              IconButton(
                onPressed: () {
                  _chatCubit.checkConnectionStatus();
                },
                icon: const Icon(Icons.network_check),
                tooltip: 'Check connection status',
              ),
              // Test button for debugging
              IconButton(
                onPressed: () {
                  _chatCubit.sendTestMessage();
                },
                icon: const Icon(Icons.bug_report),
                tooltip: 'Send test message',
              ),
              BlocBuilder<ChatCubit, ChatState>(
                builder: (context, state) {
                  return Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Center(
                      child: _buildConnectionStatus(state),
                    ),
                  );
                },
              ),
            ],
          ),
          body: Stack(
            children: [
              BlocListener<ChatCubit, ChatState>(
                listener: (context, state) {
                  // Show status messages
                  if (state is ChatReconnectingState) {
                    _showStatusMessage('أعدنا الاتصال…');
                  } else if (state is ChatReadyState && state.status == 'connected') {
                    // Check if this is a reconnection
                    if (state.messages.isNotEmpty) {
                      _showStatusMessage('تم الاتصال من جديد');
                    }
                  } else if (state is ChatDisconnectedState && state.error != null) {
                    _showStatusMessage('انقطع الاتصال. جرّب مجددًا.');
                  }

                  // Scroll to bottom when new message arrives
                  if (state.messages.isNotEmpty) {
                    _scrollToBottom();
                  }
                },
                child: Column(
                  children: [
                    // Message list
                    Expanded(
                      child: BlocBuilder<ChatCubit, ChatState>(
                        builder: (context, state) {
                          if (state.messages.isEmpty && !state.typing) {
                            return _buildEmptyState();
                          }

                          return ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.all(16),
                            itemCount: state.messages.length + (state.typing ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index < state.messages.length) {
                                final message = state.messages[index];
                                return _buildMessageBubble(message);
                              } else {
                                // Show typing indicator
                                return _buildTypingIndicator();
                              }
                            },
                          );
                        },
                      ),
                    ),

                    // Input area
                    _buildInputArea(),
                  ],
                ),
              ),

              // Debug overlay
              if (_showDebugOverlay) _buildDebugOverlay(),
            ],
          ),
        ),
      ),
    );
  }
  
  /// Build connection status indicator
  Widget _buildConnectionStatus(ChatState state) {
    if (state.isConnected) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.circle, color: Colors.green, size: 12),
          SizedBox(width: 4),
          Text('متصل', style: TextStyle(fontSize: 12)),
        ],
      );
    } else if (state is ChatReconnectingState) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 4),
          Text('جاري الاتصال...', style: TextStyle(fontSize: 12)),
        ],
      );
    } else {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.circle, color: Colors.red, size: 12),
          SizedBox(width: 4),
          Text('غير متصل', style: TextStyle(fontSize: 12)),
        ],
      );
    }
  }
  
  /// Build empty state when no messages
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            'ابدأ المحادثة',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'اطرح أسئلتك حول المستند',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[500],
            ),
          ),
        ],
      ),
    );
  }
  
  /// Build a message bubble
  Widget _buildMessageBubble(ChatMessage message) {
    final isUser = message.isUser;
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.start : MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) const Spacer(),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isUser
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey[200],
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.text,
                    style: TextStyle(
                      fontSize: 16,
                      color: isUser ? Colors.white : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatTime(message.timestamp),
                    style: TextStyle(
                      fontSize: 11,
                      color: isUser ? Colors.white70 : Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isUser) const Spacer(),
        ],
      ),
    );
  }
  
  /// Build input area with text field, send button, and retry CTA
  Widget _buildInputArea() {
    return BlocBuilder<ChatCubit, ChatState>(
      builder: (context, state) {
        final canSend = state.isConnected && 
                       state.docId != null && 
                       state is! ChatSendingState;
        
        final showRetryCTA = !state.isConnected && state.messages.isNotEmpty;
        
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Retry CTA banner
            if (showRetryCTA) _buildRetryBanner(),
            
            // Input area
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                boxShadow: [
                  BoxShadow(
                    offset: const Offset(0, -2),
                    blurRadius: 4,
                    color: Colors.black.withOpacity(0.1),
                  ),
                ],
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    // Send button
                    Semantics(
                      label: 'Send message',
                      button: true,
                      child: IconButton(
                        onPressed: canSend ? _handleSend : null,
                        icon: const Icon(Icons.send),
                        color: Theme.of(context).colorScheme.primary,
                        tooltip: 'إرسال رسالة',
                      ),
                    ),
                    
                    const SizedBox(width: 8),
                    
                    // Text input
                    Expanded(
                      child: Semantics(
                        label: 'Message input',
                        textField: true,
                        child: TextField(
                          controller: _textController,
                          enabled: canSend,
                          textDirection: TextDirection.rtl,
                          decoration: InputDecoration(
                            hintText: canSend ? 'اكتب رسالتك...' : 'جاري إعادة الاتصال...',
                            hintTextDirection: TextDirection.rtl,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                          ),
                          maxLines: null,
                          textInputAction: TextInputAction.send,
                          onSubmitted: canSend ? (_) => _handleSend() : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Build retry CTA banner
  Widget _buildRetryBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.orange.shade100,
      child: Row(
        children: [
          Icon(Icons.warning_amber, color: Colors.orange.shade700, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'انقطع الاتصال. جرّب مجددًا.',
              style: TextStyle(
                color: Colors.orange.shade700,
                fontSize: 12,
              ),
              textDirection: TextDirection.rtl,
            ),
          ),
          TextButton(
            onPressed: _handleRetry,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Retry',
              style: TextStyle(
                color: Colors.orange.shade700,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Build typing indicator
  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTypingDot(0),
                const SizedBox(width: 4),
                _buildTypingDot(1),
                const SizedBox(width: 4),
                _buildTypingDot(2),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build animated typing dot
  Widget _buildTypingDot(int index) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 600),
      builder: (context, value, child) {
        final delay = index * 200.0;
        final animationValue = (value * 1000 - delay).clamp(0.0, 600.0) / 600.0;
        final opacity = (animationValue * 2 - 1).abs();
        
        return Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: Colors.grey.shade600.withOpacity(opacity),
            shape: BoxShape.circle,
          ),
        );
      },
      onEnd: () {
        if (mounted) {
          setState(() {});
        }
      },
    );
  }
  
  /// Build debug overlay showing connection status
  Widget _buildDebugOverlay() {
    return Positioned(
      top: 10,
      right: 10,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.8),
          borderRadius: BorderRadius.circular(8),
        ),
        child: BlocBuilder<ChatCubit, ChatState>(
          builder: (context, state) {
            final connectionInfo = widget.webSocketManager?.connectionInfo ?? {};
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'DEBUG INFO',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'WS: ${state is ChatReadyState ? "Connected" : "Disconnected"}',
                  style: TextStyle(color: Colors.white, fontSize: 10),
                ),
                Text(
                  'Chat: ${state is ChatReadyState ? "Ready" : "Not Ready"}',
                  style: TextStyle(color: Colors.white, fontSize: 10),
                ),
                Text(
                  'DocId: ${state.docId ?? "None"}',
                  style: TextStyle(color: Colors.white, fontSize: 10),
                ),
                Text(
                  'Last HB: ${connectionInfo['lastHeartbeatAt'] ?? "Never"}',
                  style: TextStyle(color: Colors.white, fontSize: 10),
                ),
                Text(
                  'Status: ${state.status}',
                  style: TextStyle(color: Colors.white, fontSize: 10),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Format timestamp for display
  String _formatTime(DateTime timestamp) {
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

