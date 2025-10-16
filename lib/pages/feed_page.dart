// lib/pages/feed_page.dart
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/posts_service.dart';
import '../services/ai_summary_service.dart';

class FeedPage extends StatefulWidget {
  const FeedPage({super.key});

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  final _postsService = PostsService();
  final _ai = AISummaryService();
  final _captionCtrl = TextEditingController();

  bool _loading = false;
  String? _error;
  List<PostItem> _posts = [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _postsService.fetchFeed(limit: 100);
      setState(() => _posts = data);
    } catch (e) {
      setState(() => _error = 'Error al cargar feed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickAndPublish() async {
    final caption = _captionCtrl.text.trim();
    if (caption.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Escribe un texto para tu PDF...')),
      );
      return;
    }

    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      allowMultiple: false,
      withData: true,
    );
    if (res == null || res.files.isEmpty) return;

    final file = res.files.single;
    final Uint8List? bytes = file.bytes;
    if (bytes == null) {
      setState(() => _error = 'No se pudo leer el PDF.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _postsService.createPost(
        caption: caption,
        filename: file.name,
        bytes: bytes,
      );
      _captionCtrl.clear();
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PDF subido y publicación creada')),
        );
      }
    } catch (e) {
      setState(() => _error = 'Error al publicar: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openPdf(PostItem post) async {
    final uri = Uri.parse(post.fileUrl);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir el PDF')),
      );
    }
  }

  Future<void> _summarize(PostItem post) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    AISummaryResult result;
    try {
      result = await _ai.fetchOrCreateSummary(
        postId: post.id,
        pdfUrl: post.fileUrl,
        prompt:
            'Resume el PDF en español con una introducción breve, viñetas claras y puntos clave (200-250 palabras).',
      );
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Error al resumir: $e'),
        ),
      );
      return;
    } finally {
      if (mounted) Navigator.of(context).pop();
    }

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.65,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, controller) => Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(
            controller: controller,
            children: [
              Text('Resumen del PDF con IA',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              SelectableText(result.text),
              const SizedBox(height: 16),
              if (result.fileUrl != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Abrir archivo .md'),
                    onPressed: () async {
                      final ok = await launchUrl(Uri.parse(result.fileUrl!),
                          mode: LaunchMode.externalApplication);
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('No se pudo abrir el archivo')),
                        );
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _delete(PostItem post) async {
    final me = Supabase.instance.client.auth.currentUser!;
    if (me.id != post.userId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Solo el autor puede borrar su publicación')),
      );
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar publicación'),
        content: const Text('¿Seguro que quieres eliminarla?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _postsService.deletePost(post);
      await _refresh();
    } catch (e) {
      setState(() => _error = 'Error al eliminar: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _captionCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser!;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Feed de PDFs'),
        actions: [
          TextButton.icon(
            onPressed:
                _loading ? null : () => Supabase.instance.client.auth.signOut(),
            icon: const Icon(Icons.logout),
            label: const Text('Salir'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              elevation: 0,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                            child: Text((user.email ?? 'U')[0].toUpperCase())),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _captionCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Escribe un texto para tu PDF...',
                              border: OutlineInputBorder(),
                            ),
                            maxLines: 2,
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                          onPressed: _loading ? null : _pickAndPublish,
                          icon: _loading
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.picture_as_pdf_outlined),
                          label: const Text('Subir PDF'),
                        ),
                      ],
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_loading && _posts.isEmpty)
              const Center(
                  child: Padding(
                      padding: EdgeInsets.all(24.0),
                      child: CircularProgressIndicator())),
            for (final p in _posts)
              _PdfCard(
                post: p,
                onOpen: _openPdf,
                onDelete: _delete,
                onSummarize: _summarize,
              ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
}

class _PdfCard extends StatelessWidget {
  final PostItem post;
  final Future<void> Function(PostItem) onOpen;
  final Future<void> Function(PostItem) onDelete;
  final Future<void> Function(PostItem) onSummarize;

  const _PdfCard({
    required this.post,
    required this.onOpen,
    required this.onDelete,
    required this.onSummarize,
  });

  String _fileName(String path) {
    final idx = path.lastIndexOf('/');
    return idx >= 0 ? path.substring(idx + 1) : path;
  }

  @override
  Widget build(BuildContext context) {
    final me = Supabase.instance.client.auth.currentUser!;
    final isOwner = me.id == post.userId;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: const Icon(Icons.picture_as_pdf, color: Colors.redAccent),
        title: Text(post.caption.isEmpty ? '(Sin título)' : post.caption),
        subtitle: Text(_fileName(post.filePath)),
        trailing: Wrap(
          spacing: 8,
          children: [
            IconButton(
              tooltip: 'Abrir PDF',
              onPressed: () => onOpen(post),
              icon: const Icon(Icons.open_in_new),
            ),
            IconButton(
              tooltip: 'Resumir (genera y guarda .md)',
              onPressed: () => onSummarize(post),
              icon: const Icon(Icons.summarize_outlined),
            ),
            if (isOwner)
              IconButton(
                tooltip: 'Eliminar',
                onPressed: () => onDelete(post),
                icon: const Icon(Icons.delete_outline),
              ),
          ],
        ),
      ),
    );
  }
}
