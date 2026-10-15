import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _flutterTts = FlutterTts();

  Future<void> init() async {
    await _flutterTts.setLanguage('ko-KR');
    await _flutterTts.setSpeechRate(0.45);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
    await _flutterTts.awaitSpeakCompletion(true);
  }

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await _flutterTts.stop();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await _flutterTts.speak(text);
  }

  Future<void> stop() async {
    await _flutterTts.stop();
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
}