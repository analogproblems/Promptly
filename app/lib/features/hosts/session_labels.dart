import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';
import 'host_colors.dart';
import 'models.dart';

/// The id of the label that comes with the app. Hosts marked production
/// before labels existed carry it, and older apps know it as `production`.
const productionLabelId = 'production';

/// A label a host's sessions carry: a coloured bar across the top with the
/// label's words, and the same colour on its tab. Labels are a synced
/// setting, so every device draws them the same.
class SessionLabel {
  const SessionLabel({required this.id, required this.name, required this.color, this.warn = false});

  factory SessionLabel.create() => SessionLabel(id: newRecordId(), name: '', color: 'blue');

  final String id;
  final String name;

  /// One of [hostColorNames], or `#RRGGBB`.
  final String color;

  /// Whether the bar shows a warning sign before the words.
  final bool warn;

  SessionLabel copyWith({String? name, String? color, bool? warn}) =>
      SessionLabel(id: id, name: name ?? this.name, color: color ?? this.color, warn: warn ?? this.warn);

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'color': color, 'warn': warn};

  factory SessionLabel.fromJson(Map<String, dynamic> j) => SessionLabel(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        color: j['color'] as String? ?? 'grey',
        warn: j['warn'] as bool? ?? false,
      );
}

/// What a vault without labels saved starts with.
const defaultSessionLabels = [
  SessionLabel(id: productionLabelId, name: 'Production', color: 'red', warn: true),
];

/// A label's colour on this theme: a named colour is tuned per theme, a
/// hex one is drawn as given.
Color labelColor(String color, Brightness brightness) {
  final hex = parseHexColor(color);
  return hex ?? hostColor(color, brightness);
}

/// `#RRGGBB` (the `#` optional) as a colour, or null.
Color? parseHexColor(String text) {
  final s = text.trim().replaceFirst('#', '');
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(s)) return null;
  return Color(0xFF000000 | int.parse(s, radix: 16));
}

/// Black or white, whichever reads better on [background].
Color inkOn(Color background) => background.computeLuminance() > 0.179 ? const Color(0xFF0E1116) : Colors.white;

/// What a session shows for its host's label, fixed when it opens.
class SessionMark {
  const SessionMark({required this.name, required this.text, required this.color, this.warn = false});

  /// The label's name, for screen readers.
  final String name;

  /// The words on the bar: the host's own, or the label's name.
  final String text;
  final String color;
  final bool warn;
}

/// The mark [host]'s sessions carry, or null when it has no label (or its
/// label has since been deleted).
SessionMark? markFor(Host host, List<SessionLabel> labels) {
  final id = host.sessionLabelId;
  if (id == null) return null;
  for (final l in labels) {
    if (l.id == id) {
      final own = host.labelText.trim();
      final name = l.name.trim().isEmpty ? 'Label' : l.name.trim();
      return SessionMark(name: name, text: own.isEmpty ? name : own, color: l.color, warn: l.warn);
    }
  }
  return null;
}

const sessionLabelsKey = 'session_labels';

/// The saved labels, in the order they were made.
class SessionLabelsNotifier extends Notifier<List<SessionLabel>> {
  @override
  List<SessionLabel> build() {
    try {
      final raw = ref.watch(engineProvider).settingGet(sessionLabelsKey);
      if (raw == null) return defaultSessionLabels;
      final list = jsonDecode(raw);
      if (list is! List) return defaultSessionLabels;
      return [
        for (final l in list)
          if (l is Map && l['id'] is String) SessionLabel.fromJson(l.cast<String, dynamic>()),
      ];
    } catch (_) {
      return defaultSessionLabels;
    }
  }

  void _write(List<SessionLabel> labels) {
    state = labels;
    try {
      ref.read(engineProvider).settingSet(sessionLabelsKey, jsonEncode([for (final l in labels) l.toJson()]));
    } catch (_) {
      // A store that cannot be written still leaves the labels live for this run.
    }
  }

  /// Add [label], or replace the one with its id.
  void save(SessionLabel label) {
    final i = state.indexWhere((l) => l.id == label.id);
    _write(i < 0 ? [...state, label] : [for (final l in state) l.id == label.id ? label : l]);
  }

  /// Hosts that carry it simply lose their bar.
  void delete(String id) => _write([for (final l in state) if (l.id != id) l]);

  SessionLabel? byId(String? id) {
    for (final l in state) {
      if (l.id == id) return l;
    }
    return null;
  }
}

final sessionLabelsProvider =
    NotifierProvider<SessionLabelsNotifier, List<SessionLabel>>(SessionLabelsNotifier.new);
