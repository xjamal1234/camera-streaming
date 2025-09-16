import 'package:flutter_bloc/flutter_bloc.dart';
import 'stream_ws_state.dart';

class StreamWsCubit extends Cubit<StreamWsState> {
  StreamWsCubit() : super(const InitialState());

  void setInitial() {
    emit(InitialState(
      targetFps: state.targetFps,
      guidanceDirection: state.guidanceDirection,
      guidanceMagnitude: state.guidanceMagnitude,
      coverage: state.coverage,
      confidence: state.confidence,
      readyForCapture: state.readyForCapture,
    ));
  }

  void setConnecting() {
    emit(ConnectingState(
      targetFps: state.targetFps,
      guidanceDirection: state.guidanceDirection,
      guidanceMagnitude: state.guidanceMagnitude,
      coverage: state.coverage,
      confidence: state.confidence,
      readyForCapture: state.readyForCapture,
    ));
  }

  void setStreaming() {
    emit(StreamingState(
      targetFps: state.targetFps,
      guidanceDirection: state.guidanceDirection,
      guidanceMagnitude: state.guidanceMagnitude,
      coverage: state.coverage,
      confidence: state.confidence,
      readyForCapture: state.readyForCapture,
    ));
  }

  void setFailure(String message) {
    emit(FailureState(
      message: message,
      targetFps: state.targetFps,
      guidanceDirection: state.guidanceDirection,
      guidanceMagnitude: state.guidanceMagnitude,
      coverage: state.coverage,
      confidence: state.confidence,
      readyForCapture: state.readyForCapture,
    ));
  }

  void setTargetFps(int fps) {
    final currentState = state;
    if (currentState is InitialState) {
      emit(InitialState(
        targetFps: fps,
        guidanceDirection: currentState.guidanceDirection,
        guidanceMagnitude: currentState.guidanceMagnitude,
        coverage: currentState.coverage,
        confidence: currentState.confidence,
        readyForCapture: currentState.readyForCapture,
      ));
    } else if (currentState is ConnectingState) {
      emit(ConnectingState(
        targetFps: fps,
        guidanceDirection: currentState.guidanceDirection,
        guidanceMagnitude: currentState.guidanceMagnitude,
        coverage: currentState.coverage,
        confidence: currentState.confidence,
        readyForCapture: currentState.readyForCapture,
      ));
    } else if (currentState is StreamingState) {
      emit(StreamingState(
        targetFps: fps,
        guidanceDirection: currentState.guidanceDirection,
        guidanceMagnitude: currentState.guidanceMagnitude,
        coverage: currentState.coverage,
        confidence: currentState.confidence,
        readyForCapture: currentState.readyForCapture,
      ));
    } else if (currentState is FrameUpdateState) {
      emit(FrameUpdateState(
        imageId: currentState.imageId,
        regions: currentState.regions,
        inferMs: currentState.inferMs,
        pipelineMs: currentState.pipelineMs,
        boxes: currentState.boxes,
        targetFps: fps,
        guidanceDirection: currentState.guidanceDirection,
        guidanceMagnitude: currentState.guidanceMagnitude,
        coverage: currentState.coverage,
        confidence: currentState.confidence,
        readyForCapture: currentState.readyForCapture,
      ));
    } else if (currentState is IntervalUpdateState) {
      emit(IntervalUpdateState(
        fps: currentState.fps,
        regionsPerSec: currentState.regionsPerSec,
        frames: currentState.frames,
        regions: currentState.regions,
        targetFps: fps,
        guidanceDirection: currentState.guidanceDirection,
        guidanceMagnitude: currentState.guidanceMagnitude,
        coverage: currentState.coverage,
        confidence: currentState.confidence,
        readyForCapture: currentState.readyForCapture,
      ));
    } else if (currentState is FailureState) {
      emit(FailureState(
        message: currentState.message,
        targetFps: fps,
        guidanceDirection: currentState.guidanceDirection,
        guidanceMagnitude: currentState.guidanceMagnitude,
        coverage: currentState.coverage,
        confidence: currentState.confidence,
        readyForCapture: currentState.readyForCapture,
      ));
    }
  }

  void updateFrame({
    required int imageId,
    required int regions,
    required int inferMs,
    int? pipelineMs,
    List<List<double>>? boxes,
  }) {
    emit(FrameUpdateState(
      imageId: imageId,
      regions: regions,
      inferMs: inferMs,
      pipelineMs: pipelineMs,
      boxes: boxes,
      targetFps: state.targetFps,
      guidanceDirection: state.guidanceDirection,
      guidanceMagnitude: state.guidanceMagnitude,
      coverage: state.coverage,
      confidence: state.confidence,
      readyForCapture: state.readyForCapture,
    ));
  }

  void updateInterval({
    required double fps,
    required double regionsPerSec,
    required int frames,
    required int regions,
  }) {
    emit(IntervalUpdateState(
      fps: fps,
      regionsPerSec: regionsPerSec,
      frames: frames,
      regions: regions,
      targetFps: state.targetFps,
      guidanceDirection: state.guidanceDirection,
      guidanceMagnitude: state.guidanceMagnitude,
      coverage: state.coverage,
      confidence: state.confidence,
      readyForCapture: state.readyForCapture,
    ));
  }

  void updateGuidance({
    required String direction,
    required double magnitude,
    required double coverage,
    required double confidence,
    required bool ready,
  }) {
    final currentState = state;
    if (currentState is InitialState) {
      emit(InitialState(
        targetFps: currentState.targetFps,
        guidanceDirection: direction,
        guidanceMagnitude: magnitude,
        coverage: coverage,
        confidence: confidence,
        readyForCapture: ready,
      ));
    } else if (currentState is ConnectingState) {
      emit(ConnectingState(
        targetFps: currentState.targetFps,
        guidanceDirection: direction,
        guidanceMagnitude: magnitude,
        coverage: coverage,
        confidence: confidence,
        readyForCapture: ready,
      ));
    } else if (currentState is StreamingState) {
      emit(StreamingState(
        targetFps: currentState.targetFps,
        guidanceDirection: direction,
        guidanceMagnitude: magnitude,
        coverage: coverage,
        confidence: confidence,
        readyForCapture: ready,
      ));
    } else if (currentState is FrameUpdateState) {
      emit(FrameUpdateState(
        imageId: currentState.imageId,
        regions: currentState.regions,
        inferMs: currentState.inferMs,
        pipelineMs: currentState.pipelineMs,
        boxes: currentState.boxes,
        targetFps: currentState.targetFps,
        guidanceDirection: direction,
        guidanceMagnitude: magnitude,
        coverage: coverage,
        confidence: confidence,
        readyForCapture: ready,
      ));
    } else if (currentState is IntervalUpdateState) {
      emit(IntervalUpdateState(
        fps: currentState.fps,
        regionsPerSec: currentState.regionsPerSec,
        frames: currentState.frames,
        regions: currentState.regions,
        targetFps: currentState.targetFps,
        guidanceDirection: direction,
        guidanceMagnitude: magnitude,
        coverage: coverage,
        confidence: confidence,
        readyForCapture: ready,
      ));
    } else if (currentState is FailureState) {
      emit(FailureState(
        message: currentState.message,
        targetFps: currentState.targetFps,
        guidanceDirection: direction,
        guidanceMagnitude: magnitude,
        coverage: coverage,
        confidence: confidence,
        readyForCapture: ready,
      ));
    }
  }
}
