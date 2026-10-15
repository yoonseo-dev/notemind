// 구현할 때 필요한 import입니다. TODO를 채우면 경고가 사라집니다.
// ignore_for_file: unused_import
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/config.dart';
import '../core/document_import.dart';
import 'inference.dart';
import 'models.dart';
import 'study_session.dart';

final repositoryProvider = Provider<NoteRepository>((ref) {
  // 연결 설정에서 Supabase 주소·키를 바꾸면 새 클라이언트로 다시 만듭니다.
  ref.watch(configProvider.select((c) => (c.supabaseUrl, c.anonKey)));
  return NoteRepository(Supabase.instance.client);
});
final documentsProvider = FutureProvider<List<NoteDocument>>(
  (ref) => ref.watch(repositoryProvider).documents(),
);
final conversationsProvider = FutureProvider<List<Json>>(
  (ref) => ref.watch(repositoryProvider).conversations(),
);

class NoteRepository {
  NoteRepository(this.client);
  final SupabaseClient client;
  String get userId => client.auth.currentUser!.id;
  Future<List<NoteDocument>> documents() async {
    await ensureStudySession(client);
    return (await client
            .from('documents')
            .select()
            .order('created_at', ascending: false))
        .map(NoteDocument.fromJson)
        .toList();
  }

  Future<List<Json>> conversations() async {
    await ensureStudySession(client);
    return await client
        .from('conversations')
        .select()
        .order('created_at', ascending: false)
        .limit(100);
  }

  Future<List<ChatMessage>> messages(String id) async {
    await ensureStudySession(client);
    return (await client
            .from('messages')
            .select()
            .eq('conversation_id', id)
            .order('created_at', ascending: true))
        .map(ChatMessage.fromJson)
        .toList();
  }

  Future<void> saveMessage(ChatMessage message, String conversation) async {
    // TODO(7): 메시지 저장
    // - 먼저 await ensureStudySession(client)로 익명 로그인을 확인합니다.
    // - 'messages' 테이블에 message.toJson(conversation)을 upsert합니다.
    //   (같은 id로 여러 번 저장하므로 insert가 아니라 upsert입니다.
    //   답변을 받는 동안 상태가 바뀔 때마다 다시 저장합니다.)
    await ensureStudySession(client);
    await client.from('messages').upsert(message.toJson(conversation));
  }

  Future<String> createConversation(
    String title,
    bool rag, {
    String? documentId,
  }) async {
    // TODO(6): 대화 만들기
    // - await ensureStudySession(client) 후 const Uuid().v4()로 새 id를 만듭니다.
    // - 'conversations' 테이블에 insert합니다.
    //   'id': id, 'title': 제목(첫 질문을 runes 기준 50자까지),
    //   'mode': rag ? 'rag' : 'chat', 'document_id': documentId
    // - 만든 id를 반환합니다.
    await ensureStudySession(client);
    final id = const Uuid().v4();
    await client.from('conversations').insert({
      'id': id,
      'title': String.fromCharCodes(title.runes.take(50)),
      'mode': rag ? 'rag' : 'chat',
      'document_id': documentId,
    });
    return id;
  }

  Future<void> removeDocument(NoteDocument document) async {
    await ensureStudySession(client);
    await client.storage.from('documents').remove([document.path]);
    await client.from('documents').delete().eq('id', document.id);
  }

  Future<void> ingest(
    String name,
    Uint8List bytes,
    AppConfig config,
    void Function(double, String) progress, {
    NoteDocument? retry,
  }) async {
    // TODO(4): 문서 업로드와 색인
    // 1) extractDocumentChunks(name, bytes, progress)로 청크를 만듭니다. (TODO 2)
    // 2) await ensureStudySession(client)
    // 3) id는 retry?.id ?? 새 Uuid, 저장 경로는
    //    retry?.path ?? '$userId/$id/note.${documentExtension(name)}'
    // 4) 'documents' 테이블에 기록합니다.
    //    - 새 문서: insert {'id', 'title'(240자까지), 'storage_path', 'embedding_model'}
    //    - 재시도: update {'status': 'processing', 'error': null, 'embedding_model'} where id
    // 5) client.storage.from('documents').uploadBinary(path, bytes,
    //    fileOptions: FileOptions(contentType: documentContentType(name), upsert: true))
    // 6) InferenceSession(config)로 청크를 4개씩 embed()합니다. (TODO 3)
    //    결과를 {'content': 청크, 'embedding': 벡터} 목록으로 모으고,
    //    progress(0.1 + 0.8 * 완료수 / 전체수, '임베딩 n / 전체')로 알립니다.
    // 7) client.rpc('finish_document', params: {'p_document_id': id, 'p_chunks': rows})
    //    (DB 함수가 청크를 한 번에 저장하고 문서 상태를 'ready'로 바꿉니다.)
    // 8) progress(1, '문서 준비 완료')
    // - 4) 이후 실패하면 문서 상태를 {'status': 'failed', 'error': friendlyError(error)}로
    //   바꾸고 rethrow합니다. 세션은 finally에서 session.close()로 닫습니다.

    final chunks = await extractDocumentChunks(name, bytes, progress);
    await ensureStudySession(client);
    final id = retry?.id ?? const Uuid().v4();
    final path = retry?.path ?? '$userId/$id/note.${documentExtension(name)}';
    final model = config.embeddingModel;
    var inserted = false;
    final session = InferenceSession(config);
    try {
      progress(0.09, '문서 준비 중');
      if (retry == null) {
        await client.from('documents').insert({
          'id': id,
          'title': String.fromCharCodes(name.runes.take(240)),
          'storage_path': path,
          'embedding_model': model,
        });
      } else {
        await client
            .from('documents')
            .update({
              'status': 'processing',
              'error': null,
              'embedding_model': model,
            })
            .eq('id', id);
      }
      inserted = true;
      await client.storage
          .from('documents')
          .uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(
              contentType: documentContentType(name),
              upsert: true,
            ),
          );
      final rows = <Json>[];
      for (var index = 0; index < chunks.length; index += 4) {
        final batch = chunks.sublist(
          index,
          (index + 4).clamp(0, chunks.length),
        );
        final vectors = await session.embed(batch);
        for (var i = 0; i < batch.length; i++) {
          rows.add({'content': batch[i], 'embedding': vectors[i]});
        }
        progress(
          0.1 + 0.8 * rows.length / chunks.length,
          '임베딩 ${rows.length} / ${chunks.length}',
        );
      }
      progress(0.95, '검색 가능한 문서로 저장 중');
      await client.rpc(
        'finish_document',
        params: {'p_document_id': id, 'p_chunks': rows},
      );
      progress(1, '문서 준비 완료');
    } catch (error) {
      if (inserted) {
        try {
          await client
              .from('documents')
              .update({'status': 'failed', 'error': friendlyError(error)})
              .eq('id', id);
        } catch (_) {
          /* 원래 오류를 보존합니다. */
        }
      }
      rethrow;
    } finally {
      session.close();
    }
  }

  Future<void> retryDocument(
    NoteDocument document,
    AppConfig config,
    void Function(double, String) progress,
  ) async {
    // TODO(5): 실패한 문서 다시 처리
    // - await ensureStudySession(client)
    // - client.storage.from('documents').download(document.path)로 원본을 받습니다.
    // - ingest(document.title, bytes, config, progress, retry: document)를 호출합니다.
    await ensureStudySession(client);
    final bytes = await client.storage
        .from('documents')
        .download(document.path);
    await ingest(document.title, bytes, config, progress, retry: document);
  }

  Future<({List<SourceChunk> sources, bool partial})> overview({
    String? documentId,
  }) async {
    // TODO(10): 요약용 근거 가져오기 (검색 없이 문서 앞부분 사용)
    // - documents() 중 status가 'ready'이고, documentId가 있으면 그 id와 같은 문서만 고릅니다.
    // - 0개면 (sources: <SourceChunk>[], partial: false)를 반환합니다.
    // - 2개 이상이면 어떤 문서를 요약할지 모르므로 FormatException을 던집니다.
    //   ('요약할 문서를 골라주세요. ...')
    // - 'chunks' 테이블에서 select('id, document_id, position, content'),
    //   eq('document_id', 문서 id), order('position', ascending: true), limit(8 + 1)
    // - 앞 8개를 SourceChunk.fromJson({...row, 'title': 문서 제목, 'similarity': null})로 바꿉니다.
    // - 9개째가 있으면 partial: true입니다. (문서가 길어 앞부분만 요약)
    // - 확인: flutter test test/overview_repository_test.dart

    final ready = (await documents())
        .where(
          (d) =>
              d.status == 'ready' && (documentId == null || d.id == documentId),
        )
        .toList();
    if (ready.isEmpty) return (sources: <SourceChunk>[], partial: false);
    if (ready.length > 1) {
      throw const FormatException(
        '요약할 문서를 골라주세요. '
        '문서함에서 해당 문서의 "이 노트에 질문하기"를 누르면 됩니다.',
      );
    }
    final doc = ready.single;
    const limit = 8;
    final rows = await client
        .from('chunks')
        .select('id, document_id, position, content')
        .eq('document_id', doc.id)
        .order('position', ascending: true)
        .limit(limit + 1);
    return (
      sources: rows
          .take(limit)
          .map(
            (row) => SourceChunk.fromJson({
              ...row,
              'title': doc.title,
              'similarity': null,
            }),
          )
          .toList(),
      partial: rows.length > limit,
    );
  }

  Future<List<SourceChunk>> search(
    List<double> vector,
    String model, {
    String? documentId,
  }) async {
    // TODO(9): 벡터 검색 (RAG의 R)
    // - await ensureStudySession(client)
    // - client.rpc('match_chunks', params: {...})를 호출합니다.
    //   'query_embedding': vector, 'p_model': model,
    //   'match_threshold': 0.45, 'match_count': 5, 'p_document_id': documentId
    //   (유사도 0.45 이상인 청크를 최대 5개 가져옵니다.)
    // - 결과 List의 각 행을 Map<String, dynamic>.from(row)로 바꾼 뒤
    //   SourceChunk.fromJson으로 변환해 반환합니다.
    await ensureStudySession(client);
    final result = await client.rpc(
      'match_chunks',
      params: {
        'query_embedding': vector,
        'p_model': model,
        'match_threshold': 0.45,
        'match_count': 5,
        'p_document_id': documentId,
      },
    );
    return (result as List)
        .map((row) => SourceChunk.fromJson(Map<String, dynamic>.from(row)))
        .toList();
  }
}

String friendlyError(Object error) {
  if (error is AuthException) {
    return error.message;
  }
  if (error is FormatException) {
    return error.message;
  }
  if (error is PostgrestException) {
    return '데이터 저장·조회에 실패했습니다. 서버 연결과 DB 마이그레이션을 확인하세요. (${error.code ?? 'DB'})';
  }
  if (error is StorageException) {
    return '문서 파일 처리에 실패했습니다. 연결을 확인하고 다시 시도하세요.';
  }
  final text = error.toString().replaceFirst('Exception: ', '');
  if (text.contains('SocketException') ||
      text.contains('ClientException') ||
      text.contains('TimeoutException')) {
    return '서버에 연결할 수 없습니다. 연결 설정과 로컬 서버 상태를 확인하세요.';
  }
  return text;
}
