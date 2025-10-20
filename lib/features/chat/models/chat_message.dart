/// Represents a single chat message in the conversation
/// 
/// Can be either from the user or from the assistant (GPT)
class ChatMessage {
  /// Unique identifier for the message
  final String id;
  
  /// Role of the message sender: "user" or "assistant"
  final String role;
  
  /// Text content of the message
  final String text;
  
  /// Timestamp when the message was created
  final DateTime timestamp;
  
  /// Optional metadata for assistant messages
  /// Contains intent, args, etc. from the server
  final Map<String, dynamic>? meta;
  
  ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.timestamp,
    this.meta,
  });
  
  /// Create a user message
  factory ChatMessage.user({
    required String text,
    String? id,
  }) {
    return ChatMessage(
      id: id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'user',
      text: text,
      timestamp: DateTime.now(),
    );
  }
  
  /// Create an assistant message
  factory ChatMessage.assistant({
    required String text,
    Map<String, dynamic>? meta,
    String? id,
  }) {
    return ChatMessage(
      id: id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'assistant',
      text: text,
      timestamp: DateTime.now(),
      meta: meta,
    );
  }
  
  /// Check if this is a user message
  bool get isUser => role == 'user';
  
  /// Check if this is an assistant message
  bool get isAssistant => role == 'assistant';
  
  /// Convert to JSON for persistence or logging
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'role': role,
      'text': text,
      'timestamp': timestamp.toIso8601String(),
      if (meta != null) 'meta': meta,
    };
  }
  
  /// Create from JSON
  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      role: json['role'] as String,
      text: json['text'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      meta: json['meta'] as Map<String, dynamic>?,
    );
  }
  
  @override
  String toString() {
    return 'ChatMessage(id: $id, role: $role, text: ${text.substring(0, text.length > 50 ? 50 : text.length)}...)';
  }
}

