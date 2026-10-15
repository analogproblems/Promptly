import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';

/// The port forwards of a live session, each with a switch. Opens from the
/// session bar.
Future<void> showForwardsSheet(BuildContext context, WidgetRef ref, int sessionId) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _ForwardsSheet(engine: ref.read(engineProvider), sessionId: sessionId),
  );
}

class _ForwardsSheet extends StatefulWidget {
  const _ForwardsSheet({required this.engine, required this.sessionId});

  final Engine engine;
  final int sessionId;

  @override
  State<_ForwardsSheet> createState() => _ForwardsSheetState();
}

class _ForwardsSheetState extends State<_ForwardsSheet> {
  List<SshForwardStatus> _forwards = const [];
  String? _error;
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    try {
      _forwards = widget.engine.sshForwards(widget.sessionId);
      _error = null;
    } catch (e) {
      _error = e is String ? e : e.toString();
    }
    if (mounted) setState(() {});
  }

  Future<void> _set(int index, bool on) async {
    setState(() => _busy.add(index));
    try {
      await widget.engine.sshForwardSet(widget.sessionId, index, on);
    } catch (_) {
      // The status carries the reason.
    }
    _busy.remove(index);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Port forwards', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: t.text)),
            const SizedBox(height: 4),
            Text(
              'Local forwards open a port on this device. Remote ones open a port on the server. '
              'SOCKS lets any program pick its own destination through the server.',
              style: TextStyle(fontSize: 12, color: t.muted),
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Text(_error!, style: TextStyle(color: t.danger, fontSize: 13))
            else if (_forwards.isEmpty)
              Text('This host has no port forwards. Add some in the host editor.',
                  style: TextStyle(color: t.muted, fontSize: 13))
            else
              for (final f in _forwards)
                SwitchListTile(
                  key: Key('forward-switch-${f.index}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(_describe(f), style: monoStyle(context, size: 13, color: t.text)),
                  subtitle: Text(
                    f.error ?? (f.active ? _activeNote(f) : 'Off'),
                    style: TextStyle(fontSize: 12, color: f.error != null ? t.danger : t.muted),
                  ),
                  value: f.active,
                  onChanged: _busy.contains(f.index) ? null : (v) => _set(f.index, v),
                ),
          ],
        ),
      ),
    );
  }

  String _describe(SshForwardStatus s) {
    final f = s.forward;
    return switch (f.kind) {
      SshForwardKind.local => '${f.bindPort} → ${f.targetHost}:${f.targetPort}',
      SshForwardKind.remote => 'server ${f.bindPort} → ${f.targetHost}:${f.targetPort}',
      SshForwardKind.dynamic_ => 'SOCKS on ${f.bindPort}',
    };
  }

  String _activeNote(SshForwardStatus s) => switch (s.forward.kind) {
        SshForwardKind.local => 'Listening on port ${s.boundPort} here',
        SshForwardKind.remote => 'The server is listening on port ${s.boundPort}',
        SshForwardKind.dynamic_ => 'SOCKS5 proxy on 127.0.0.1:${s.boundPort}',
      };
}
