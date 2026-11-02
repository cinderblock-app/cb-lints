# cb-lints

Cinderblock's own analyzer rules and repo checks, moved out of `cb-mobile`, which pins a commit of this repo.
The rules name that app's paths and classes, so this is not a general package. It is public so that
`dart analyze` can fetch the plugin with no credentials. It has no licence.

- `cb_lints/` is the analyzer plugin. `cb-mobile` enables it in `analysis_options.yaml`, with a `git:`
  source, so its rules report in `dart analyze` and the IDE.
- `cb_checks/` holds `docs-check` and `proto-optional-check`. `cb-mobile` depends on it from `tool/`, whose
  committed lockfile pins the commit, and registers both in `tool/bin/tools.dart`.

## Changing something

CI runs `./check.sh` on every push, which also proves the plugin loads: `fixture/` breaks every rule and must draw them all. A new rule needs a violation there and a line in `check.sh`. In `cb-mobile`, move the commit in `analysis_options.yaml` and in
`tool/pubspec.yaml`, run `dart pub upgrade cb_checks` in `tool/`, and run a bare `fvm dart analyze` from the
root. A plugin rule reports only when the target is the package root: `dart analyze lib` prints no plugin
warnings at all. Pin full commit SHAs, as a tag can move.

`cb_lints/pubspec.yaml` pins `analysis_server_plugin`, `analyzer` and `analyzer_plugin` to exact versions,
which move together and follow the Dart SDK, so a Flutter bump in `cb-mobile` can need a release here first.

## Auto-fixes

- `reader_without_ignore_no_connection` has a quick fix in the IDE. Plugin fixes cannot be applied in bulk,
  so `dart fix` does not see it. It offers nothing for `yield* await x`, which throws before there is a
  stream to guard.
- `docs-check --fix` points a reference at its file when git recorded that file moving. A file with the
  same name is not enough.
- `proto-optional-check --update` records what cannot lose data: new optional fields, new messages, and
  removed required fields. It cannot approve a new required field or a dropped `optional`.

The rest need a person: naming a capability, routing a write through an Operation, moving a page and its
imports, writing a decoder, or finding what a renamed file or name is called now.

## What stays in cb-mobile

The rules name `cb-mobile`'s paths, and its `docs_check.yaml` and `optional_fields.json` hold what is
specific to it: names the docs may mention that the repo cannot show, and the proto's ledger.
