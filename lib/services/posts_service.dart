import 'dart:typed_data';
import 'package:mime/mime.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../constants.dart';

class PostItem {
  final String id;
  final String userId;
  final String authorUsername;
  final String caption;
  final String filePath;
  final String fileUrl;
  final DateTime createdAt;

  PostItem({
    required this.id,
    required this.userId,
    required this.authorUsername,
    required this.caption,
    required this.filePath,
    required this.fileUrl,
    required this.createdAt,
  });
}

class PostsService {
  final _client = Supabase.instance.client;

  String get _uid {
    final id = _client.auth.currentUser?.id;
    if (id == null) throw StateError('User not authenticated');
    return id;
  }

  /// Sube un PDF al bucket público y crea el registro en `posts` (image_path guarda la ruta).
  Future<void> createPost({
    required String caption,
    required String filename,
    required Uint8List bytes,
  }) async {
    final uid = _uid;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final safeName = filename.replaceAll(RegExp(r'\s+'), '_');
    final path = '$uid/docs/${ts}_$safeName';

    final contentType =
        lookupMimeType(filename, headerBytes: bytes) ?? 'application/pdf';

    await _client.storage.from(storageBucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            cacheControl: '3600',
            upsert: false,
            contentType: contentType,
          ),
        );

    await _client.from('posts').insert({
      'user_id': uid,
      'caption': caption,
      'image_path': path, // reutilizamos este campo
    });
  }

  Future<List<PostItem>> fetchFeed({int limit = 100, int offset = 0}) async {
    final rows = await _client
        .from('posts_with_author')
        .select('id,user_id,author_username,caption,image_path,created_at')
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);

    final storage = _client.storage.from(storageBucket);

    return (rows as List).map((r) {
      final path = r['image_path'] as String;
      final url = storage.getPublicUrl(path);
      return PostItem(
        id: r['id'] as String,
        userId: r['user_id'] as String,
        authorUsername: (r['author_username'] as String?) ?? 'Usuario',
        caption: (r['caption'] as String?) ?? '',
        filePath: path,
        fileUrl: url,
        createdAt: DateTime.parse(r['created_at'] as String).toLocal(),
      );
    }).toList();
  }

  Future<void> deletePost(PostItem post) async {
    await _client.storage.from(storageBucket).remove([post.filePath]);
    await _client.from('posts').delete().eq('id', post.id);
  }
}
