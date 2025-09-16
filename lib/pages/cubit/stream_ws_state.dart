import 'package:flutter_bloc/flutter_bloc.dart';

abstract class StreamWsState {
  final int targetFps;
  final String? guidanceDirection;
  final double guidanceMagnitude;
  final double coverage;
  final double confidence;
  final bool readyForCapture;
  
  const StreamWsState({
    this.targetFps = 6,
    this.guidanceDirection,
    this.guidanceMagnitude = 0.0,
    this.coverage = 0.0,
    this.confidence = 0.0,
    this.readyForCapture = false,
  });
}

class InitialState extends StreamWsState {
  const InitialState({
    super.targetFps,
    super.guidanceDirection,
    super.guidanceMagnitude,
    super.coverage,
    super.confidence,
    super.readyForCapture,
  });
}

class ConnectingState extends StreamWsState {
  const ConnectingState({
    super.targetFps,
    super.guidanceDirection,
    super.guidanceMagnitude,
    super.coverage,
    super.confidence,
    super.readyForCapture,
  });
}

class StreamingState extends StreamWsState {
  const StreamingState({
    super.targetFps,
    super.guidanceDirection,
    super.guidanceMagnitude,
    super.coverage,
    super.confidence,
    super.readyForCapture,
  });
}

class FrameUpdateState extends StreamWsState {
  final int imageId;
  final int regions;
  final int inferMs;
  final int? pipelineMs;
  final List<List<double>>? boxes;
  
  const FrameUpdateState({
    required this.imageId,
    required this.regions,
    required this.inferMs,
    this.pipelineMs,
    this.boxes,
    super.targetFps,
    super.guidanceDirection,
    super.guidanceMagnitude,
    super.coverage,
    super.confidence,
    super.readyForCapture,
  });
}

class IntervalUpdateState extends StreamWsState {
  final double fps;
  final double regionsPerSec;
  final int frames;
  final int regions;
  
  const IntervalUpdateState({
    required this.fps,
    required this.regionsPerSec,
    required this.frames,
    required this.regions,
    super.targetFps,
    super.guidanceDirection,
    super.guidanceMagnitude,
    super.coverage,
    super.confidence,
    super.readyForCapture,
  });
}

class FailureState extends StreamWsState {
  final String message;
  
  const FailureState({
    required this.message,
    super.targetFps,
    super.guidanceDirection,
    super.guidanceMagnitude,
    super.coverage,
    super.confidence,
    super.readyForCapture,
  });
}
