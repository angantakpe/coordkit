# Release process

CoordKit releases are version-driven and published from a reviewed tag. A
focused local check is useful change evidence; it is not proof that the entire
release is ready.

## Prepare the release

1. Choose a semantic version and update it in:
   - `plugins/coordkit/.claude-plugin/plugin.json`
   - `plugins/coordkit/.codex-plugin/plugin.json`
   - `.claude-plugin/marketplace.json` (`plugins[0].version`)
2. Add the matching section to `plugins/coordkit/CHANGELOG.md`.
3. Update user-facing documentation and shared command specs for changed
   behavior.
4. Run the test files selected for each change and record the exact commands.
5. Review the packaged plugin from a fresh install in both shipped hosts. In
   Codex, review and approve the installed hook hashes through `/hooks`; approval
   from a development cache does not prove the release artifact is trusted.
6. Confirm the repository and release notes contain no credentials, private
   paths, or internal-only links.

The tag must match the manifest version exactly:

```text
coordkit-vX.Y.Z
```

For example, version `5.4.0` uses tag `coordkit-v5.4.0` and changelog heading
`## 5.4.0`.

## Publish and verify

Pushing a `coordkit-v*` tag starts `.github/workflows/release.yml`. The release
workflow verifies the tag against both host manifests, marketplace metadata and
the changelog, then runs the package checks and tests selected from changes since
the previous release tag (the parent commit for the first release). It creates
the GitHub release only after those checks pass. The CI workflow also offers a
manual `full_suite` option; use it only when an explicit full run is wanted.
Record the selected test files in release notes. These checks do not establish
full-suite or live cross-machine coverage.

After the workflow succeeds:

1. Read back the GitHub release and confirm its tag, version, notes, and source
   commit.
2. Install from the hosted marketplace in a fresh host session and check the
   first-run command (`/bus` in Claude Code or `$coordkit bus` in Codex).
3. Confirm the repository is publicly reachable without an authenticated GitHub
   session before sharing its URL outside the project.
4. Publish launch announcements only after the public URL and install path have
   been verified. Keep returned post URLs as publication evidence.

If the workflow or fresh-install check fails, fix the source and cut a new patch
version. Do not move or reuse a published release tag.
