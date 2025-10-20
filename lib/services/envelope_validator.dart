import 'package:flutter/foundation.dart';
import 'websocket_manager.dart';

/// Validates envelope messages for type safety and required fields
class EnvelopeValidator {
  /// Validate a chat user envelope
  static bool isValidChatUser(Envelope envelope) {
    if (envelope.type != 'chat_user') {
      debugPrint('[EnvelopeValidator] Invalid type for chat_user: ${envelope.type}');
      return false;
    }

    try {
      final data = envelope.data as Map<String, dynamic>;
      
      // Check required fields
      if (!data.containsKey('docId') || data['docId'] is! String) {
        debugPrint('[EnvelopeValidator] Missing or invalid docId');
        return false;
      }
      
      if (!data.containsKey('text') || data['text'] is! String) {
        debugPrint('[EnvelopeValidator] Missing or invalid text');
        return false;
      }
      
      // Validate docId is not empty
      if ((data['docId'] as String).trim().isEmpty) {
        debugPrint('[EnvelopeValidator] Empty docId');
        return false;
      }
      
      // Validate text is not empty
      if ((data['text'] as String).trim().isEmpty) {
        debugPrint('[EnvelopeValidator] Empty text');
        return false;
      }
      
      // Validate locale if present
      if (data.containsKey('locale') && data['locale'] is! String) {
        debugPrint('[EnvelopeValidator] Invalid locale type');
        return false;
      }
      
      return true;
    } catch (e) {
      debugPrint('[EnvelopeValidator] Error validating chat_user envelope: $e');
      return false;
    }
  }

  /// Validate a chat assistant envelope
  static bool isValidChatAssistant(Envelope envelope) {
    if (envelope.type != 'chat_assistant') {
      debugPrint('[EnvelopeValidator] Invalid type for chat_assistant: ${envelope.type}');
      return false;
    }

    try {
      final data = envelope.data as Map<String, dynamic>;
      
      // Check required fields
      if (!data.containsKey('text') || data['text'] is! String) {
        debugPrint('[EnvelopeValidator] Missing or invalid text');
        return false;
      }
      
      // Validate text is not empty
      if ((data['text'] as String).trim().isEmpty) {
        debugPrint('[EnvelopeValidator] Empty text');
        return false;
      }
      
      // Validate meta if present
      if (data.containsKey('meta') && data['meta'] is! Map<String, dynamic>) {
        debugPrint('[EnvelopeValidator] Invalid meta type');
        return false;
      }
      
      return true;
    } catch (e) {
      debugPrint('[EnvelopeValidator] Error validating chat_assistant envelope: $e');
      return false;
    }
  }

  /// Validate any envelope
  static bool isValid(Envelope envelope) {
    switch (envelope.type) {
      case 'chat_user':
        return isValidChatUser(envelope);
      case 'chat_assistant':
        return isValidChatAssistant(envelope);
      case 'system':
      case 'error':
      case 'hb':  // Heartbeat messages
      case 'processing_completed':
      case 'guidance':
      case 'final_frame_captured':
        // System, error, and other server messages are always valid
        return true;
      default:
        debugPrint('[EnvelopeValidator] Unknown envelope type: ${envelope.type} - allowing through');
        return true; // Allow unknown types through for debugging
    }
  }

  /// Safely parse and validate an envelope from JSON
  static Envelope? parseAndValidate(Map<String, dynamic> json) {
    try {
      final envelope = Envelope.fromJson(json);
      
      if (isValid(envelope)) {
        return envelope;
      } else {
        debugPrint('[EnvelopeValidator] Invalid envelope: $json');
        return null;
      }
    } catch (e) {
      debugPrint('[EnvelopeValidator] Error parsing envelope: $e');
      return null;
    }
  }
}
