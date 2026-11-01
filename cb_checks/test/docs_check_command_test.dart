import 'dart:io';

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

  group('parseRenames', () {
    test('follows a file through several renames', () {
      expect(parseRenames(<String>['R100\ta.sh\tb.sh', 'M\tother.sh', 'R090\tb.sh\tc/d.sh']), <String, String>{
        'a.sh': 'c/d.sh',
        'b.sh': 'c/d.sh',
      });
    });
  });

  group('movedPath', () {
    const Set<String> files = <String>{'tools/new/run.sh', 'docs/redux/near.md', 'third_party/x/gone.sh'};
    const Map<String, String> renames = <String, String>{
      'tools/run.sh': 'tools/new/run.sh',
      'docs/near.md': 'docs/redux/near.md',
      'tools/old.sh': 'tools/later_deleted.sh',
      'one/same.sh': 'tools/new/run.sh',
      'two/same.sh': 'docs/redux/near.md',
    };

    String? moved(String token, {String file = 'docs/a.md', bool isPath = true}) {
      return movedPath(DocReference(file: file, line: 1, token: token, isPath: isPath), renames, files);
    }

    test('follows a rename git recorded', () {
      expect(moved('tools/run.sh'), 'tools/new/run.sh');
    });

    test('follows a rename from a partial path', () {
      expect(moved('run.sh'), 'tools/new/run.sh');
    });

    test('keeps a link relative while it still climbs', () {
      expect(moved('../run.sh', file: 'docs/redux/a.md'), isNull);
      expect(moved('../tools/run.sh', file: 'docs/a.md'), '../tools/new/run.sh');
    });

    test('gives the whole path once a link no longer climbs', () {
      expect(moved('../near.md', file: 'docs/redux/a.md'), 'docs/redux/near.md');
    });

    test('leaves a deleted file that has a namesake', () {
      expect(moved('tools/gone.sh'), isNull);
    });

    test('leaves a rename whose target is gone too', () {
      expect(moved('tools/old.sh'), isNull);
    });

    test('leaves a path two renames could explain', () {
      expect(moved('same.sh'), isNull);
    });

    test('leaves a folder, a link out of the repo and a code name', () {
      expect(moved('tools/run.sh/'), isNull);
      expect(moved('../../../run.sh', file: 'docs/redux/a.md'), isNull);
      expect(moved('run.sh', isPath: false), isNull);
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

    test('numbers lines as extractReferences does, keeping their endings', () {
      const String markdown = 'first\r`tools/run.sh`\r\nthird';

      expect(replaceReference(markdown, reference, 'x'), 'first\r`x`\r\nthird');
    });

    test('replaces on a last line with no ending', () {
      expect(replaceReference('first\n`tools/run.sh`', reference, 'x'), 'first\n`x`');
    });

    test('leaves a longer path alone', () {
      const String markdown = '\n`tools/run.sh.bak`\n';

      expect(replaceReference(markdown, reference, 'x'), markdown);
    });
  });

  group('docs-check --fix', () {
    late Directory repo;

    ProcessResult git(List<String> arguments) {
      final ProcessResult result = Process.runSync('git', arguments, workingDirectory: repo.path);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return result;
    }

    ProcessResult check() {
      return Process.runSync(Platform.resolvedExecutable, <String>[
        File('bin/cb_checks.dart').absolute.path,
        'docs-check',
        '--fix',
      ], workingDirectory: repo.path);
    }

    setUp(() {
      repo = Directory.systemTemp.createTempSync('docs_check');
      git(<String>['init', '-q']);
      git(<String>['config', 'user.email', 'a@example.com']);
      git(<String>['config', 'user.name', 'a']);
      File('${repo.path}/docs_check.yaml').writeAsStringSync('allowed: []\nsnapshots: []\n');
      Directory('${repo.path}/tools').createSync();
      Directory('${repo.path}/third_party').createSync();
      File('${repo.path}/tools/run.sh').writeAsStringSync('#!/bin/sh\necho run\n' * 20);
      File('${repo.path}/tools/gone.sh').writeAsStringSync('#!/bin/sh\necho gone\n' * 20);
      File('${repo.path}/third_party/gone.sh').writeAsStringSync('unrelated\n');
      File('${repo.path}/CLAUDE.md').writeAsStringSync('`tools/run.sh` and `tools/gone.sh`\n');
      git(<String>['add', '-A']);
      git(<String>['commit', '-qm', 'start']);
    });

    tearDown(() => repo.deleteSync(recursive: true));

    test('rewrites a rename and fails on a deleted file with a namesake', () {
      git(<String>['mv', 'tools/run.sh', 'tools/run2.sh']);
      git(<String>['rm', '-q', 'tools/gone.sh']);

      final ProcessResult result = check();

      expect(File('${repo.path}/CLAUDE.md').readAsStringSync(), '`tools/run2.sh` and `tools/gone.sh`\n');
      expect(result.stderr, contains('`tools/gone.sh` no longer exists'));
      expect(result.exitCode, 1);
    });

    test('passes once every reference is fixed', () {
      git(<String>['mv', 'tools/run.sh', 'tools/run2.sh']);
      git(<String>['mv', 'tools/gone.sh', 'tools/here.sh']);
      git(<String>['commit', '-qm', 'move']);

      final ProcessResult result = check();

      expect(File('${repo.path}/CLAUDE.md').readAsStringSync(), '`tools/run2.sh` and `tools/here.sh`\n');
      expect(result.exitCode, 0, reason: '${result.stderr}');
    });
  });
}
