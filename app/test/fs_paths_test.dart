import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/features/files/fs.dart';

void main() {
  test('Windows paths keep their drive and backslashes', () {
    final fs = LocalFs(windows: true);
    expect(fs.parent(r'C:\Users\Alice\notes.txt'), r'C:\Users\Alice');
    expect(fs.join(fs.parent(r'C:\Users\Alice\notes.txt'), 'todo.txt'), r'C:\Users\Alice\todo.txt');
    expect(fs.parent(r'C:\Users'), r'C:\');
    expect(fs.parent(r'C:\'), r'C:\');
    expect(fs.isRoot(r'C:\'), isTrue);
    expect(fs.parent('C:/Users/Alice/'), r'C:\Users');
    expect(fs.parent(r'\\nas\share\photos\a.jpg'), r'\\nas\share\photos');
    expect(fs.parent(r'\\nas\share\photos'), r'\\nas\share\');
    expect(fs.isRoot(r'\\nas\share\'), isTrue);
    expect([for (final c in fs.crumbs(r'D:\work\src')) c.path], [r'D:\', r'D:\work', r'D:\work\src']);
  });

  test('POSIX paths are unchanged', () {
    final fs = LocalFs(windows: false);
    expect(fs.parent('/home/me/a.txt'), '/home/me');
    expect(fs.parent('/home'), '/');
    expect(fs.isRoot('/'), isTrue);
    expect([for (final c in fs.crumbs('/home/me')) c.path], ['/', '/home', '/home/me']);
  });
}
