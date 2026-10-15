import '../hosts/models.dart' show newRecordId;

/// A `{{name}}` in a snippet's command, asked for when it runs.
class SnippetVariable {
  const SnippetVariable({required this.name, this.defaultValue, this.prompt = ''});

  final String name;
  final String? defaultValue;

  /// What to ask, when the name alone is not enough.
  final String prompt;

  Map<String, dynamic> toJson() => {'name': name, 'default': defaultValue, 'prompt': prompt};

  factory SnippetVariable.fromJson(Map<String, dynamic> j) => SnippetVariable(
        name: j['name'] as String? ?? '',
        defaultValue: j['default'] as String?,
        prompt: j['prompt'] as String? ?? '',
      );
}

/// A saved command. Field names are the vault's; see
/// `engine/crates/promptly-vault/src/model.rs`.
class Snippet {
  Snippet({
    required this.id,
    required this.label,
    required this.command,
    this.tags = const [],
    this.variables = const [],
  });

  factory Snippet.create() => Snippet(id: newRecordId(), label: '', command: '');

  final String id;
  final String label;
  final String command;
  final List<String> tags;
  final List<SnippetVariable> variables;

  static final _variable = RegExp(r'\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}');

  /// The variable names a command mentions, each once, in order.
  static List<String> variableNames(String command) {
    final names = <String>[];
    for (final m in _variable.allMatches(command)) {
      final name = m.group(1)!;
      if (!names.contains(name)) names.add(name);
    }
    return names;
  }

  bool get hasVariables => variableNames(command).isNotEmpty;

  /// The command with its variables filled in. A name with no value keeps
  /// its default, or stays as written.
  String render(Map<String, String> values) => command.replaceAllMapped(_variable, (m) {
        final name = m.group(1)!;
        final given = values[name];
        if (given != null) return given;
        for (final v in variables) {
          if (v.name == name && v.defaultValue != null) return v.defaultValue!;
        }
        return m.group(0)!;
      });

  /// The first line of the command, for lists.
  String get firstLine {
    final line = command.trim().split('\n').first;
    return command.trim().contains('\n') ? '$line …' : line;
  }

  Snippet copyWith({String? label, String? command, List<String>? tags, List<SnippetVariable>? variables}) => Snippet(
        id: id,
        label: label ?? this.label,
        command: command ?? this.command,
        tags: tags ?? this.tags,
        variables: variables ?? this.variables,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'command': command,
        'tags': tags,
        'variables': [for (final v in variables) v.toJson()],
      };

  factory Snippet.fromJson(Map<String, dynamic> j) => Snippet(
        id: j['id'] as String,
        label: j['label'] as String? ?? '',
        command: j['command'] as String? ?? '',
        tags: (j['tags'] as List?)?.cast<String>() ?? const [],
        variables: [
          for (final v in (j['variables'] as List?) ?? const [])
            if (v is Map) SnippetVariable.fromJson(v.cast<String, dynamic>()),
        ],
      );
}
