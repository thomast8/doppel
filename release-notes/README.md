# Doppel release notes

Every Doppel release must have a Markdown file named for its version, for
example `release-notes/1.2.0.md`. Write short, user-facing notes that explain
what changed and any action the user needs to take.

`just package-release VERSION BUILD` fails when that file is missing or blank.
It copies the notes beside the release archive using Sparkle's required matching
basename, then verifies that the generated appcast embeds them.

Use the generated Markdown as the matching GitHub release notes, and upload the
archive:

- `Doppel-VERSION-macOS.zip`

The packaging command embeds the Markdown in the signed appcast. The updater
therefore does not depend on the standalone Markdown file being hosted.

The Markdown file can instead be supplied with `DOPPEL_RELEASE_NOTES` when a
release needs to use a source file outside this directory.
