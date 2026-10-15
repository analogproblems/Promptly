import 'package:flutter/material.dart';

import '../shell/empty_state.dart';

class SnippetsScreen extends StatelessWidget {
  const SnippetsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(title: 'Snippets'),
        Expanded(
          child: EmptyState(
            icon: Icons.code_outlined,
            title: 'No snippets yet',
            message:
                'Save the commands you type all the time. Variables like {{name}} prompt when you run them.',
            action: OutlinedButton.icon(
              onPressed: () => notYet(context, 'Snippets land in milestone 3.'),
              icon: const Icon(Icons.add),
              label: const Text('New snippet'),
            ),
          ),
        ),
      ],
    );
  }
}
