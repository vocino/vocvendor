# Versioning

Releases are tag-driven. Pushing a version tag to `main` runs the
release workflow, which packages the addon and uploads it to
CurseForge, Wago, and GitHub Releases.

## Format

Semantic versions with a `v` prefix:

- `v1.2.3` — stable release (CurseForge Release channel)
- `v1.2.3-beta.1` — Beta channel
- `v1.2.3-alpha.1` — Alpha channel

The packager detects the channel from the literal words `alpha`
and `beta` in the tag name; a plain tag is a full release.

- MAJOR: breaking changes (SavedVariables format, load behavior).
- MINOR: new features, backwards compatible.
- PATCH: bug fixes only.

## Cutting a release

1. Land the work on `main`.
2. Tag and push: `git tag v1.2.3 && git push origin v1.2.3`. From
   anywhere that cannot push tags (a cloud session, a phone), run the
   `tag` workflow instead (Actions > tag > Run workflow, on `main`,
   with the version): it creates the tag and starts the release.
3. The workflow packages, uploads, and creates the GitHub Release.

Tags are immutable: never move, delete, or re-push one. A broken
release gets a new PATCH tag, not a retag.

Cutting a tag publishes publicly and cannot be recalled — confirm
the tag name explicitly before pushing.

## Changelog

There is no hand-written changelog. The packager builds it from
commit subjects since the previous tag, so write subjects users
can read: `feat:`, `fix:`, `docs:`, `chore:` with a clear summary.

Never hand-edit `## Version` in the `.toc` file; the
`@project-version@` token is replaced with the tag at package time.
