// lib/pages/feed_page.dart
import 'dart:math';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
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
  String _query = '';

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
      final data = await _postsService.fetchFeed(limit: 200);
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
          caption: caption, filename: file.name, bytes: bytes);
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
    final ok = await launchUrl(Uri.parse(post.fileUrl),
        mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo abrir el PDF')));
    }
  }

  Future<void> _summarize(PostItem post) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _BlurDialog(child: CircularProgressIndicator()),
    );

    AISummaryResult result;
    try {
      result = await _ai.fetchOrCreateSummary(
        postId: post.id,
        pdfUrl: post.fileUrl,
        prompt:
            'Resume el PDF en español con introducción breve, viñetas claras y puntos clave (200–250 palabras).',
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
            child: Text('Error al resumir: $e')),
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
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, controller) => Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(
            controller: controller,
            children: [
              Row(
                children: [
                  const Icon(Icons.summarize_outlined),
                  const SizedBox(width: 8),
                  Text('Resumen IA',
                      style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
              const SizedBox(height: 12),
              SelectableText(result.text),
              const SizedBox(height: 16),
              if (result.fileUrl != null)
                FilledButton.tonalIcon(
                  onPressed: () => launchUrl(Uri.parse(result.fileUrl!),
                      mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('Abrir archivo .md'),
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

  List<PostItem> get _filtered {
    if (_query.trim().isEmpty) return _posts;
    final q = _query.toLowerCase();
    return _posts
        .where((p) =>
            p.caption.toLowerCase().contains(q) ||
            p.filePath.toLowerCase().contains(q))
        .toList();
  }

  @override
  void dispose() {
    _captionCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser!;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              expandedHeight: 132,
              flexibleSpace: FlexibleSpaceBar(
                titlePadding:
                    const EdgeInsetsDirectional.only(start: 16, bottom: 16),
                title: const Text('Feed de PDFs'),
                background: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [cs.primaryContainer, cs.secondaryContainer],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                ),
              ),
              actions: [
                IconButton(
                  tooltip: 'Salir',
                  onPressed: () => Supabase.instance.client.auth.signOut(),
                  icon: const Icon(Icons.logout),
                ),
                const SizedBox(width: 8),
              ],
            ),

            // Búsqueda
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: SearchBar(
                  hintText: 'Buscar por título o archivo…',
                  leading: const Icon(Icons.search),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            ),

            // Composer
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: _Composer(
                  email: user.email ?? 'U',
                  controller: _captionCtrl,
                  loading: _loading,
                  errorText: _error,
                  onSubmit: _pickAndPublish,
                )
                    .animate()
                    .fadeIn(duration: 250.ms, curve: Curves.easeOut)
                    .moveY(begin: 8, end: 0, duration: 250.ms),
              ),
            ),

            // Grid
            if (_loading && _posts.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(48),
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else if (_filtered.isEmpty)
              const SliverToBoxAdapter(child: _EmptyState())
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                sliver: SliverGrid(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final p = _filtered[index];
                      return _PdfCard(
                        post: p,
                        onOpen: _openPdf,
                        onDelete: _delete,
                        onSummarize: _summarize,
                      )
                          .animate()
                          .fadeIn(delay: (index * 40).ms, duration: 220.ms)
                          .moveY(begin: 10, end: 0, curve: Curves.easeOutCubic);
                    },
                    childCount: _filtered.length,
                  ),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 420,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    mainAxisExtent: 176,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final String email;
  final TextEditingController controller;
  final bool loading;
  final String? errorText;
  final VoidCallback onSubmit;
  const _Composer({
    required this.email,
    required this.controller,
    required this.loading,
    required this.errorText,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [cs.surface, cs.surfaceVariant.withOpacity(.6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
              blurRadius: 20,
              color: Colors.black.withOpacity(0.06),
              offset: const Offset(0, 8))
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: cs.primaryContainer,
                child: Text((email.isNotEmpty ? email[0] : 'U').toUpperCase()),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    hintText: 'Escribe un texto para tu PDF...',
                    border: OutlineInputBorder(borderSide: BorderSide.none),
                    isDense: true,
                  ),
                  maxLines: 2,
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: loading ? null : onSubmit,
                icon: loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('Subir PDF'),
              ),
            ],
          ),
          if (errorText != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(errorText!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          ],
        ]),
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

  String _prettyDate(DateTime dt) {
    final d = dt;
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final me = Supabase.instance.client.auth.currentUser!;
    final isOwner = me.id == post.userId;
    final cs = Theme.of(context).colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onOpen(post),
        child: Stack(children: [
          Positioned.fill(
              child: CustomPaint(
                  painter: _SoftPatternPainter(color: cs.primaryContainer))),
          Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.withOpacity(.25)),
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.picture_as_pdf, size: 16, color: Colors.red),
                    SizedBox(width: 6),
                    Text('PDF', style: TextStyle(fontWeight: FontWeight.w600)),
                  ]),
                ),
                const Spacer(),
                Tooltip(
                  message: 'Abrir PDF',
                  child: IconButton(
                      onPressed: () => onOpen(post),
                      icon: const Icon(Icons.open_in_new),
                      visualDensity: VisualDensity.compact),
                ),
                Tooltip(
                  message: 'Resumir con IA',
                  child: IconButton(
                      onPressed: () => onSummarize(post),
                      icon: const Icon(Icons.summarize_outlined),
                      visualDensity: VisualDensity.compact),
                ),
                if (isOwner)
                  Tooltip(
                    message: 'Eliminar',
                    child: IconButton(
                        onPressed: () => onDelete(post),
                        icon: const Icon(Icons.delete_outline),
                        visualDensity: VisualDensity.compact),
                  ),
              ]),
              const SizedBox(height: 12),
              Text(
                post.caption.isEmpty ? '(Sin título)' : post.caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Row(children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: cs.secondaryContainer,
                  child: Text(
                      post.authorUsername.isNotEmpty
                          ? post.authorUsername[0].toUpperCase()
                          : 'U',
                      style: const TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_fileName(post.filePath),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                const SizedBox(width: 8),
                Text(_prettyDate(post.createdAt),
                    style: Theme.of(context).textTheme.bodySmall),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _SoftPatternPainter extends CustomPainter {
  final Color color;
  _SoftPatternPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final rnd = Random(size.hashCode);
    final paint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20);
    for (int i = 0; i < 5; i++) {
      paint.color = color.withOpacity(0.35 - i * 0.05);
      final r = size.shortestSide / (6 + i * 2);
      final dx = rnd.nextDouble() * size.width;
      final dy = rnd.nextDouble() * size.height;
      canvas.drawCircle(Offset(dx, dy), r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SoftPatternPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _BlurDialog extends StatelessWidget {
  final Widget child;
  const _BlurDialog({required this.child});
  @override
  Widget build(BuildContext context) {
    return Dialog(
      elevation: 0,
      backgroundColor: Colors.black.withOpacity(.08),
      insetPadding: EdgeInsets.zero,
      child: Container(
        alignment: Alignment.center,
        height: 120,
        width: 120,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface.withOpacity(.7),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(.2)),
        ),
        child: child,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(children: [
        Icon(Icons.folder_off_outlined, size: 64, color: cs.outline),
        const SizedBox(height: 12),
        Text('Sin publicaciones',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: cs.onSurface)),
        const SizedBox(height: 6),
        Text('Sube tu primer PDF para comenzar.',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: cs.outline)),
      ]),
    );
  }
}
