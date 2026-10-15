// 구현할 때 필요한 import입니다. TODO를 채우면 경고가 사라집니다.
// ignore_for_file: unused_import
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config.dart';
import '../core/text_processing.dart';
import 'models.dart';

class RequestCancelled implements Exception {}

/// Each operation owns its socket client; cancel closes even an in-flight request.
class InferenceSession {
  InferenceSession(this.config, {http.Client? client})
    : _client = client ?? http.Client();
  final AppConfig config;
  final http.Client _client;
  bool cancelled = false;
  void cancel() {
    cancelled = true;
    _client.close();
  }

  void close() => _client.close();
  void check() {
    if (cancelled) {
      throw RequestCancelled();
    }
  }

  Map<String, String> get headers => {
    'Content-Type': 'application/json',
    if (config.apiKey.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey}',
  };
  Uri endpoint(String base, String path) =>
      Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}/$path');

  /// 여러 문장을 한 번에 1024차원 벡터로 바꿉니다. (POST {embeddingUrl}/embeddings)
  Future<List<List<double>>> embed(List<String> texts) async {
    // TODO(3): 임베딩 요청
    // - 시작할 때 check()를 호출합니다. (취소된 세션이면 RequestCancelled)
    // - _client.post(endpoint(config.embeddingUrl, 'embeddings'), headers: headers, body: ...)
    //   body: jsonEncode({'model': config.embeddingModel, 'input': texts,
    //                     'encoding_format': 'float'})
    //   .timeout(const Duration(seconds: 90))를 붙입니다.
    // - 응답을 받은 뒤 다시 check()를 호출합니다.
    // - statusCode가 200이 아니면 Exception('임베딩 요청 실패 (코드). ...')
    // - 응답 JSON의 'data' 목록은 순서가 섞일 수 있습니다. 'index' 기준으로 정렬합니다.
    // - 결과 개수가 texts 개수와 다르면 FormatException.
    // - 각 'embedding'을 List<double>로 바꿉니다.
    //   길이가 1024가 아니거나 isFinite가 아닌 값이 있으면 FormatException.
    // - 확인: flutter test test/core_test.dart
    //   ('embedding order is restored ...', 'cancel closes the transport ...')
    check();
    final response = await _client
        .post(
          endpoint(config.embeddingUrl, 'embeddings'),
          headers: headers,
          body: jsonEncode({
            'model': config.embeddingModel,
            'input': texts,
            'encoding_format': 'float',
          }),
        )
        .timeout(const Duration(seconds: 90));
    check();
    if (response.statusCode != 200) {
      throw Exception('임베딩 요청 실패 (${response.statusCode}).');
    }
    final data =
        (jsonDecode(response.body)['data'] as List)
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
          ..sort((a, b) => (a['index'] as int).compareTo(b['index'] as int));
    if (data.length != texts.length) {
      throw const FormatException('임베딩 응답 개수가 다릅니다.');
    }
    return data.map((row) {
      final vector = (row['embedding'] as List)
          .map((n) => (n as num).toDouble())
          .toList();
      if (vector.length != 1024 || vector.any((n) => !n.isFinite)) {
        throw const FormatException('이 앱은 1024차원 임베딩 모델을 사용합니다.');
      }
      return vector;
    }).toList();
  }

  /// 대화 메시지를 보내고 답변을 토큰 단위로 받습니다. (POST {chatUrl}/chat/completions)
  Stream<String> chat(List<Json> messages) async* {
    // TODO(12): 스트리밍 답변 받기
    // - check() 후 http.Request('POST', endpoint(config.chatUrl, 'chat/completions'))를 만듭니다.
    //   headers를 넣고, body는 jsonEncode로 아래 값을 보냅니다.
    //   'model': config.model, 'messages': messages, 'stream': true,
    //   'max_tokens': 768, 'temperature': 0.2,
    //   'chat_template_kwargs': {'enable_thinking': false}
    // - _client.send(request).timeout(60초) 후 check(). 200이 아니면 Exception.
    // - sseData(response.stream.timeout(90초))로 이벤트를 하나씩 읽습니다. (TODO 11)
    //   - 이벤트마다 check()를 호출합니다.
    //   - '[DONE]'이면 정상 종료 표시를 하고 반복을 끝냅니다.
    //   - JSON에 'error'가 있으면 Exception.
    //   - choices[0]['delta']['content']가 비어 있지 않은 문자열이면 yield합니다.
    // - 반복이 끝난 뒤 check()를 호출합니다.
    //   '[DONE]'을 받지 못했으면 Exception('응답 연결이 완료 전에 끊어졌습니다. ...')
    // - 확인: flutter test test/core_test.dart
    //   ('SSE refuses silently truncated answers', 'a socket that ends quietly ...')
    check();
    final request =
        http.Request('POST', endpoint(config.chatUrl, 'chat/completions'))
          ..headers.addAll(headers)
          ..body = jsonEncode({
            'model': config.model,
            'messages': messages,
            'stream': true,
            'max_tokens': 768,
            'temperature': 0.2,
            'chat_template_kwargs': {'enable_thinking': false},
          });
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 60));
    check();
    if (response.statusCode != 200) {
      throw Exception(
        '생성 요청 실패 (${response.statusCode}). '
        '서버 로그와 모델 설정을 확인하세요.',
      );
    }
    var done = false;
    await for (final event in sseData(
      response.stream.timeout(const Duration(seconds: 90)),
    )) {
      check();
      if (event == '[DONE]') {
        done = true;
        break;
      }
      final json = jsonDecode(event) as Json;
      if (json.containsKey('error')) {
        throw Exception('추론 서버가 오류를 반환했습니다.');
      }
      final choices = json['choices'] as List? ?? [];
      if (choices.isEmpty) continue;
      final content = choices.first['delta']?['content'];
      if (content is String && content.isNotEmpty) yield content;
    } // await for 끝
    check();
    if (!done) {
      throw Exception('응답 연결이 완료 전에 끊어졌습니다. 다시 시도하세요.');
    }
  }

  Future<void> probe(String base, String model) async {
    final response = await _client
        .get(endpoint(base, 'models'), headers: headers)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final models = jsonDecode(response.body)['data'] as List;
    if (!models.any((m) => m['id'] == model)) {
      throw Exception('모델 이름 불일치: $model');
    }
  }
}
