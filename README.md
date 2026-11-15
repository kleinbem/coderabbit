# coderabbit

Central [CodeRabbit](https://coderabbit.ai) config for every `kleinbem` repo.
CodeRabbit reads `.coderabbit.yaml` from this repo for any repo without its own.
While it exists, the web UI settings don't apply.

A repo that needs something extra adds its own `.coderabbit.yaml` with
`inheritance: true`, so it merges on top of this one instead of replacing it.
See [central configuration](https://docs.coderabbit.ai/configuration/central-configuration)
and [inheritance](https://docs.coderabbit.ai/configuration/configuration-inheritance).

CI checks the file against CodeRabbit's schema on every PR.

CodeRabbit only reads central config from a `coderabbit` repo in the same
organization, so the kleinbem-dev org has its own copy in
[kleinbem-dev/coderabbit](https://github.com/kleinbem-dev/coderabbit). Edit the
config here: on every change to main, `sync-org.yaml` opens a PR there with the
same file, and it merges once green. Never edit the org copy directly.

## Full-code reviews

`bin/cr-full-review` gets a CodeRabbit review of whole files rather than a diff:
it opens a throwaway PR whose base branch is an empty tree, so every line shows
as new. Use it in any kleinbem repo, or in a kleinbem fork of an upstream that
has no CodeRabbit (e.g. `kleinbem/nixpkgs`).

```bash
cr-full-review open pkgs/by-name/bu/buzz-cli   # paths, or nothing for the whole tree
cr-full-review wait <pr-url>                   # asks @coderabbitai once after 10 min
cr-full-review close <pr-url>                  # saves findings to ~/.cache/cr-full-review/, deletes the PR's branches
```

Fix the findings in normal PRs. The review branches are never merged.
