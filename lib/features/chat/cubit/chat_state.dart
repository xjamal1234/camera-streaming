import 'package:flutter/foundation.dart';
import '../models/chat_message.dart';

/// Base state for chat feature
@immutable
abstract class ChatState {
  final String? docId;
  final bool isConnected;
  final List<ChatMessage> messages;
  final String? status;
  final bool typing;
  
  const ChatState({
    this.docId,
    this.isConnected = false,
    this.messages = const [],
    this.status,
    this.typing = false,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ChatState &&
        other.docId == docId &&
        other.isConnected == isConnected &&
        listEquals(other.messages, messages) &&
        other.status == status &&
        other.typing == typing;
  }

  @override
  int get hashCode => Object.hash(docId, isConnected, messages, status, typing);
}

/// Initial state before chat begins
class ChatInitialState extends ChatState {
  const ChatInitialState({
    super.docId,
    super.isConnected,
    super.messages,
    super.status,
    super.typing,
  });
}

/// State when chat is ready and active
class ChatReadyState extends ChatState {
  const ChatReadyState({
    required super.docId,
    required super.isConnected,
    required super.messages,
    super.status,
    super.typing,
  });
}

/// State when sending a message
class ChatSendingState extends ChatState {
  const ChatSendingState({
    required super.docId,
    required super.isConnected,
    required super.messages,
    super.status,
    super.typing,
  });
}

/// State when receiving a message
class ChatReceivingState extends ChatState {
  const ChatReceivingState({
    required super.docId,
    required super.isConnected,
    required super.messages,
    super.status,
    super.typing,
  });
}

/// State when connection is lost
class ChatDisconnectedState extends ChatState {
  final String? error;
  
  const ChatDisconnectedState({
    required super.docId,
    super.isConnected = false,
    required super.messages,
    super.status,
    super.typing,
    this.error,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ChatDisconnectedState &&
        super == other &&
        other.error == error;
  }

  @override
  int get hashCode => Object.hash(super.hashCode, error);
}

/// State when reconnecting
class ChatReconnectingState extends ChatState {
  const ChatReconnectingState({
    required super.docId,
    super.isConnected = false,
    required super.messages,
    super.status,
    super.typing,
  });
}

