# Support

CoordKit does not currently promise an SLA or paid support channel.

For help:

- read the top-level [README](README.md) first;
- check the detailed docs under [`docs/`](docs/);
- inspect the plugin-specific notes under [`plugins/coordkit/`](plugins/coordkit/).
- search existing [GitHub issues](https://github.com/angantakpe/coordkit/issues)
  before opening a new one.

For bug reports, include:

- your host runtime;
- operating system and Bash version;
- the plugin version;
- the command or hook that failed;
- the relevant transport and enforcement modes, if known;
- the smallest reproduction you can provide.

Remove tokens, repository secrets, and sensitive ledger content from logs before
posting them. For a Codex hook approval failure, include the hook status shown by
`/hooks` and whether the plugin was installed or updated in the current session.

For security issues, use [SECURITY.md](SECURITY.md) instead of a public issue.
