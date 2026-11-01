# cb-lints

Cinderblock's analyzer rules and repo checks, moved out of `cb-mobile`, which pins a tag of this repo.

- `cb_lints/` is the analyzer plugin. `cb-mobile` enables it in `analysis_options.yaml`, with a `git:`
  source, so its rules report in `dart analyze` and the IDE.
- `cb_checks/` is a command line tool with `docs-check` and `proto-optional-check`. `cb-mobile` runs them
  through `tools/cb_checks.sh`, which reads the same tag.

## Changing something

Run `./check.sh`, which is also the only thing that tests this repo. Tag the commit, then move the tag in
`cb-mobile`'s `analysis_options.yaml`, and run a bare `dart analyze` from its root. A plugin rule reports
only when the target is the package root: `dart analyze lib` prints no plugin warnings at all.

`cb_lints/pubspec.yaml` pins `analysis_server_plugin`, `analyzer` and `analyzer_plugin` to exact versions,
which move together and follow the Dart SDK, so a Flutter bump in `cb-mobile` can need a release here first.

## Auto-fixes

- `reader_without_ignore_no_connection` has a quick fix in the IDE. Plugin fixes cannot be applied in bulk,
  so `dart fix` does not see it.
- `docs-check --fix` points a reference at its file when exactly one file has that name.
- `proto-optional-check --update` records new optional fields.

The rest need a person: naming a capability, routing a write through an Operation, moving a page and its
imports, writing a decoder, or finding what a renamed file or name is called now.

## What stays in cb-mobile

The rules name `cb-mobile`'s paths, and its `docs_check.yaml` and `optional_fields.json` hold what is
specific to it: names the docs may mention that the repo cannot show, and the proto's ledger.
