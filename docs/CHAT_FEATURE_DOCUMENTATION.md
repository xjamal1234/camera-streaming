# Chat Feature Documentation

## Overview
This document provides a complete guide to the chat feature implementation in the NOOR Flutter mobile app. The chat feature allows users to converse with an AI assistant about their scanned documents after the scanning and processing phase.

---

## Architecture Overview

### Flow Diagram
```
Camera/Guidance → Loading (waiting for processing_completed) → Chat Screen
                                    ↓
                             (gpt_ready: true, docId)
```

### Components

1. **WsService** (`lib/services/ws_service.dart`)
   - Shared WebSocket service
   - Handles connection, reconnection, and message routing
   - Used by both Loading and Chat screens

2. **ChatMessage Model** (`lib/features/chat/models/chat_message.dart`)
   - Data model for messages
   - Supports user and assistant roles

3. **ChatCubit** (`lib/features/chat/cubit/chat_cubit.dart`)
   - State management for chat
   - Handles sending/receiving messages

4. **ChatScreen** (`lib/features/chat/screens/chat_screen.dart`)
   - UI for chat interface
   - RTL support for Arabic

---

## Implementation Details

### 1. WebSocket Service (`ws_service.dart`)

**Purpose**: Provide a reusable WebSocket connection that can be shared across screens.

**Key Methods**:

```dart
// Connect to WebSocket server
Future<void> connectWs({required String url, String? token})

// Send JSON message
void sendJson(Map<String, dynamic> message)

// Stream of incoming messages
Stream<Map<String, dynamic>> get onMessage

// Dispose and cleanup
Future<void> dispose()
```

**Features**:
- **Auto-reconnection**: Automatically attempts to reconnect on connection loss
- **Max reconnect attempts**: 5 attempts with 3-second delays
- **Broadcast stream**: Multiple listeners can subscribe to messages
- **Connection status**: Emits `_ws_connected`, `_ws_disconnected`, `_ws_reconnecting` events
- **Error handling**: Emits `_ws_error` events

**Message Format**:
All messages follow this envelope format:
```json
{
  "type": "message_type",
  "data": { ... }
}
```

**Internal Events**:
The service emits special events for connection management:
- `_ws_connected`: Connection established
- `_ws_disconnected`: Connection closed
- `_ws_reconnecting`: Attempting to reconnect
- `_ws_error`: Error occurred
- `_ws_max_reconnect`: Max reconnection attempts reached

---

### 2. Chat Message Model (`chat_message.dart`)

**Purpose**: Represent individual chat messages in the conversation.

**Properties**:
```dart
class ChatMessage {
  final String id;              // Unique message ID
  final String role;            // "user" or "assistant"
  final String text;            // Message content
  final DateTime timestamp;     // When message was sent
  final Map<String, dynamic>? meta;  // Optional metadata from server
}
```

**Factory Constructors**:
```dart
// Create user message
ChatMessage.user({required String text, String? id})

// Create assistant message
ChatMessage.assistant({required String text, Map<String, dynamic>? meta, String? id})
```

**Helper Methods**:
```dart
bool get isUser      // Check if message is from user
bool get isAssistant // Check if message is from assistant
Map<String, dynamic> toJson()  // Convert to JSON
factory ChatMessage.fromJson() // Create from JSON
```

---

### 3. Chat State Management (`chat_cubit.dart` & `chat_state.dart`)

**States**:

1. **ChatInitialState**: Before chat initialization
2. **ChatReadyState**: Chat is ready, connected, and active
3. **ChatSendingState**: Currently sending a message
4. **ChatReceivingState**: Currently receiving a message
5. **ChatDisconnectedState**: Connection lost
6. **ChatReconnectingState**: Attempting to reconnect

**ChatCubit Methods**:

```dart
// Initialize chat with document ID
void initialize(String docId)

// Send user message to server
Future<void> sendMessage(String text)

// Clear all messages
void clearMessages()
```

**Message Handling**:

The cubit listens to WsService messages and handles:
- `chat_assistant`: Assistant response from server
- `_ws_connected`: Connection established
- `_ws_disconnected`: Connection lost
- `_ws_reconnecting`: Reconnection in progress
- `_ws_error`: Error occurred

---

### 4. Chat Screen UI (`chat_screen.dart`)

**Purpose**: Provide the user interface for chatting with the AI assistant.

**Features**:

1. **RTL Support**: 
   - Full right-to-left layout for Arabic
   - Auto-directional text based on content

2. **Message List**:
   - Scrollable list of messages
   - User messages (right side, blue)
   - Assistant messages (left side, gray)
   - Timestamps

3. **Input Area**:
   - Text field for typing messages
   - Send button (disabled when not connected or no docId)
   - Submit on enter key

4. **Connection Status**:
   - Green dot: Connected
   - Red dot: Disconnected
   - Spinner: Reconnecting

5. **Empty State**:
   - Friendly message when no messages yet
   - Encourages user to start conversation

**UI Components**:

```dart
// Connection status indicator
Widget _buildConnectionStatus(ChatState state)

// Empty state when no messages
Widget _buildEmptyState()

// Individual message bubble
Widget _buildMessageBubble(ChatMessage message)

// Input area with text field and send button
Widget _buildInputArea()
```

**Accessibility**:
- Send button: "Send message" label
- Text field: "Message input" label
- Screen reader announcements for assistant messages

---

### 5. Integration with Existing Code (`stream_ws_page.dart`)

**Changes Made**:

1. **Added WsService Instance**:
```dart
final WsService _wsService = WsService();
StreamSubscription? _wsServiceSubscription;
```

2. **Connected WsService on Start**:
```dart
// In _startStreaming()
await _wsService.connectWs(url: serverUrl);
```

3. **Added Message Listener**:
```dart
// In initState()
_wsServiceSubscription = _wsService.onMessage.listen(_handleWsServiceMessage);
```

4. **Handle processing_completed**:
```dart
void _handleWsServiceMessage(Map<String, dynamic> message) {
  if (type == 'processing_completed' && data != null) {
    final gptReady = data['gpt_ready'] as bool? ?? false;
    final docId = data['docId'] as String?;
    
    if (gptReady && docId != null) {
      Navigator.push(...ChatScreen(docId: docId, wsService: _wsService));
    }
  }
}
```

5. **Cleanup on Dispose**:
```dart
_wsServiceSubscription?.cancel();
_wsService.dispose();
```

---

## Message Protocol

### Server → Client Messages

#### 1. Processing Completed (Readiness Signal)
```json
{
  "type": "processing_completed",
  "data": {
    "docId": "0007",
    "gpt_ready": true,
    "scanned_color": "path/to/image.jpg"
  }
}
```

**Triggers**: Navigation from Loading to Chat screen

#### 2. Assistant Response
```json
{
  "type": "chat_assistant",
  "data": {
    "text": "الفقرة 1: ...",
    "meta": {
      "intent": "read_paragraph",
      "args": {
        "paragraph_index": 1
      }
    }
  }
}
```

**Triggers**: New assistant message added to chat

### Client → Server Messages

#### User Message
```json
{
  "type": "chat_user",
  "data": {
    "docId": "0007",
    "text": "اقرأ الفقرة الأولى"
  }
}
```

**Sent**: When user submits a message

---

## User Flow

### Step 1: Camera & Guidance
User captures document with camera guidance system (existing feature).

### Step 2: Loading Screen
After perfect frame is captured:
1. Loading overlay appears
2. Camera stream stops
3. WebSocket stays connected
4. App waits for `processing_completed` message

### Step 3: Processing Completed
Server sends:
```json
{
  "type": "processing_completed",
  "data": {
    "docId": "0007",
    "gpt_ready": true
  }
}
```

### Step 4: Navigate to Chat
If `gpt_ready: true`:
1. Cancel loading timeout
2. Navigate to ChatScreen
3. Pass docId and wsService

If `gpt_ready: false`:
1. Stay on Loading screen
2. Keep listening for updates

### Step 5: Chat Screen
1. Initialize chat with docId
2. User can send messages
3. Assistant responds with answers
4. Connection status shown at top
5. Auto-reconnect if disconnected

### Step 6: Back Navigation
When user presses back from chat:
1. Return to initial/home screen (not Loading)
2. Reset state
3. Ready for new scan

---

## Error Handling

### Connection Errors

1. **Initial Connection Failure**:
   - Shows error toast
   - Auto-reconnect after 3 seconds
   - Max 5 attempts

2. **Mid-Chat Disconnection**:
   - Shows "Reconnecting..." status
   - Toast notification
   - Input disabled during reconnect
   - Attempts auto-reconnect

3. **Max Reconnect Attempts Reached**:
   - Shows "Max reconnection attempts reached"
   - Input permanently disabled
   - User can go back and restart

### Message Errors

1. **Empty Message**:
   - Send button does nothing
   - No error shown

2. **Send During Disconnect**:
   - Toast: "جاري إعادة الاتصال..."
   - Message stays in input
   - Not queued (user can retry)

3. **No docId**:
   - Send button disabled
   - Cannot send messages

### Server Errors

1. **"Processing..." Response**:
   - Treated as normal assistant message
   - Shows in chat as assistant bubble

2. **Malformed Messages**:
   - Logged to console
   - Ignored (doesn't crash app)

---

## Testing Checklist

### Connection Tests
- [ ] WsService connects on streaming start
- [ ] WsService reconnects after disconnect
- [ ] Max reconnect attempts limit works
- [ ] Connection status updates correctly

### Navigation Tests
- [ ] Loading waits for processing_completed
- [ ] Chat opens when gpt_ready=true
- [ ] Chat does not open when gpt_ready=false
- [ ] Back from chat returns to home

### Chat Functionality
- [ ] Can send user messages
- [ ] Receives assistant messages
- [ ] Messages display correctly (RTL)
- [ ] Timestamps show correctly
- [ ] Empty state shows when no messages
- [ ] Send button disabled when disconnected
- [ ] Auto-scroll to latest message

### Error Scenarios
- [ ] Handles reconnection gracefully
- [ ] Shows toast on reconnect
- [ ] Prevents send during disconnect
- [ ] Handles malformed messages
- [ ] Doesn't crash on errors

---

## Code Structure

```
lib/
├── services/
│   └── ws_service.dart              # Shared WebSocket service
├── features/
│   └── chat/
│       ├── models/
│       │   └── chat_message.dart    # Message data model
│       ├── cubit/
│       │   ├── chat_state.dart      # Chat states
│       │   └── chat_cubit.dart      # State management
│       └── screens/
│           └── chat_screen.dart     # Chat UI
└── pages/
    └── stream_ws_page.dart          # Updated with chat integration
```

---

## Configuration

### WebSocket Endpoint
```dart
String serverUrl = 'wss://c10d731adcf6.ngrok-free.app/ws/guidance';
```

### Authentication
Currently no token required. If needed in future:
```dart
await _wsService.connectWs(
  url: serverUrl,
  token: 'YOUR_TOKEN_HERE',
);
```

### Reconnection Settings
```dart
static const int _maxReconnectAttempts = 5;
static const Duration _reconnectDelay = Duration(seconds: 3);
```

### RTL Configuration
```dart
// In ChatScreen
Directionality(
  textDirection: TextDirection.rtl,
  child: Scaffold(...)
)
```

---

## Future Enhancements

### Potential Improvements
1. **Message Persistence**: Save chat history to local storage
2. **Voice Input**: Add speech-to-text for Arabic
3. **Message Search**: Search through conversation history
4. **Export Chat**: Export conversation as PDF/text
5. **Rich Messages**: Support images, links in messages
6. **Typing Indicator**: Show when assistant is "typing"
7. **Message Reactions**: Like/dislike assistant responses
8. **Multi-Document**: Support multiple document conversations

### Known Limitations
1. No message queuing during disconnect
2. No offline mode
3. No message edit/delete
4. No conversation context preservation on app restart

---

## Troubleshooting

### Issue: Chat screen doesn't appear
**Solution**: Check that server sends `processing_completed` with `gpt_ready: true` and valid `docId`

### Issue: Messages not sending
**Solution**: Check WebSocket connection status (green dot). Verify docId is set correctly.

### Issue: Reconnection failing
**Solution**: Check server is running and ngrok URL is valid. Restart app if needed.

### Issue: RTL layout not working
**Solution**: Ensure device language settings support RTL. Check Directionality widget is wrapping Scaffold.

### Issue: Messages display order wrong
**Solution**: Verify timestamps are correct. Check ListView.builder itemCount.

---

## Performance Considerations

### Memory Management
- Messages list can grow large
- Consider limiting to last 100 messages
- Implement pagination if needed

### Network Usage
- WebSocket kept alive during chat
- Each message ~1-2KB
- Heartbeats minimal overhead

### Battery Impact
- Active WebSocket connection
- Reconnection attempts consume battery
- Consider timeout for inactive chats

---

## Accessibility

### Screen Reader Support
- Send button labeled "Send message"
- Input field labeled "Message input"
- Connection status announced
- Message bubbles announced

### Keyboard Navigation
- Text field accessible via keyboard
- Send on Enter key
- Tab navigation supported

### Visual Accessibility
- High contrast message bubbles
- Clear connection status indicators
- Readable font sizes (16px messages)
- Proper spacing between messages

---

## Maintenance

### Regular Checks
1. Monitor WebSocket connection stability
2. Review error logs for patterns
3. Check message delivery success rate
4. Monitor reconnection attempt frequency

### Updates Needed When
1. Server protocol changes
2. New message types added
3. Authentication requirements change
4. UI/UX improvements needed

---

## Summary

The chat feature provides a seamless conversation interface for users to interact with the AI assistant about their scanned documents. It integrates with the existing guidance/scanning flow, maintains a shared WebSocket connection, handles errors gracefully, and provides full RTL support for Arabic users.

The implementation follows clean architecture principles, uses Cubit for state management, and maintains separation of concerns across services, models, and UI components.

