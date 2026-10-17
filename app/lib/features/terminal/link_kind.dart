/// What a link under the pointer is, which decides what clicking it does:
/// a web link opens, a file path or an address is copied.
enum LinkKind { web, path, address }

final _address = RegExp(r'^\d{1,3}(\.\d{1,3}){3}(:\d+)?$');

/// The kind of a link the engine found, from its text. The engine finds
/// web links (always with a scheme, like `https:`), absolute or `~/` paths
/// and IPv4 addresses.
LinkKind linkKind(String link) {
  if (link.startsWith('/') || link.startsWith('~/')) return LinkKind.path;
  if (_address.hasMatch(link)) return LinkKind.address;
  return LinkKind.web;
}

/// What the menu calls copying it.
String copyLabel(LinkKind kind) => switch (kind) {
      LinkKind.web => 'Copy link',
      LinkKind.path => 'Copy path',
      LinkKind.address => 'Copy address',
    };
