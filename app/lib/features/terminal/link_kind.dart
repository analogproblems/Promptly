/// What a link under the pointer is, which decides what clicking it does:
/// a web link opens, and anything else is copied. A file path or address
/// means something on the other machine, and a link of any other kind
/// (`file:`, `ssh:`, an app's own) could make this computer do something
/// the server chose.
enum LinkKind { web, path, address, other }

final _web = RegExp(r'^(https?://|mailto:)', caseSensitive: false);

final _address = RegExp(r'^\d{1,3}(\.\d{1,3}){3}(:\d+)?$');

/// The kind of a link the engine found, from its text. The engine finds
/// web links (always with a scheme, like `https:`), absolute or `~/` paths
/// and IPv4 addresses.
LinkKind linkKind(String link) {
  if (link.startsWith('/') || link.startsWith('~/')) return LinkKind.path;
  if (_address.hasMatch(link)) return LinkKind.address;
  return _web.hasMatch(link) ? LinkKind.web : LinkKind.other;
}

/// What the menu calls copying it.
String copyLabel(LinkKind kind) => switch (kind) {
      LinkKind.web || LinkKind.other => 'Copy link',
      LinkKind.path => 'Copy path',
      LinkKind.address => 'Copy address',
    };
