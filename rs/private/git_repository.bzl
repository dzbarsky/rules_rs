load("@bazel_tools//tools/build_defs/repo:git_worker.bzl", "git_repo")

# Fork upstream git_repository to not delete the .git; we need that to derive worktrees.

def _git_repository_impl(rctx):
    git_repo(rctx, rctx.path("."))
    rctx.file("BUILD.bazel", "")
    return rctx.repo_metadata(reproducible = True)

git_repository = repository_rule(
    implementation = _git_repository_impl,
    attrs = {
        "remote": attr.string(mandatory = True),
        "commit": attr.string(mandatory = True),
        "shallow_since": attr.string(),
        "init_submodules": attr.bool(default = True),
        "recursive_init_submodules": attr.bool(default = True),
        "verbose": attr.bool(default = False),
    },
)
