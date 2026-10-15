import 'package:flutter/material.dart';

import '../shell/empty_state.dart';

class SessionsScreen extends StatelessWidget {
  const SessionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(title: 'Sessions'),
        Expanded(
          child: EmptyState(
            icon: Icons.terminal_outlined,
            title: 'No live sessions',
            message:
                'Open a host and it shows up here with a live thumbnail, so you can watch a build finish from the list.',
          ),
        ),
      ],
    );
  }
}
