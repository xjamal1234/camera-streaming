import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

/// Manages chat session persistence using SharedPreferences
class SessionManager {
  static const String _keyLastDocId = 'chat_last_doc_id';
  static const String _keyLastMessage = 'chat_last_message';
  static const String _keyChatEnabled = 'chat_enabled_for_doc_id';
  static const String _keySessionToken = 'chat_session_token';

  /// Save the last active document ID
  static Future<void> saveLastDocId(String docId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyLastDocId, docId);
      debugPrint('[SessionManager] Saved last docId: $docId');
    } catch (e) {
      debugPrint('[SessionManager] Error saving last docId: $e');
    }
  }

  /// Get the last active document ID
  static Future<String?> getLastDocId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyLastDocId);
    } catch (e) {
      debugPrint('[SessionManager] Error getting last docId: $e');
      return null;
    }
  }

  /// Save the last user message
  static Future<void> saveLastMessage(String message) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyLastMessage, message);
      debugPrint('[SessionManager] Saved last message');
    } catch (e) {
      debugPrint('[SessionManager] Error saving last message: $e');
    }
  }

  /// Get the last user message
  static Future<String?> getLastMessage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyLastMessage);
    } catch (e) {
      debugPrint('[SessionManager] Error getting last message: $e');
      return null;
    }
  }

  /// Mark chat as enabled for a specific document ID
  static Future<void> setChatEnabled(String docId, bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_keyChatEnabled:$docId';
      await prefs.setBool(key, enabled);
      debugPrint('[SessionManager] Set chat enabled for $docId: $enabled');
    } catch (e) {
      debugPrint('[SessionManager] Error setting chat enabled: $e');
    }
  }

  /// Check if chat is enabled for a specific document ID
  static Future<bool> isChatEnabled(String docId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_keyChatEnabled:$docId';
      return prefs.getBool(key) ?? false;
    } catch (e) {
      debugPrint('[SessionManager] Error checking chat enabled: $e');
      return false;
    }
  }

  /// Save session token
  static Future<void> saveSessionToken(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keySessionToken, token);
      debugPrint('[SessionManager] Saved session token');
    } catch (e) {
      debugPrint('[SessionManager] Error saving session token: $e');
    }
  }

  /// Get session token
  static Future<String?> getSessionToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keySessionToken);
    } catch (e) {
      debugPrint('[SessionManager] Error getting session token: $e');
      return null;
    }
  }

  /// Clear all chat session data
  static Future<void> clearSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyLastDocId);
      await prefs.remove(_keyLastMessage);
      await prefs.remove(_keySessionToken);
      
      // Clear all chat enabled flags
      final keys = prefs.getKeys();
      for (final key in keys) {
        if (key.startsWith(_keyChatEnabled)) {
          await prefs.remove(key);
        }
      }
      
      debugPrint('[SessionManager] Cleared all session data');
    } catch (e) {
      debugPrint('[SessionManager] Error clearing session: $e');
    }
  }

  /// Get session summary for debugging
  static Future<Map<String, dynamic>> getSessionSummary() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastDocId = prefs.getString(_keyLastDocId);
      final lastMessage = prefs.getString(_keyLastMessage);
      final sessionToken = prefs.getString(_keySessionToken);
      
      // Get all chat enabled flags
      final keys = prefs.getKeys();
      final enabledDocs = <String>[];
      for (final key in keys) {
        if (key.startsWith(_keyChatEnabled) && (prefs.getBool(key) ?? false)) {
          final docId = key.substring(_keyChatEnabled.length + 1);
          enabledDocs.add(docId);
        }
      }
      
      return {
        'lastDocId': lastDocId,
        'lastMessage': lastMessage,
        'sessionToken': sessionToken,
        'enabledDocs': enabledDocs,
      };
    } catch (e) {
      debugPrint('[SessionManager] Error getting session summary: $e');
      return {};
    }
  }
}
