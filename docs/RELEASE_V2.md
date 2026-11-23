# Release workflows (v2)

v2 automates the whole release of Dart and Flutter packages: versions,
changelogs, tags, GitHub releases, and pub.dev uploads. Each repository
describes its packages in one file, `.github/release.yaml`, and calls the
workflows from one caller workflow.

The v1 `publish.yml` stays unchanged for the repositories that use it.

## How a release runs

1. **Prepare.** A maintainer runs the caller's `Release` workflow by hand.
   `release-pr.yml` writes the next versions and changelog sections and
   opens one release PR (branch `release/next`).
2. **Review and merge.** The maintainer edits the changelog in the PR if
   needed and merges it.
3. **Tag.** On the push to `main`, `release-tag.yml` creates a tag for each
   new version, one push per tag, plus a GitHub release with the changelog
   section.
4. **Publish.** Each tag push starts `release-publish.yml`:
   - **plan** checks that the tag matches a package tag pattern, that each
     pubspec declares the tagged version, that each changelog documents it,
     that the tagged commit is on a release branch, and that each package
     already exists on pub.dev;
   - **verify** analyzes and tests each package and runs `pre_publish`;
   - **approve** waits for a reviewer, when `approval_environment` is set;
   - **publish** handles the packages in dependency order. It skips a version
     that is already on pub.dev, so a re-run is safe. It copies each package
     out of the workspace and resolves and analyzes it against pub.dev, as a
     consumer would. It restores files that the build changed, runs
     `pub publish --dry-run` (warnings fail the release), and only then
     requests a short-lived OIDC credential, uploads, and removes the
     credential.

Steps 1 and 2 are optional. A maintainer can also raise the version and
changelog in an ordinary PR; step 3 tags it after the merge.

## Versions

The built-in versioner reads the Conventional Commits that touched each
package since its last tag:

| Commit | Version change from 1.0.0 | Before 1.0.0 |
|---|---|---|
| `feat:` | minor | patch |
| `fix:`, `perf:`, `revert:` | patch | patch |
| `!` or `BREAKING CHANGE:` | major | minor |
| `docs:`, `chore:`, `test:`, `ci:`, … | none | none |

A prerelease stays on its line: `2.0.0-beta.3` becomes `2.0.0-beta.4`. Run the
workflow with an explicit `version` to start or leave a prerelease line.
Non-conventional commit subjects are ignored, so use squash merges with
Conventional Commit PR titles (`pr-title-check.yml` enforces that).

Set `versioner: melos` to run `melos version` instead, for repositories that
already configure melos versioning.

## Configuration

```yaml
# .github/release.yaml
sdk: flutter                 # flutter or dart; default from the packages
flutter_version_file: .fvmrc # or flutter_version: 3.41.0; default stable
versioning: independent      # independent or fixed (one shared version)
versioner: builtin           # builtin or melos
release_branches: [main, 'release/*'] # default [main]
pre_publish: dart run melos run ci    # optional extra check before upload
packages:
  - path: packages/core
    tag: core-v{{version}}   # must match the pub.dev Admin tag pattern
  - path: packages/flutter
    tag: flutter-v{{version}}
    test: true               # default true
    allow_warnings: false    # accept dry-run warnings pub cannot avoid
```

The tool orders packages after the packages they depend on, so the list
order does not matter. Validate a configuration locally:

```sh
dart run <dart-actions>/tool/bin/release.dart check --root=.
```

## Caller workflow

```yaml
# .github/workflows/release.yml
name: Release

on:
  workflow_dispatch:
    inputs:
      version:
        description: Exact version. Leave empty to let the commits decide.
        required: false
        default: ''
  push:
    branches: [main]
    tags: ['v[0-9]+.[0-9]+.[0-9]+*'] # one glob per tag pattern

permissions: {}

jobs:
  prepare:
    if: github.event_name == 'workflow_dispatch'
    uses: btwld/dart-actions/.github/workflows/release-pr.yml@v2
    permissions:
      contents: write
      pull-requests: write
    with:
      version: ${{ inputs.version }}
      app_client_id: ${{ vars.RELEASE_APP_CLIENT_ID }}
    secrets:
      app_private_key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}

  tag:
    if: github.event_name == 'push' && github.ref_type == 'branch' && vars.RELEASE_APP_CLIENT_ID != ''
    uses: btwld/dart-actions/.github/workflows/release-tag.yml@v2
    permissions:
      contents: read
    with:
      app_client_id: ${{ vars.RELEASE_APP_CLIENT_ID }}
    secrets:
      app_private_key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}

  publish:
    if: github.ref_type == 'tag'
    uses: btwld/dart-actions/.github/workflows/release-publish.yml@v2
    permissions:
      contents: read
      id-token: write
    with:
      approval_environment: Release
```

When you pin a commit SHA instead of `@v2`, pass the same SHA as `tool_ref`
to each job, so the workflow and the tool come from the same commit.

## One-time setup

- **GitHub App** (once per organization): Contents and Pull requests write.
  Store its client ID as the organization variable `RELEASE_APP_CLIENT_ID`
  and its private key as the organization secret `RELEASE_APP_PRIVATE_KEY`.
  A tag pushed with `GITHUB_TOKEN` starts no workflow, so tagging needs the
  App. Without the App, `release-pr.yml` still pushes the branch and prints
  a link to open the PR, and tags can be pushed by hand.
- **pub.dev Admin** (per package): enable publishing from GitHub Actions for
  the repository with the tag pattern from the configuration. Turn on
  "Require GitHub Actions environment" with `pub.dev`. pub.dev automates
  only existing packages, so publish a new package's first version by hand.
- **Repository**: create the `pub.dev` environment, and a `Release`
  environment with required reviewers for the approval gate. Add a tag
  ruleset so that only the App and admins can create release tags.

## Rules from pub.dev and GitHub that shape the design

- pub.dev accepts automated uploads only from a workflow that a tag push
  started, so publishing cannot run from a manual dispatch.
- GitHub starts no workflow for a tag pushed with `GITHUB_TOKEN`, or for a
  push that carries more than three tags.
- While a pub.dev credential is registered, pub sends it with public reads
  too, and pub.dev answers those with HTTP 403
  ([dart-lang/pub-dev#9576](https://github.com/dart-lang/pub-dev/issues/9576)).
  The tool therefore validates without a credential and adds one only around
  each upload, with `--skip-validation`. pub.dev still validates the archive.
