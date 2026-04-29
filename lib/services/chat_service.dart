import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

// ─────────────────────────────────────────────────────────────
// SSEParser
//
// Our backend sends:
//   data: {"delta": "Hello"}
//   data: {"delta": " there"}
//   data: [DONE]
//
// This parser buffers raw text and emits delta strings.
// ─────────────────────────────────────────────────────────────
class SSEParser {
  String _buffer = '';
  bool _isDone = false;

  /// True after [DONE] has been seen — caller should stop reading.
  bool get isDone => _isDone;

  /// Feed a raw text chunk.
  /// Returns any delta text accumulated so far (may be empty).
  /// After this returns, check [isDone] to see if the stream finished.
  /// Throws [ChatException] if the backend sent an error event.
  String parse(String chunk) {
    _buffer += chunk;
    String result = '';

    while (_buffer.contains('\n\n')) {
      final index = _buffer.indexOf('\n\n');
      final rawEvent = _buffer.substring(0, index).trim();
      _buffer = _buffer.substring(index + 2);

      if (rawEvent.isEmpty) continue;

      for (final line in rawEvent.split('\n')) {
        // Skip empty lines and SSE comments (: OPENROUTER PROCESSING)
        if (line.trim().isEmpty || line.trim().startsWith(':')) continue;
        if (!line.startsWith('data:')) continue;

        final data = line.replaceFirst('data:', '').trim();

        // End of stream — yield whatever we have first, then signal done
        if (data == '[DONE]') {
          _isDone = true;
          return result;
        }

        try {
          final decoded = jsonDecode(data) as Map<String, dynamic>;

          // Check if backend sent an error event
          if (decoded.containsKey('error')) {
            throw ChatException(
              decoded['error'] as String? ?? 'Unknown error from server',
            );
          }

          // Our backend sends: { "delta": "text" }
          final delta = decoded['delta'] as String? ?? '';
          result += delta;

        } catch (e) {
          if (e is ChatException) rethrow;
          // Malformed JSON — skip
          continue;
        }
      }
    }

    return result;
  }

  void reset() {
    _buffer = '';
    _isDone = false;
  }
}

// ─────────────────────────────────────────────────────────────
// ChatService
// ─────────────────────────────────────────────────────────────
class ChatService {
  ChatService({
    required String baseUrl,
    String? authToken,
  })  : _baseUrl = baseUrl.replaceAll(RegExp(r'/$'), ''), // remove trailing /
        _authToken = authToken;

  final String _baseUrl;
  final String? _authToken;
  final http.Client _client = http.Client();

  // ── Public API ──────────────────────────────────────────────

  /// Sends a message and returns a Stream<String> of text deltas.
  Stream<String> sendMessage({
    required String message,
    List<Map<String, dynamic>> history = const [],
    String? systemPrompt,
  }) async* {
    final request = http.Request(
      'POST',
      Uri.parse('$_baseUrl/api/chat/stream'),
    );

    request.headers.addAll({
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
      if (_authToken != null) 'Authorization': 'Bearer $_authToken',
    });

    request.body = jsonEncode({
      'message': message,
      'history': history,
      if (systemPrompt != null) 'system_prompt': systemPrompt,
    });

    http.StreamedResponse streamedResponse;

    try {
      streamedResponse = await _client.send(request);
    } on http.ClientException catch (e) {
      throw ChatException(
        'Could not reach the server. Is the backend running?\n${e.message}',
      );
    }

    if (streamedResponse.statusCode != 200) {
      final body = await streamedResponse.stream.bytesToString();
      String message = 'Server error (${streamedResponse.statusCode})';
      try {
        final json = jsonDecode(body) as Map<String, dynamic>;
        message = json['error'] as String? ?? message;
      } catch (_) {}
      throw ChatException(message);
    }

    final parser = SSEParser();

    await for (final chunk
        in streamedResponse.stream.transform(utf8.decoder)) {
      final delta = parser.parse(chunk);

      if (delta.isNotEmpty) yield delta;

      if (parser.isDone) return; // [DONE]
    }
  }

  void dispose() => _client.close();
}

// ─────────────────────────────────────────────────────────────
// ChatException
// ─────────────────────────────────────────────────────────────
class ChatException implements Exception {
  const ChatException(this.message);
  final String message;

  @override
  String toString() => message;
}
