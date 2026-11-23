# Private btwld dependencies

A composite action that lets CI fetch private btwld repositories, such as a
`git:` dependency in `pubspec.yaml`. It mints a short-lived installation token
from the `btwld-ci` GitHub App, limited to Contents read on the repositories
you name, and points git at it. `dart pub get` and `flutter pub get` then work
without a personal access token.

## Usage

```yaml
- uses: actions/checkout@v4

- name: Read private dependencies
  uses: btwld/dart-actions/private-deps@main
  with:
    app-id: ${{ vars.CI_APP_ID }}
    private-key: ${{ secrets.CI_APP_PRIVATE_KEY }}
    repositories: glitch

- run: dart pub get --enforce-lockfile
```

List every private repository the job resolves, including transitive ones:

```yaml
    repositories: |
      jam
      stargate-dart
```

## Setup

The org admin does this once:

1. The `btwld-ci` App has Contents read only and no webhook.
2. Install it on each private repository that CI fetches. A repository that is
   not in the installation cannot be named in `repositories`.
3. Org variable `CI_APP_ID` and org secret `CI_APP_PRIVATE_KEY` are visible
   only to the repositories whose CI fetches private dependencies.

## Limits

- GitHub does not pass secrets to pull requests from forks, so those runs
  cannot read private repositories. The action fails with a clear message.
- Give the secret only to private consumer repositories. A public repository
  that holds it exposes private code to anyone who can change its workflows.
- The token is revoked when the job ends. The git header stays in the global
  config until then; a job that later runs untrusted code can remove it with
  `git config --global --unset-all http.https://github.com/btwld/<repo>.git.extraheader`.
