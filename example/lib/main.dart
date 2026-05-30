// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:smart_network/smart_network.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Data models
// ─────────────────────────────────────────────────────────────────────────────

class Post {
  final int id;
  final String title;
  final String body;

  const Post({required this.id, required this.title, required this.body});

  factory Post.fromJson(dynamic json) {
    final map = json as Map<String, dynamic>;
    return Post(
      id: map['id'] as int,
      title: map['title'] as String,
      body: map['body'] as String,
    );
  }

  @override
  String toString() => 'Post(id: $id, title: "$title")';
}

// ─────────────────────────────────────────────────────────────────────────────
// TokenRefresher implementation (required by SmartConfig)
// ─────────────────────────────────────────────────────────────────────────────

/// Example implementation — replace with your real auth endpoint.
class ExampleTokenRefresher extends TokenRefresher {
  @override
  Future<TokenPair> refresh(String refreshToken) async {
    // In a real app you would POST to your /auth/refresh endpoint.
    // For the example, we simulate a successful refresh.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return const TokenPair(
      accessToken: 'fresh-access-token',
      refreshToken: 'fresh-refresh-token',
      expiresIn: 3600,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Repository
// ─────────────────────────────────────────────────────────────────────────────

class PostRepository {
  final _client = SmartNetworkClient();

  /// GET /posts — cached, deduplicated, auto-retried
  Future<List<Post>> getPosts({int page = 1}) async {
    final res = await _client.get<List<Post>>(
      '/posts',
      queryParameters: {'_page': page, '_limit': 10},
      fromJson: (json) =>
          (json as List<dynamic>).map(Post.fromJson).toList(),
    );

    print('  fromCache: ${res.fromCache}  isStale: ${res.isStale}');
    return res.data;
  }

  /// GET /posts/1 — single post with long-lived cache
  Future<Post> getPost(int id) async {
    final res = await _client.get<Post>(
      '/posts/$id',
      fromJson: Post.fromJson,
    );
    return res.data;
  }

  /// POST /posts — queued when offline
  Future<void> createPost({
    required String title,
    required String body,
  }) async {
    final res = await _client.post<dynamic>(
      '/posts',
      data: {'title': title, 'body': body, 'userId': 1},
      queueIfOffline: true, // persisted when offline
    );

    if (res.isQueued) {
      print('  ✉️ Request queued — will be sent when online');
    } else {
      print('  ✅ Post created: ${res.data}');
    }
  }

  /// DELETE /posts/:id — queued when offline
  Future<void> deletePost(int id) async {
    await _client.delete<dynamic>(
      '/posts/$id',
      queueIfOffline: true,
    );
    print('  🗑️ Deleted post $id');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// App entry point
// ─────────────────────────────────────────────────────────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── SmartNetwork one-time initialisation ──────────────────────────────────
  await SmartNetworkClient().initialize(
    SmartConfig(
      baseUrl: 'https://jsonplaceholder.typicode.com',

      // Timeouts
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),

      // Retry: up to 3 attempts with exponential back-off
      retryPolicy: const RetryPolicy(
        maxAttempts: 3,
        retryOnStatusCodes: {408, 500, 502, 503, 504},
        backoffStrategy: ExponentialBackoff(
          base: Duration(seconds: 1),
          maxDelay: Duration(seconds: 15),
          jitterFactor: 0.5,
        ),
      ),

      // Cache: stale-while-revalidate, 10-min TTL
      cachePolicy: const CachePolicy(
        enabled: true,
        maxAge: Duration(minutes: 10),
        staleAge: Duration(minutes: 30),
        strategy: CacheStrategy.staleWhileRevalidate,
        maxMemoryEntries: 200,
      ),

      // Auth (disabled for JSONPlaceholder — enable for your real API)
      // tokenRefresher: ExampleTokenRefresher(),

      // Offline queue
      enableOfflineMode: true,

      // Deduplication
      enableDeduplication: true,

      // Logging (disable in release builds)
      enableLogging: true,

      // Request batching (uncomment + add batchEndpoint to your API)
      // batchConfig: BatchConfig(
      //   batchEndpoint: '/batch',
      //   maxBatchSize: 10,
      //   windowDuration: Duration(milliseconds: 50),
      // ),
    ),
  );

  runApp(const SmartNetworkExampleApp());
}

// ─────────────────────────────────────────────────────────────────────────────
// UI
// ─────────────────────────────────────────────────────────────────────────────

class SmartNetworkExampleApp extends StatelessWidget {
  const SmartNetworkExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'smart_network Example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const PostListPage(),
    );
  }
}

class PostListPage extends StatefulWidget {
  const PostListPage({super.key});

  @override
  State<PostListPage> createState() => _PostListPageState();
}

class _PostListPageState extends State<PostListPage> {
  final _repo = PostRepository();
  final _client = SmartNetworkClient();

  List<Post> _posts = [];
  bool _loading = false;
  String? _error;
  String _cacheStatus = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final posts = await _repo.getPosts();
      final diag = await _client.diagnostics();

      setState(() {
        _posts = posts;
        _loading = false;
        _cacheStatus =
            'Memory: ${diag['cacheEntries']['memory']} | '
            'Hive: ${diag['cacheEntries']['hive']} | '
            'Queue: ${diag['offlineQueueSize']}';
      });
    } on SmartException catch (e) {
      setState(() {
        _loading = false;
        _error = '${e.type.name}: ${e.message}';
      });
    }
  }

  Future<void> _create() async {
    try {
      await _repo.createPost(
        title: 'Test post ${DateTime.now().millisecond}',
        body: 'Created from smart_network example.',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Post created (or queued)!')),
      );
    } on SmartException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: ${e.message}')),
      );
    }
  }

  Future<void> _clearCache() async {
    await _client.clearCache();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Cache cleared')),
    );
    setState(() => _cacheStatus = 'Cache cleared');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('smart_network Demo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear Cache',
            onPressed: _clearCache,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Cache status banner ──────────────────────────────────────────
          Container(
            width: double.infinity,
            color: Colors.indigo.shade50,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
            child: Text(
              _cacheStatus.isEmpty ? 'Loading...' : '📦 Cache: $_cacheStatus',
              style: const TextStyle(fontSize: 12, color: Colors.indigo),
            ),
          ),

          // ── Content ──────────────────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _ErrorView(message: _error!, onRetry: _load)
                    : _PostList(posts: _posts),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('Create Post'),
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _PostList extends StatelessWidget {
  final List<Post> posts;
  const _PostList({required this.posts});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: posts.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final post = posts[index];
        return ListTile(
          leading: CircleAvatar(child: Text('${post.id}')),
          title: Text(
            post.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            post.body,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
