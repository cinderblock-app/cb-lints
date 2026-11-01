import 'package:test/test.dart';
import 'package:cb_checks/src/docs_check_command.dart';

const Set<String> _rootFolders = <String>{'lib', 'tools', 'assets'};

List<DocReference> _extract(String file, String markdown) {
  return extractReferences(file, markdown, rootFolders: _rootFolders);
}

List<String> _tokens(String markdown) {
  return _extract('docs/a.md', markdown).map((DocReference it) => it.token).toList();
}

List<String> _stale(String markdown, {String file = 'docs/a.md'}) {
  return findStaleReferences(
    references: _extract(file, markdown),
    files: <String>{'docs/architecture.md', 'lib/src/data/persistence/entity_converters.dart', 'tools/run.sh'},
    words: <String>{'OperationsEngine', 'isConnectionFailure', 'ConnectivityService', 'TIMERS_BUNDLE_ID'},
  ).map((DocReference it) => it.token).toList();
}

void main() {
  group('extractReferences', () {
    test('finds paths and code-shaped names', () {
      expect(_tokens('See `tools/run.sh`, `lib/src/util/`, `OperationsEngine` and `_decode()`.'), <String>[
        'tools/run.sh',
        'lib/src/util/',
        'OperationsEngine',
        '_decode()',
      ]);
    });

    test('skips plain words, commands, placeholders and globs', () {
      const String markdown =
          '`status`, `Memo`, `fvm flutter test`, `lib/src/<domain>.dart`, `**/*.g.dart`, `package:http`, '
          '`.g.dart`, `com.cinderblockapp.mobile/timers`, `Debug-dev`';

      expect(_tokens(markdown), isEmpty);
    });

    test('checks the file of a location', () {
      expect(_tokens('`tools/run.sh:12` `lib/a.dart:12-20`'), <String>['tools/run.sh', 'lib/a.dart']);
    });

    test('takes any root folder and more kinds of file', () {
      expect(_tokens('`assets/img/` `other/thing` `intl_en.arb` `a.cpp`'), <String>[
        'assets/img/',
        'intl_en.arb',
        'a.cpp',
      ]);
    });

    test('skips flags and paths on a machine', () {
      expect(_tokens('`/tmp/out.json` `~/a.json` `--file=private/a.json` `-x.json`'), isEmpty);
    });

    test('skips fenced code blocks and reports the right line', () {
      final List<DocReference> references = _extract('docs/a.md', '''
```
`tools/gone.sh`
```
`tools/run.sh`
''');

      expect(references.single.token, 'tools/run.sh');
      expect(references.single.line, 4);
    });
  });

  group('DocsCheckConfig', () {
    test('reads the names and snapshots', () {
      final DocsCheckConfig config = DocsCheckConfig.parse('''
# Firebase's API.
allowed:
  - resultsBucket
snapshots:
  - docs/triage.md
''');

      expect(config.allowed, <String>{'resultsBucket'});
      expect(config.snapshots, <String>{'docs/triage.md'});
    });
  });

  group('findStaleReferences', () {
    test('accepts existing files, folders and partial paths', () {
      expect(_stale('`tools/run.sh` `./tools/run.sh` `lib/src/data/` `persistence/entity_converters.dart`'), isEmpty);
    });

    test('accepts a link relative to its doc', () {
      expect(_stale('`../architecture.md`', file: 'docs/redux/a.md'), isEmpty);
      expect(_stale('`../gone.md`', file: 'docs/redux/a.md'), <String>['../gone.md']);
    });

    test('reports a link out of the repo as stale', () {
      expect(_stale('`../../../outside.md`', file: 'docs/redux/a.md'), <String>['../../../outside.md']);
    });

    test('does not match part of a file name', () {
      expect(_stale('`run.sh` `un.sh`'), <String>['un.sh']);
    });

    test('reports a missing file', () {
      expect(_stale('`tools/gone.sh` `code-quality.yml`'), <String>['tools/gone.sh', 'code-quality.yml']);
    });

    test('accepts known names and reports unknown ones', () {
      expect(_stale('`OperationsEngine` `TIMERS_BUNDLE_ID` `isConnectionFailure()`'), isEmpty);
      expect(_stale('`SetIsConnected` `_gone()`'), <String>['SetIsConnected', '_gone()']);
    });

    test('needs every part of a dotted name', () {
      expect(_stale('`ConnectivityService.isConnectionFailure`'), isEmpty);
      expect(_stale('`ConnectivityService.isOffline`'), <String>['ConnectivityService.isOffline']);
    });
  });

  group('movedPath', () {
    const Set<String> files = <String>{'docs/architecture.md', 'tools/new/run.sh', 'a/index.dart', 'b/index.dart'};

    DocReference reference(String token, {String file = 'docs/a.md', bool isPath = true}) {
      return DocReference(file: file, line: 1, token: token, isPath: isPath);
    }

    test('finds a file with a unique name', () {
      expect(movedPath(reference('tools/run.sh'), files), 'tools/new/run.sh');
    });

    test('keeps a link relative to its doc', () {
      expect(movedPath(reference('../run.sh', file: 'docs/redux/a.md'), files), '../../tools/new/run.sh');
    });

    test('leaves a name several files have', () {
      expect(movedPath(reference('lib/index.dart'), files), isNull);
    });

    test('leaves a name no file has', () {
      expect(movedPath(reference('tools/gone.sh'), files), isNull);
    });

    test('leaves a code name', () {
      expect(movedPath(reference('run.sh', isPath: false), files), isNull);
    });
  });

  group('replaceReference', () {
    const DocReference reference = DocReference(file: 'docs/a.md', line: 2, token: 'tools/run.sh', isPath: true);

    test('replaces only on its line, with any line number', () {
      const String markdown = '`tools/run.sh`\nSee `tools/run.sh:12` and `tools/run.sh`.\n';

      expect(
        replaceReference(markdown, reference, 'tools/new/run.sh'),
        '`tools/run.sh`\nSee `tools/new/run.sh` and `tools/new/run.sh`.\n',
      );
    });

    test('leaves a longer path alone', () {
      const String markdown = '\n`tools/run.sh.bak`\n';

      expect(replaceReference(markdown, reference, 'x'), markdown);
    });
  });
}
