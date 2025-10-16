// lib/services/ai_summary_service.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../constants.dart';

class AISummaryResult {
  final String text;
  final String? filePath;
  final String? fileUrl;
  AISummaryResult({required this.text, this.filePath, this.fileUrl});
}

class AISummaryService {
  final String _apiKey;

  final String _preferredModel;

  AISummaryService({
    String? apiKey,
    String preferredModel = 'gemini-2.5-flash',
  })  : _apiKey = apiKey ?? googleAIKey,
        _preferredModel = preferredModel;

  SupabaseClient get _sb => Supabase.instance.client;

  Future<AISummaryResult> fetchOrCreateSummary({
    required String postId,
    required String pdfUrl,
    String? prompt,
  }) async {
    // 1) Cache existente
    final cached = await _sb
        .from('summaries')
        .select('summary, file_path')
        .eq('post_id', postId)
        .limit(1)
        .maybeSingle();

    if (cached != null && cached['summary'] is String) {
      final text = cached['summary'] as String;
      final filePath = cached['file_path'] as String?;
      final url = (filePath != null && filePath.isNotEmpty)
          ? _sb.storage.from(storageBucket).getPublicUrl(filePath)
          : null;
      return AISummaryResult(text: text, filePath: filePath, fileUrl: url);
    }

    // 2) Descarga PDF
    final res = await http.get(Uri.parse(pdfUrl));
    if (res.statusCode != 200) {
      throw StateError('No se pudo descargar el PDF (HTTP ${res.statusCode})');
    }
    final pdfBytes = Uint8List.fromList(res.bodyBytes);

    // 3) Resume con Gemini
    final summaryText = await _summarizeWithGemini(pdfBytes, prompt: prompt);

    // 4) Guarda archivo en Storage como Markdown
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) throw StateError('No autenticado');

    final filePath = '$uid/summaries/$postId.md';
    final bytes = Uint8List.fromList(utf8.encode(summaryText));
    await _sb.storage.from(storageBucket).uploadBinary(
          filePath,
          bytes,
          fileOptions: const FileOptions(
            cacheControl: '300',
            upsert: true,
            contentType: 'text/markdown; charset=utf-8',
          ),
        );
    final fileUrl = _sb.storage.from(storageBucket).getPublicUrl(filePath);

    // 5) Inserta en DB (maneja carrera por unique(post_id))
    try {
      await _sb.from('summaries').insert({
        'post_id': postId,
        'user_id': uid,
        'model': _preferredModel,
        'summary': summaryText,
        'file_path': filePath,
      });
    } catch (_) {
      // Si otro lo insertó antes, lee el existente
      final again = await _sb
          .from('summaries')
          .select('summary, file_path')
          .eq('post_id', postId)
          .limit(1)
          .maybeSingle();
      if (again != null && again['summary'] is String) {
        final t = again['summary'] as String;
        final p = again['file_path'] as String?;
        final u = (p != null && p.isNotEmpty)
            ? _sb.storage.from(storageBucket).getPublicUrl(p)
            : null;
        return AISummaryResult(text: t, filePath: p, fileUrl: u);
      }
      rethrow;
    }

    return AISummaryResult(
        text: summaryText, filePath: filePath, fileUrl: fileUrl);
  }

  Future<String> _summarizeWithGemini(
    Uint8List pdfBytes, {
    String? prompt,
  }) async {
    if (_apiKey.isEmpty) {
      throw StateError('Falta googleAIKey en constants.dart');
    }

    final candidates = <String>[
      _preferredModel,
      'gemini-2.5-pro',
      'gemini-2.5-flash-latest',
      'gemini-2.5-pro-latest',
      'gemini-2.0-flash',
      'gemini-2.0-pro',
      'gemini-1.5-flash-latest',
      'gemini-1.5-pro-latest',
    ];

    final systemPrompt = prompt ??
        'Eres un asistente que resume documentos PDF en español. '
            'Devuelve un resumen claro, con viñetas y una sección final de puntos clave.';

    final content = [
      Content.multi([
        TextPart(systemPrompt),
        TextPart('Resume el PDF de forma breve y fiel.'),
        DataPart('application/pdf', pdfBytes),
      ]),
    ];

    Object? lastError;
    for (final m in candidates) {
      try {
        final model = GenerativeModel(
          model: m,
          apiKey: _apiKey,
          generationConfig: GenerationConfig(
            temperature: 0.3,
            maxOutputTokens: 1024,
          ),
        );
        final resp = await model.generateContent(content);
        final txt = resp.text?.trim();
        if (txt != null && txt.isNotEmpty) return txt;
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError('No se pudo usar Gemini (último error: $lastError)');
  }
}
