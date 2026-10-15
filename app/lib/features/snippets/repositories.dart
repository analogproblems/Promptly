import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';
import 'models.dart';

/// Saved snippets, loaded from the engine's store. Mutations write through
/// and reload, so the list is always what the store holds.
class SnippetsNotifier extends Notifier<List<Snippet>> {
  @override
  List<Snippet> build() => _load();

  List<Snippet> _load() {
    try {
      final snippets = ref
          .read(engineProvider)
          .recordsList('snippets')
          .map((r) => Snippet.fromJson(jsonDecode(r.json) as Map<String, dynamic>))
          .toList();
      snippets.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      return snippets;
    } catch (_) {
      return const [];
    }
  }

  void save(Snippet snippet) {
    ref.read(engineProvider).recordPut('snippets', snippet.id, jsonEncode(snippet.toJson()));
    state = _load();
  }

  void delete(String id) {
    ref.read(engineProvider).recordDelete('snippets', id);
    state = _load();
  }

  Snippet? byId(String? id) {
    if (id == null) return null;
    for (final s in state) {
      if (s.id == id) return s;
    }
    return null;
  }
}

final snippetsProvider = NotifierProvider<SnippetsNotifier, List<Snippet>>(SnippetsNotifier.new);
