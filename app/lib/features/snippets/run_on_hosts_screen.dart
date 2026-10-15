import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../hosts/host_colors.dart';
import '../hosts/models.dart';
import '../hosts/repositories.dart';
import '../sessions/session_manager.dart';
import '../settings/settings_providers.dart';
import 'repositories.dart';
import 'run_snippet.dart';

/// Pick hosts, fill the variables once, run the snippet on each with its
/// stored login, and read what every host printed.
class RunOnHostsScreen extends ConsumerStatefulWidget {
  const RunOnHostsScreen({super.key, required this.snippetId});

  final String snippetId;

  @override
  ConsumerState<RunOnHostsScreen> createState() => _RunOnHostsScreenState();
}

class _HostResult {
  bool running = true;
  SshExecResult? result;

  /// A reason it could not even start, from the host's own settings.
  String? problem;
}

class _RunOnHostsScreenState extends ConsumerState<RunOnHostsScreen> {
  final Set<String> _selected = {};
  final Map<String, _HostResult> _results = {};
  String? _command;

  bool get _running => _results.values.any((r) => r.running);

  Future<void> _run() async {
    final snippet = ref.read(snippetsProvider.notifier).byId(widget.snippetId);
    if (snippet == null) return;
    final values = await askVariables(context, snippet);
    if (values == null || !mounted) return;
    final command = snippet.render(values);
    final hosts = [for (final h in ref.read(hostsProvider)) if (_selected.contains(h.id)) h];
    setState(() {
      _command = command;
      _results.clear();
      for (final h in hosts) {
        _results[h.id] = _HostResult();
      }
    });
    for (final h in hosts) {
      _runOne(h, command);
    }
  }

  Future<void> _runOne(Host host, String command) async {
    final manager = ref.read(sessionManagerProvider.notifier);
    final plan = manager.requestFor(host, theme: terminalThemeFor(ref, context));
    final slot = _results[host.id]!;
    if (plan.request == null) {
      setState(() {
        slot.running = false;
        slot.problem = plan.problem ?? 'This host cannot be used.';
      });
      return;
    }
    SshExecResult result;
    try {
      result = await ref.read(engineProvider).sshExec(plan.request!, command, 60);
    } catch (e) {
      result = SshExecResult(output: '', exitCode: null, timedOut: false, error: e is String ? e : e.toString());
    }
    if (!mounted) return;
    setState(() {
      slot.running = false;
      slot.result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final snippet = ref.watch(snippetsProvider.select((s) => s.where((x) => x.id == widget.snippetId).firstOrNull));
    final hosts = ref.watch(hostsProvider);
    final brightness = Theme.of(context).brightness;
    if (snippet == null) {
      return Center(child: Text('This snippet is gone.', style: TextStyle(color: t.muted)));
    }
    final allSelected = hosts.isNotEmpty && _selected.length == hosts.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 56,
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back',
                onPressed: () => context.go('/snippets'),
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Run ${snippet.label} on hosts',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: t.text),
                ),
              ),
              FilledButton.icon(
                key: const Key('run-on-hosts-go'),
                onPressed: _selected.isEmpty || _running ? null : _run,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: Text(_selected.isEmpty ? 'Run' : 'Run on ${_selected.length}'),
              ),
            ],
          ),
        ),
        Expanded(
          child: hosts.isEmpty
              ? Center(child: Text('No saved hosts yet.', style: TextStyle(color: t.muted)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                  children: [
                    Text(_command ?? snippet.command, style: monoStyle(context, size: 12, color: t.muted)),
                    const SizedBox(height: 8),
                    Text(
                      'Each host runs it with its stored login, with no terminal, and its output shows here. '
                      'Hosts that ask for a login each time, or whose key is not trusted yet, say so.',
                      style: TextStyle(fontSize: 12, color: t.muted),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        key: const Key('run-select-all'),
                        onPressed: () => setState(() {
                          if (allSelected) {
                            _selected.clear();
                          } else {
                            _selected.addAll(hosts.map((h) => h.id));
                          }
                        }),
                        child: Text(allSelected ? 'Select none' : 'Select all'),
                      ),
                    ),
                    for (final h in hosts) ...[
                      CheckboxListTile(
                        key: Key('run-host-${h.id}'),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _selected.contains(h.id),
                        onChanged: _running
                            ? null
                            : (v) => setState(() => v == true ? _selected.add(h.id) : _selected.remove(h.id)),
                        title: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: hostColor(h.color ?? defaultColorFor(h.label), brightness),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                            Text(h.label, style: monoStyle(context, size: 14, weight: FontWeight.w600, color: t.text)),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(h.endpoint, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 12, color: t.muted)),
                            ),
                          ],
                        ),
                      ),
                      if (_results[h.id] case final r?) _ResultCard(result: r),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final _HostResult result;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final r = result.result;
    final String status;
    final Color statusColor;
    if (result.running) {
      status = 'Running…';
      statusColor = t.muted;
    } else if (result.problem != null) {
      status = result.problem!;
      statusColor = t.danger;
    } else if (r?.error != null) {
      status = r!.error!;
      statusColor = t.danger;
    } else if (r?.timedOut == true) {
      status = 'Still running after 60 seconds; this is what it printed by then.';
      statusColor = t.warning;
    } else {
      final code = r?.exitCode;
      status = code == null ? 'Ended' : 'Exit $code';
      statusColor = code == 0 ? t.accent : t.warning;
    }
    final output = r?.output ?? '';
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 0, 0, 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(PromptlyTokens.controlRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (result.running)
                SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: t.muted))
              else
                Icon(
                  statusColor == t.danger ? Icons.error_outline : Icons.check_circle_outline,
                  size: 14,
                  color: statusColor,
                ),
              const SizedBox(width: 6),
              Expanded(child: Text(status, style: TextStyle(fontSize: 12, color: statusColor))),
            ],
          ),
          if (output.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(output.trimRight(), style: monoStyle(context, size: 12, color: t.text)),
          ],
        ],
      ),
    );
  }
}
