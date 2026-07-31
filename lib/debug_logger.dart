// debug_logger.dart
//
// A small, dependency-free (beyond path_provider, already used elsewhere in
// this app) logger that writes timestamped lines to per-category .txt files
// on-device, so a failure can be diagnosed after the fact instead of only
// via `adb logcat` at the moment it happens.
//
// Files land under the app's own external-storage directory (no runtime
// storage permission needed on any Android version, since it's app-private):
//   <external files dir>/debug_logs/<category>.txt
// e.g. .../Android/data/<package>/files/debug_logs/voice_call.txt
//
// Suggested categories (pass as the first arg to log()):
//   'ui', 'message', 'voice_message', 'file_share',
//   'voice_call', 'video_call', 'screen_share', 'p2p', 'general'
//
// Usage:
//   await DebugLogger.instance.init();               // once, in _initialize()
//   logDebug('voice_call', '_createPeerConnection', 'creating pc');
//   logDebug('voice_call', '_createPeerConnection', 'getUserMedia failed', error: e, stack: st);
//
// To get the logs off the device: DebugLogger.instance.shareAll() opens the
// normal share sheet with every category file attached (uses share_plus,
// already a dependency of this app via the existing Share.shareXFiles calls).

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class DebugLogger {
  DebugLogger._();
  static final DebugLogger instance = DebugLogger._();

  Directory? _logDir;
  bool _ready = false;
  final Map<String, File> _fileCache = {};

  /// Call once at app startup (e.g. in _initialize()). Safe to call more
  /// than once — subsequent calls are no-ops.
  Future<void> init() async {
    if (_ready) return;
    try {
      Directory? base;
      try {
        base = await getExternalStorageDirectory();
      } catch (_) {
        base = null;
      }
      base ??= await getApplicationDocumentsDirectory();

      final dir = Directory('${base.path}/debug_logs');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _logDir = dir;
      _ready = true;
      await log('general', 'DebugLogger', 'Logger initialized. Writing to: ${dir.path}');
    } catch (e, st) {
      // If logging itself can't be set up, fall back to plain debugPrint —
      // never let the logger crash the app.
      debugPrint('DebugLogger init FAILED: $e\n$st');
    }
  }

  String _timestamp() {
    final n = DateTime.now();
    String pad(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${n.year}-${pad(n.month)}-${pad(n.day)} '
        '${pad(n.hour)}:${pad(n.minute)}:${pad(n.second)}.${n.millisecond.toString().padLeft(3, '0')}';
  }

  /// Writes one line to `<category>.txt`. `source` should be the class or
  /// function name the log came from, so a shared category file (e.g.
  /// 'voice_call.txt' getting lines from both call-setup and ICE-candidate
  /// handling) still reads clearly.
  Future<void> log(
    String category,
    String source,
    String message, {
    Object? error,
    StackTrace? stack,
  }) async {
    final buf = StringBuffer('[${_timestamp()}] [$source] $message');
    if (error != null) buf.write(' | ERROR: $error');
    if (stack != null) buf.write('\n$stack');

    // Always echo to the normal console too, so `adb logcat` / the IDE
    // console still shows everything live during development.
    debugPrint('[$category/$source] $message${error != null ? ' | ERROR: $error' : ''}');

    if (!_ready) await init();
    final dir = _logDir;
    if (dir == null) return; // init() already logged/printed the failure

    try {
      final safeCategory = category.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final file = _fileCache.putIfAbsent(
        safeCategory,
        () => File('${dir.path}/$safeCategory.txt'),
      );
      await file.writeAsString('${buf.toString()}\n', mode: FileMode.append, flush: true);
    } catch (e) {
      debugPrint('DebugLogger write FAILED for "$category": $e');
    }
  }

  Future<List<File>> listLogFiles() async {
    if (!_ready) await init();
    final dir = _logDir;
    if (dir == null || !await dir.exists()) return [];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.txt'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  /// Empties every category file (keeps the files themselves).
  Future<void> clearAll() async {
    final files = await listLogFiles();
    for (final f in files) {
      try {
        await f.writeAsString('');
      } catch (_) {}
    }
  }

  /// Opens the share sheet with every non-empty log file attached, so you
  /// can send them to yourself / paste their contents wherever you need.
  Future<void> shareAll() async {
    final files = await listLogFiles();
    final nonEmpty = <File>[];
    for (final f in files) {
      try {
        if (await f.length() > 0) nonEmpty.add(f);
      } catch (_) {}
    }
    if (nonEmpty.isEmpty) return;
    await Share.shareXFiles(
      nonEmpty.map((f) => XFile(f.path)).toList(),
      text: 'App debug logs',
    );
  }
}

/// Shorthand so call sites don't need `DebugLogger.instance.` everywhere.
void logDebug(
  String category,
  String source,
  String message, {
  Object? error,
  StackTrace? stack,
}) {
  // Fire-and-forget: logging must never block or throw into caller code.
  DebugLogger.instance.log(category, source, message, error: error, stack: stack);
}
