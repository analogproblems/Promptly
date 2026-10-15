import 'package:flutter/material.dart';

import '../shell/empty_state.dart';

class KeysScreen extends StatelessWidget {
  const KeysScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(title: 'Keys'),
        Expanded(
          child: EmptyState(
            icon: Icons.key_outlined,
            title: 'No keys yet',
            message:
                'Generate an ed25519 key in one tap, or import one you already have. Private keys stay behind your device lock.',
            action: OutlinedButton.icon(
              onPressed: () => notYet(context, 'Key generation lands in milestone 1.'),
              icon: const Icon(Icons.add),
              label: const Text('Generate key'),
            ),
          ),
        ),
      ],
    );
  }
}
