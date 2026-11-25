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
