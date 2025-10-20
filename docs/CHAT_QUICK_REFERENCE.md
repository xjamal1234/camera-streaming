# Chat Feature - Quick Reference

## 🚀 Quick Start

### Endpoint
```dart
wss://c10d731adcf6.ngrok-free.app/ws/guidance
```

### Message Flow
```
Camera → Loading → (processing_completed) → Chat → Send/Receive Messages
```

---

## 📨 Message Protocol

### Client Sends (User Message)
```json
{
  "type": "chat_user",
  "data": {
    "docId": "0007",
    "text": "اقرأ الفقرة الأولى"
  }
}
```

### Server Sends (Readiness)
```json
{
  "type": "processing_completed",
  "data": {
    "docId": "0007",
    "gpt_ready": true,
    "scanned_color": "path/image.jpg"
  }
}
```

### Server Sends (Assistant Response)
```json
{
  "type": "chat_assistant",
  "data": {
    "text": "الفقرة 1: النص...",
    "meta": {
      "intent": "read_paragraph",
      "args": {"paragraph_index": 1}
    }
  }
}
```

---

## 📁 File Structure

```
lib/
├── services/
│   └── ws_service.dart               # WebSocket manager
├── features/chat/
│   ├── models/
│   │   └── chat_message.dart         # Message model
│   ├── cubit/
│   │   ├── chat_state.dart           # States
│   │   └── chat_cubit.dart           # Logic
│   └── screens/
│       └── chat_screen.dart          # UI
└── pages/
    └── stream_ws_page.dart           # Integration
```

---

## 🔧 Key Classes

### WsService
```dart
// Connect
await wsService.connectWs(url: serverUrl);

// Send
wsService.sendJson({'type': 'chat_user', 'data': {...}});

// Listen
wsService.onMessage.listen((message) { ... });

// Dispose
await wsService.dispose();
```

### ChatCubit
```dart
// Initialize
chatCubit.initialize(docId);

// Send message
await chatCubit.sendMessage(text);

// Listen to state
BlocBuilder<ChatCubit, ChatState>(...)
```

### ChatMessage
```dart
// Create user message
ChatMessage.user(text: "Hello");

// Create assistant message
ChatMessage.assistant(text: "Hi", meta: {...});
```

---

## 🎨 UI Components

### Connection Status
- 🟢 Green dot = Connected
- 🔴 Red dot = Disconnected
- ⏳ Spinner = Reconnecting

### Message Bubbles
- Right (Blue) = User
- Left (Gray) = Assistant

### Input State
- Enabled = Can send
- Disabled = Reconnecting/No docId

---

## ⚡ States

```dart
ChatInitialState       // Before init
ChatReadyState         // Normal active state
ChatSendingState       // Sending message
ChatReceivingState     // Receiving response
ChatDisconnectedState  // Connection lost
ChatReconnectingState  // Trying to reconnect
```

---

## 🛠️ Common Tasks

### Change Endpoint
```dart
// In stream_ws_page.dart
String serverUrl = 'wss://your-new-url/ws/guidance';
```

### Add Authentication
```dart
await _wsService.connectWs(
  url: serverUrl,
  token: 'YOUR_TOKEN',  // ?token=YOUR_TOKEN
);
```

### Adjust Reconnection
```dart
// In ws_service.dart
static const int _maxReconnectAttempts = 5;
static const Duration _reconnectDelay = Duration(seconds: 3);
```

### Change RTL Direction
```dart
// In chat_screen.dart
Directionality(
  textDirection: TextDirection.ltr,  // or rtl
  child: Scaffold(...)
)
```

---

## 🐛 Troubleshooting

| Issue | Solution |
|-------|----------|
| Chat doesn't open | Check `gpt_ready: true` and valid `docId` in server response |
| Can't send messages | Check connection status (green dot), verify docId is set |
| Reconnection fails | Verify server is running, check ngrok URL is valid |
| RTL not working | Ensure Directionality widget wraps Scaffold |
| Messages wrong order | Check timestamps, verify ListView.builder itemCount |

---

## 📊 Performance

- **Memory**: ~1-2MB for 100 messages
- **Network**: ~1-2KB per message
- **Battery**: Minimal (WebSocket keepalive)
- **Reconnect**: 3 seconds between attempts

---

## ✅ Checklist

- [ ] WsService connects on start
- [ ] Loading waits for processing_completed
- [ ] Chat opens with docId
- [ ] Can send/receive messages
- [ ] RTL works correctly
- [ ] Connection status updates
- [ ] Reconnection works
- [ ] Error handling works
- [ ] Back navigation works

---

## 📞 Support

See full documentation:
- `CHAT_FEATURE_DOCUMENTATION.md` - Complete technical docs
- `CHAT_IMPLEMENTATION_SUMMARY.md` - Implementation overview

