import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../shell/empty_state.dart';

class HostsScreen extends ConsumerStatefulWidget {
  const HostsScreen({super.key});

  @override
  ConsumerState<HostsScreen> createState() => _HostsScreenState();
}

class _HostsScreenState extends ConsumerState<HostsScreen> {
  final _search = TextEditingController();
  EndpointParse? _quickConnect;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    // Anything with an @ is a quick-connect attempt; the engine decides if it is valid.
    final parsed =
        text.contains('@') ? ref.read(engineProvider).parseEndpoint(text) : null;
    setState(() => _quickConnect = parsed);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => notYet(context, 'The host editor lands in milestone 1.'),
        tooltip: 'Add host',
        child: const Icon(Icons.add),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Hosts',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: t.muted, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text('Sync not set up', style: TextStyle(fontSize: 12, color: t.muted)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: TextField(
              controller: _search,
              onChanged: _onChanged,
              style: monoStyle(context, size: 14),
              decoration: InputDecoration(
                hintText: 'Search, or user@host to connect',
                prefixIcon: Icon(Icons.search, color: t.muted),
              ),
            ),
          ),
          if (_quickConnect case final EndpointOk ok)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Card(
                child: ListTile(
                  leading: Icon(Icons.bolt_outlined, color: t.accent),
                  title: Text('Connect to ${ok.display}', style: monoStyle(context, size: 14)),
                  subtitle: Text('Port ${ok.port} · parsed by the engine'),
                  trailing: FilledButton(
                    onPressed: () => notYet(context, 'Connecting lands in milestone 1.'),
                    child: const Text('Connect'),
                  ),
                ),
              ),
            ),
          if (_quickConnect case final EndpointError err)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(err.message, style: TextStyle(color: t.danger, fontSize: 13)),
            ),
          Expanded(
            child: EmptyState(
              icon: Icons.dns_outlined,
              title: 'No hosts yet',
              message:
                  'Add a host, or type user@host above to connect straight away. Hosts you add will sync to your other devices once the vault is set up.',
              action: OutlinedButton.icon(
                onPressed: () => notYet(context, 'The host editor lands in milestone 1.'),
                icon: const Icon(Icons.add),
                label: const Text('Add host'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
