import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Verifies that the files and code names CLAUDE.md and docs/ refer to in
/// backticks still exist, so a rename fails here instead of leaving the docs
/// pointing at nothing.
///
/// A name is only checked to appear somewhere outside the docs, as a whole word.
/// `Foo.bar` passes if both words exist, even if `bar` has moved off `Foo`.
class DocsCheckCommand extends Command<int> {
  @override
  String get name => 'docs-check';

  @override
  String get description => 'Verify the files and code names in CLAUDE.md and docs/ exist.';

  @override
  Future<int> run() async {
    // git lists only what is under the current folder, which from tool/ would
    // be no docs at all and a pass.
    Directory.current = _git(<String>['rev-parse', '--show-toplevel']).single;

    final File configFile = File('docs_check.yaml');
    if (!configFile.existsSync()) {
      stderr.writeln('docs-check needs a docs_check.yaml at the root of the repo.');
      return 1;
    }
    final DocsCheckConfig config = DocsCheckConfig.parse(configFile.readAsStringSync());

    // A file this change adds counts, so that a doc can name it before the commit,
    // and one it deleted does not, staged or not.
    final List<String> tracked = _git(<String>['ls-files', '--cached', '--others', '--exclude-standard'])
        .where((String it) => File(it).existsSync())
        .toList();
    final Set<String> files = tracked.toSet();
    final Set<String> rootFolders = files
        .where((String it) => it.contains('/'))
        .map((String it) => it.split('/').first)
        .toSet();

    final List<DocReference> references = <DocReference>[];
    for (final String path in tracked.where((String it) => _isDoc(it, config.snapshots))) {
      references.addAll(extractReferences(path, File(path).readAsStringSync(), rootFolders: rootFolders));
    }
    if (references.isEmpty) {
      stderr.writeln('docs-check found no references, so it checked nothing.');
      return 1;
    }

    final List<DocReference> stale = findStaleReferences(
      references: references,
      files: files,
      words: _sourceWords(tracked),
    );
    final List<DocReference> notAllowed = stale.where((DocReference it) => !config.allowed.contains(it.token)).toList();
    final Set<String> ignored = _gitIgnored(notAllowed.where((DocReference it) => it.isPath));
    final List<DocReference> problems = notAllowed
        .where((DocReference it) => !ignored.contains(_normalized(it)))
        .toList();

    for (final DocReference problem in problems) {
      stderr.writeln('${problem.file}:${problem.line}: `${problem.token}` no longer exists.');
    }
    if (problems.isNotEmpty) {
      return 1;
    }
    stdout.writeln('docs-check: ${references.length} references, none stale.');
    return 0;
  }
}

/// What a repo's `docs_check.yaml` says about its own docs.
class DocsCheckConfig {
  const DocsCheckConfig({required this.allowed, required this.snapshots});

  factory DocsCheckConfig.parse(String source) {
    final YamlMap yaml = loadYaml(source) as YamlMap;
    return DocsCheckConfig(
      allowed: <String>{...(yaml['allowed'] as YamlList).cast<String>()},
      snapshots: <String>{...(yaml['snapshots'] as YamlList).cast<String>()},
    );
  }

  /// Names the repo cannot show. A doc that says a name is gone goes here too,
  /// as the sentence is true because the name is missing.
  final Set<String> allowed;

  /// Docs that record one moment, and name code later deleted on purpose.
  final Set<String> snapshots;
}

/// A file or code name written in backticks in a doc.
class DocReference {
  const DocReference({required this.file, required this.line, required this.token, required this.isPath});

  final String file;
  final int line;
  final String token;
  final bool isPath;
}

bool _isDoc(String path, Set<String> snapshots) {
  return !snapshots.contains(path) && (path == 'CLAUDE.md' || (path.startsWith('docs/') && path.endsWith('.md')));
}

const Set<String> _fileExtensions = <String>{
  'arb', 'cmake', 'cpp', 'dart', 'entitlements', 'gradle', 'h', 'ico', 'iss', 'json', 'kt', 'lock', 'md', 'plist', //
  'pro', 'proto', 'py', 'rb', 'sh', 'svg', 'swift', 'txt', 'xcconfig', 'xml', 'yaml', 'yml',
};

final RegExp _backticked = RegExp(r'`([^`\s]+)`');
final RegExp _identifiers = RegExp(r'^[A-Za-z_]\w*(\.[A-Za-z_]\w*)*$');
final RegExp _codeShaped = RegExp(r'^(_\w+|[a-z]+[A-Z]\w*|[A-Z][a-z0-9]+[A-Z]\w*|[A-Z][A-Z0-9]*_[A-Z0-9_]+)$');
final RegExp _words = RegExp(r'[A-Za-z_]\w*');
final RegExp _lineSuffix = RegExp(r':\d+(-\d+)?$');

/// The checkable references in [markdown], skipping fenced code blocks, whose
/// commands and samples are not claims about the repo.
///
/// [rootFolders] are the repo's top-level folders, so that `lib/src/util/` is a
/// path while `com.cinderblockapp.mobile/timers` is a channel name.
List<DocReference> extractReferences(String file, String markdown, {required Set<String> rootFolders}) {
  final List<DocReference> references = <DocReference>[];

  bool fenced = false;
  int number = 0;
  for (final String line in const LineSplitter().convert(markdown)) {
    number++;
    if (line.trimLeft().startsWith('```')) {
      fenced = !fenced;
      continue;
    }
    if (fenced) {
      continue;
    }
    for (final RegExpMatch match in _backticked.allMatches(line)) {
      // `lib/a.dart:12` is a claim about lib/a.dart.
      final String token = match.group(1)!.replaceFirst(_lineSuffix, '');
      if (_looksLikePath(token, rootFolders)) {
        references.add(DocReference(file: file, line: number, token: token, isPath: true));
      } else if (_looksLikeName(token)) {
        references.add(DocReference(file: file, line: number, token: token, isPath: false));
      }
    }
  }

  return references;
}

bool _looksLikePath(String token, Set<String> rootFolders) {
  // Placeholders, globs, packages and flags rather than one file in this repo,
  // and paths on someone's machine.
  if (token.contains(RegExp(r'[<>*{}$%:=…]')) || token.startsWith(RegExp('[/~-]'))) {
    return false;
  }
  // `.g.dart` is a kind of file.
  if (token.startsWith('.') && !token.contains('/')) {
    return false;
  }
  final String path = token.startsWith('./') ? token.substring(2) : token;
  final String last = path.split('/').lastWhere((String it) => it.isNotEmpty, orElse: () => '');
  if (last.contains('.') && _fileExtensions.contains(last.split('.').last)) {
    return true;
  }
  return path.contains('/') && rootFolders.contains(path.split('/').first);
}

bool _looksLikeName(String token) {
  final String name = token.endsWith('()') ? token.substring(0, token.length - 2) : token;
  return _identifiers.hasMatch(name) && name.split('.').any(_codeShaped.hasMatch);
}

String _normalized(DocReference reference) {
  // `../architecture.md` is a link, so it is relative to the doc it is in.
  final String token = reference.token.startsWith('../')
      ? p.join(p.dirname(reference.file), reference.token)
      : reference.token;
  return p.normalize(token);
}

/// The [references] that name no file in [files] and no word in [words].
///
/// A path may be written relative to the section it appears in, such as
/// `persistence/entity_converters.dart`, so it also matches the end of a file's
/// path, or a folder anywhere in one.
List<DocReference> findStaleReferences({
  required List<DocReference> references,
  required Set<String> files,
  required Set<String> words,
}) {
  final Map<String, bool> known = <String, bool>{};
  bool exists(String path) {
    return known[path] ??= files.any((String file) {
      return file == path || file.endsWith('/$path') || file.startsWith('$path/') || file.contains('/$path/');
    });
  }

  return references.where((DocReference reference) {
    if (reference.isPath) {
      return !exists(_normalized(reference));
    }
    final String name = reference.token.endsWith('()')
        ? reference.token.substring(0, reference.token.length - 2)
        : reference.token;
    return !name.split('.').every(words.contains);
  }).toList();
}

/// Every word in the tracked source, leaving out the docs so that a doc cannot
/// vouch for itself, and private/, which is encrypted outside a worktree that
/// has unlocked it.
Set<String> _sourceWords(List<String> tracked) {
  const int largestFile = 4 * 1024 * 1024;
  final Set<String> words = <String>{};
  for (final String path in tracked) {
    if (path.endsWith('.md') || path.startsWith('private/') || path.startsWith('third_party/')) {
      continue;
    }
    final File file = File(path);
    if (file.lengthSync() > largestFile) {
      continue;
    }
    final List<int> bytes = file.readAsBytesSync();
    if (bytes.take(8000).contains(0)) {
      continue;
    }
    final String text = utf8.decode(bytes, allowMalformed: true);
    words.addAll(_words.allMatches(text).map((Match it) => it.group(0)!));
  }
  return words;
}

/// The [paths] git ignores: build outputs such as lib/generated/version.dart,
/// which a checkout does not have until a build writes them.
Set<String> _gitIgnored(Iterable<DocReference> references) {
  // A folder keeps its slash, as a pattern such as `lib/generated/` only matches
  // a folder and this one may not exist yet.
  // git refuses a path outside the repo, and nothing ignores one anyway.
  final Set<String> paths = references
      .where((DocReference it) => !_normalized(it).startsWith('..'))
      .map((DocReference it) => it.token.endsWith('/') ? '${_normalized(it)}/' : _normalized(it))
      .toSet();
  if (paths.isEmpty) {
    return <String>{};
  }
  return _git(
    <String>['check-ignore', '--no-index', '--', ...paths],
    allowedExitCodes: <int>{0, 1},
  ).map(p.normalize).toSet();
}

List<String> _git(List<String> arguments, {Set<int> allowedExitCodes = const <int>{0}}) {
  final ProcessResult result = Process.runSync('git', arguments);
  if (!allowedExitCodes.contains(result.exitCode)) {
    throw StateError('git ${arguments.first} failed: ${result.stderr}');
  }
  return const LineSplitter().convert(result.stdout as String);
}
