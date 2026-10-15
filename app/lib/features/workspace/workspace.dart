import 'package:flutter/widgets.dart' show Axis, Rect;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sessions/session_manager.dart';

/// The desktop layout of sessions: tabs across the top, each a tree of
/// panes split left-right or top-bottom, every leaf holding one session
/// or nothing yet. Sessions themselves live in the session manager; a
/// pane only points at one.
sealed class PaneNode {
  PaneNode(this.id);

  final int id;
}

class PaneLeaf extends PaneNode {
  PaneLeaf(super.id, {this.sessionId});

  int? sessionId;
}

class PaneSplit extends PaneNode {
  PaneSplit(super.id, {required this.axis, required this.first, required this.second, this.ratio = 0.5});

  /// Horizontal: `first` is on the left. Vertical: `first` is on top.
  Axis axis;
  PaneNode first;
  PaneNode second;

  /// How much of the space `first` takes, 0.15 to 0.85.
  double ratio;
}

class WorkspaceTab {
  WorkspaceTab(this.id, this.root, this.focusedLeaf);

  final int id;
  PaneNode root;
  int focusedLeaf;

  /// Every leaf, left to right and top to bottom.
  List<PaneLeaf> get leaves => _collect(root, []);

  static List<PaneLeaf> _collect(PaneNode n, List<PaneLeaf> out) {
    switch (n) {
      case PaneLeaf():
        out.add(n);
      case PaneSplit():
        _collect(n.first, out);
        _collect(n.second, out);
    }
    return out;
  }

  PaneLeaf? leaf(int id) {
    for (final l in leaves) {
      if (l.id == id) return l;
    }
    return null;
  }

  PaneLeaf get focused => leaf(focusedLeaf) ?? leaves.first;

  /// Where each leaf sits, in a unit square, for moving focus by direction.
  Map<int, Rect> rects() {
    final out = <int, Rect>{};
    void walk(PaneNode n, Rect r) {
      switch (n) {
        case PaneLeaf():
          out[n.id] = r;
        case PaneSplit():
          if (n.axis == Axis.horizontal) {
            final w = r.width * n.ratio;
            walk(n.first, Rect.fromLTWH(r.left, r.top, w, r.height));
            walk(n.second, Rect.fromLTWH(r.left + w, r.top, r.width - w, r.height));
          } else {
            final h = r.height * n.ratio;
            walk(n.first, Rect.fromLTWH(r.left, r.top, r.width, h));
            walk(n.second, Rect.fromLTWH(r.left, r.top + h, r.width, r.height - h));
          }
      }
    }
    walk(root, const Rect.fromLTWH(0, 0, 1, 1));
    return out;
  }
}

class WorkspaceState {
  const WorkspaceState({required this.tabs, required this.current, required this.hostsPanel, required this.version});

  final List<WorkspaceTab> tabs;
  final int current;

  /// The hosts panel beside the panes, for dragging hosts in.
  final bool hostsPanel;

  /// Bumped on every change, since the trees are edited in place.
  final int version;

  WorkspaceTab? get currentTab => current >= 0 && current < tabs.length ? tabs[current] : null;

  WorkspaceState copyWith({List<WorkspaceTab>? tabs, int? current, bool? hostsPanel}) => WorkspaceState(
        tabs: tabs ?? this.tabs,
        current: current ?? this.current,
        hostsPanel: hostsPanel ?? this.hostsPanel,
        version: version + 1,
      );
}

enum PaneDirection { left, right, up, down }

class WorkspaceNotifier extends Notifier<WorkspaceState> {
  int _nextId = 1;

  @override
  WorkspaceState build() {
    // A session closed anywhere leaves its pane empty.
    ref.listen(sessionManagerProvider, (_, sessions) {
      final alive = {for (final e in sessions) e.id};
      var changed = false;
      for (final tab in state.tabs) {
        for (final leaf in tab.leaves) {
          if (leaf.sessionId != null && !alive.contains(leaf.sessionId)) {
            leaf.sessionId = null;
            changed = true;
          }
        }
      }
      if (changed) state = state.copyWith();
    });
    return WorkspaceState(tabs: [_emptyTab()], current: 0, hostsPanel: false, version: 0);
  }

  WorkspaceTab _emptyTab({int? sessionId}) {
    final leaf = PaneLeaf(_nextId++, sessionId: sessionId);
    return WorkspaceTab(_nextId++, leaf, leaf.id);
  }

  void _bump() => state = state.copyWith();

  // ---- Tabs ----------------------------------------------------------------

  WorkspaceTab newTab({int? sessionId}) {
    final tab = _emptyTab(sessionId: sessionId);
    state = state.copyWith(tabs: [...state.tabs, tab], current: state.tabs.length);
    return tab;
  }

  void selectTab(int index) {
    if (index < 0 || index >= state.tabs.length) return;
    state = state.copyWith(current: index);
  }

  void nextTab() => selectTab((state.current + 1) % state.tabs.length);

  void previousTab() => selectTab((state.current - 1 + state.tabs.length) % state.tabs.length);

  /// Close a tab and every session in it. The last tab is emptied, not
  /// removed, so there is always somewhere to work.
  void closeTab(int tabId) {
    final index = state.tabs.indexWhere((t) => t.id == tabId);
    if (index < 0) return;
    final manager = ref.read(sessionManagerProvider.notifier);
    for (final leaf in state.tabs[index].leaves) {
      if (leaf.sessionId != null) manager.close(leaf.sessionId!);
    }
    if (state.tabs.length == 1) {
      state = state.copyWith(tabs: [_emptyTab()], current: 0);
      return;
    }
    final tabs = [...state.tabs]..removeAt(index);
    final current = state.current > index || state.current >= tabs.length ? state.current - 1 : state.current;
    state = state.copyWith(tabs: tabs, current: current.clamp(0, tabs.length - 1));
  }

  // ---- Showing sessions ----------------------------------------------------

  /// Bring a session on screen: where it already is, else in the focused
  /// pane if that one is empty, else in a new tab.
  void showSession(int sessionId) {
    for (var i = 0; i < state.tabs.length; i++) {
      for (final leaf in state.tabs[i].leaves) {
        if (leaf.sessionId == sessionId) {
          state.tabs[i].focusedLeaf = leaf.id;
          state = state.copyWith(current: i);
          return;
        }
      }
    }
    final tab = state.currentTab;
    final focused = tab?.focused;
    if (tab != null && focused != null && focused.sessionId == null) {
      focused.sessionId = sessionId;
      _bump();
      return;
    }
    newTab(sessionId: sessionId);
  }

  /// Put a session in a particular pane, replacing nothing: the pane must
  /// be empty, or the session goes to a new tab.
  void attachSession(int leafId, int sessionId) {
    for (var i = 0; i < state.tabs.length; i++) {
      final leaf = state.tabs[i].leaf(leafId);
      if (leaf == null) continue;
      if (leaf.sessionId != null) {
        newTab(sessionId: sessionId);
        return;
      }
      leaf.sessionId = sessionId;
      state.tabs[i].focusedLeaf = leafId;
      state = state.copyWith(current: i);
      return;
    }
    newTab(sessionId: sessionId);
  }

  // ---- Panes ---------------------------------------------------------------

  /// Split the focused pane; the new, empty pane takes the focus. Returns
  /// the new pane's id.
  int? split(Axis axis) {
    final tab = state.currentTab;
    if (tab == null) return null;
    final target = tab.focused;
    final fresh = PaneLeaf(_nextId++);
    final split = PaneSplit(_nextId++, axis: axis, first: target, second: fresh);
    if (tab.root == target) {
      tab.root = split;
    } else {
      _replace(tab.root, target, split);
    }
    tab.focusedLeaf = fresh.id;
    _bump();
    return fresh.id;
  }

  /// Change how a split shares its space.
  void setRatio(int splitId, double ratio) {
    for (final tab in state.tabs) {
      final s = _findSplit(tab.root, splitId);
      if (s != null) {
        s.ratio = ratio.clamp(0.15, 0.85);
        _bump();
        return;
      }
    }
  }

  /// Close the focused pane and its session. The tab closes with its last
  /// pane.
  void closeFocusedPane() {
    final tab = state.currentTab;
    if (tab == null) return;
    final target = tab.focused;
    if (target.sessionId != null) {
      ref.read(sessionManagerProvider.notifier).close(target.sessionId!);
      target.sessionId = null;
    }
    if (tab.root == target) {
      closeTab(tab.id);
      return;
    }
    final parent = _parentOf(tab.root, target)!;
    final sibling = parent.first == target ? parent.second : parent.first;
    if (tab.root == parent) {
      tab.root = sibling;
    } else {
      _replace(tab.root, parent, sibling);
    }
    tab.focusedLeaf = WorkspaceTab._collect(sibling, []).first.id;
    _bump();
  }

  void focusLeaf(int leafId) {
    final tab = state.currentTab;
    if (tab == null || tab.leaf(leafId) == null || tab.focusedLeaf == leafId) return;
    tab.focusedLeaf = leafId;
    _bump();
  }

  /// Move focus to the nearest pane in a direction.
  void focusNeighbour(PaneDirection direction) {
    final tab = state.currentTab;
    if (tab == null) return;
    final rects = tab.rects();
    final from = rects[tab.focusedLeaf];
    if (from == null) return;
    int? best;
    double bestDistance = double.infinity;
    for (final e in rects.entries) {
      if (e.key == tab.focusedLeaf) continue;
      final r = e.value;
      final bool beyond;
      final bool overlaps;
      switch (direction) {
        case PaneDirection.left:
          beyond = r.right <= from.left + 1e-6;
          overlaps = r.bottom > from.top && r.top < from.bottom;
        case PaneDirection.right:
          beyond = r.left >= from.right - 1e-6;
          overlaps = r.bottom > from.top && r.top < from.bottom;
        case PaneDirection.up:
          beyond = r.bottom <= from.top + 1e-6;
          overlaps = r.right > from.left && r.left < from.right;
        case PaneDirection.down:
          beyond = r.top >= from.bottom - 1e-6;
          overlaps = r.right > from.left && r.left < from.right;
      }
      if (!beyond || !overlaps) continue;
      final d = (r.center - from.center).distance;
      if (d < bestDistance) {
        bestDistance = d;
        best = e.key;
      }
    }
    if (best != null) focusLeaf(best);
  }

  void toggleHostsPanel() => state = state.copyWith(hostsPanel: !state.hostsPanel);

  // ---- Tree helpers --------------------------------------------------------

  static void _replace(PaneNode root, PaneNode old, PaneNode fresh) {
    if (root is! PaneSplit) return;
    if (root.first == old) {
      root.first = fresh;
    } else if (root.second == old) {
      root.second = fresh;
    } else {
      _replace(root.first, old, fresh);
      _replace(root.second, old, fresh);
    }
  }

  static PaneSplit? _parentOf(PaneNode root, PaneNode child) {
    if (root is! PaneSplit) return null;
    if (root.first == child || root.second == child) return root;
    return _parentOf(root.first, child) ?? _parentOf(root.second, child);
  }

  static PaneSplit? _findSplit(PaneNode root, int id) {
    if (root is! PaneSplit) return null;
    if (root.id == id) return root;
    return _findSplit(root.first, id) ?? _findSplit(root.second, id);
  }
}

final workspaceProvider = NotifierProvider<WorkspaceNotifier, WorkspaceState>(WorkspaceNotifier.new);

/// The session in the focused pane of the current tab, if any.
final focusedSessionProvider = Provider<SessionEntry?>((ref) {
  final ws = ref.watch(workspaceProvider);
  final id = ws.currentTab?.focused.sessionId;
  if (id == null) return null;
  for (final e in ref.watch(sessionManagerProvider)) {
    if (e.id == id) return e;
  }
  return null;
});

/// Bumped when something (the menu, the palette) asks the focused session
/// to open its search bar.
final findRequestProvider = NotifierProvider<FindRequestNotifier, int>(FindRequestNotifier.new);

class FindRequestNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void request() => state++;
}
