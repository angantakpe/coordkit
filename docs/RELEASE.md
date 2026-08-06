# Release process

CoordKit release hygiene is version-driven.

The release checklist is:

1. Update the plugin manifest version in `plugins/coordkit/.claude-plugin/plugin.json`.
2. Update the changelog in `plugins/coordkit/CHANGELOG.md`.
3. Update any user-facing docs that changed behavior.
4. Run the repo test suite.
5. Create a git tag that matches the released version.

Suggested tag format:

```text
coordkit-v5.2.1
```

The current workflow is:

1. Push a tag that matches `coordkit-v*`.
2. The release workflow runs the full repo test suite.
3. The release workflow publishes a GitHub release from that tag with generated
   notes.

Maintainers should still verify the artifact state before making a release
public.
