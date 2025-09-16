# WS Camera Stream

A Flutter app that streams camera frames over WebSocket to a FastAPI server for real-time classification.

## Features

- Real-time camera preview using back camera
- Configurable FPS (1-15) with default of 6 FPS
- WebSocket streaming to FastAPI server
- Frame throttling to prevent backlog
- YUV to JPEG conversion in isolate for smooth UI
- Real-time display of classification results

## Setup

### Prerequisites

- Flutter SDK
- Android device with camera
- FastAPI server running on `ws://10.7.2.82:8000/process_realtime_classify/`

### Installation

1. Install dependencies:
   ```bash
   flutter pub get
   ```

2. Ensure Android device and laptop are on the same Wi-Fi network

3. Run the app:
   ```bash
   flutter run
   ```

## Usage

1. **Camera Preview**: The app shows a full-screen camera preview from the back camera
2. **Start Streaming**: Tap the "Start" button to connect to the WebSocket server and begin streaming frames
3. **Adjust FPS**: Use the slider to set target FPS (1-15, default 6)
4. **View Results**: 
   - "Last Frame" shows the most recent classification result
   - "Last Interval" shows the majority classification over the last interval
5. **Stop Streaming**: Tap "Stop" to disconnect from the server (camera preview continues)

## Technical Details

### Architecture
- Single StatefulWidget with all logic contained locally
- No BLoC/Cubit/Clean Architecture as requested
- Camera stream processing with throttling and queue management

### Performance Optimizations
- **Throttling**: Frames are throttled based on target FPS to prevent backlog
- **Queue Size 1**: Only the latest frame is kept to prioritize recency
- **Isolate Processing**: YUV to JPEG conversion runs in isolate to avoid UI blocking
- **Busy Gate**: Prevents overlapping frame processing

### WebSocket Protocol
- **Client → Server**: Raw JPEG bytes (not JSON/Base64)
- **Server → Client**: JSON messages:
  - `{"status":"frame", "frame_number":N, "class_id":i, "class_name":"..."}`
  - `{"status":"interval", "interval_number":k, "duration_seconds":5, "most_common_class_id":j, "most_common_class_name":"...", "total_frames":m}`

### Android Permissions
- `android.permission.CAMERA` - Camera access
- `android.permission.INTERNET` - WebSocket communication

## Troubleshooting

- **Camera not working**: Ensure camera permissions are granted
- **WebSocket connection failed**: Check that device and server are on same network
- **Poor performance**: Reduce target FPS or check server processing speed
- **Memory issues**: App uses queue size 1 to minimize memory usage

## Dependencies

- `camera: ^0.11.0+2` - Camera functionality
- `web_socket_channel: ^2.4.0` - WebSocket communication  
- `image: ^4.1.7` - Image processing for JPEG conversion
