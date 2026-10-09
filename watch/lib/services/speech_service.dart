import 'dart:async';
import 'dart:convert';

import 'package:vosk_flutter/vosk_flutter.dart';

/// Which Vosk model to load. There is NO sub-50MB Tagalog model published by
/// Vosk (only `vosk-model-tl-ph-generic-0.6`, ~329MB), so the default is the
/// 41MB small English model, which still hears English keywords such as
/// "medic" / "rescue" / "roof". See README -> "Models" for swapping in Tagalog.
///   flutter run --dart-define=VOSK_MODEL=assets/models/vosk-model-tl-ph-generic-0.6.zip
const voskModelAsset = String.fromEnvironment(
  'VOSK_MODEL',
  defaultValue: 'assets/models/vosk-model-small-en-us-0.15.zip',
);

/// Thin wrapper over Vosk's mic pipeline: model load -> live partials -> text.
class OfflineSpeech {
  final _vosk = VoskFlutterPlugin.instance();
  SpeechService? _service;
  StreamSubscription<String>? _partialSub;
  StreamSubscription<String>? _resultSub;

  final _finals = <String>[];
  String _partial = '';

  /// Called with the full running transcript on every update.
  void Function(String transcript)? onTranscript;

  /// Loads the model and opens the recognizer. Slow on first run (the zip is
  /// unpacked to app storage), instant afterwards. Throws on failure.
  Future<void> init() async {
    final modelPath = await ModelLoader().loadFromAssets(voskModelAsset);
    final model = await _vosk.createModel(modelPath);
    final recognizer = await _vosk.createRecognizer(
      model: model,
      sampleRate: 16000,
    );
    _service = await _vosk.initSpeechService(recognizer);
  }

  bool get ready => _service != null;

  String get transcript =>
      [..._finals, if (_partial.isNotEmpty) _partial].join(' ').trim();

  Future<void> start() async {
    _finals.clear();
    _partial = '';
    _partialSub = _service!.onPartial().listen((s) {
      _partial = (jsonDecode(s)['partial'] as String? ?? '').trim();
      onTranscript?.call(transcript);
    });
    _resultSub = _service!.onResult().listen((s) {
      final text = (jsonDecode(s)['text'] as String? ?? '').trim();
      if (text.isNotEmpty) _finals.add(text);
      _partial = '';
      onTranscript?.call(transcript);
    });
    await _service!.start();
  }

  /// Stops the mic and returns the final transcript. Waits briefly so Vosk can
  /// flush its last utterance before we tear the listeners down.
  Future<String> stop() async {
    await _service!.stop();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _partialSub?.cancel();
    await _resultSub?.cancel();
    return transcript;
  }

  Future<void> dispose() async {
    await _partialSub?.cancel();
    await _resultSub?.cancel();
    await _service?.dispose();
  }
}
