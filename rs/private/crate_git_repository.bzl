load("@bazel_tools//tools/build_defs/repo:utils.bzl", "patch")
load(":repository_utils.bzl", "common_attrs", "generate_build_file")
load(":toml2json.bzl", "run_toml2json")

_INHERITABLE_FIELDS = [
    "version",
    "edition",
    "description",
    "homepage",
    "repository",
    "license",
    # TODO(zbarsky): Do we need to fixup the path for readme and license_file?
    "license_file",
    "rust_version",
    "readme",
]

def _crate_git_repository_implementation(rctx):
    repo_dir = rctx.path(rctx.attr.git_repo_label).dirname
    crate_dir = repo_dir.get_child(rctx.attr.strip_prefix) if rctx.attr.strip_prefix else repo_dir
    if not crate_dir.exists:
        fail("strip_prefix at {} does not exist in repo".format(rctx.attr.strip_prefix))

    target_dir = rctx.path(".")
    for item in crate_dir.readdir():
        rctx.symlink(item, target_dir.get_child(item.basename))

    # TODO(zbarsky): Will these patches properly follow the symlinks? Is that even correct?
    # Maybe we should do a clone from the on-disk repo..
    patch(rctx)

    cargo_toml = run_toml2json(rctx, "Cargo.toml")

    if rctx.attr.strip_prefix:
        workspace_cargo_toml = run_toml2json(rctx, repo_dir.get_child(rctx.attr.workspace_cargo_toml))
        workspace_package = workspace_cargo_toml.get("workspace", {}).get("package")
        if workspace_package:
            crate_package = cargo_toml["package"]
            for field in _INHERITABLE_FIELDS:
                value = crate_package.get(field)
                if type(value) == "dict" and value.get("workspace") == True:
                    crate_package[field] = workspace_package.get(field)

    rctx.file("BUILD.bazel", generate_build_file(rctx, cargo_toml))

    return rctx.repo_metadata(reproducible = True)

crate_git_repository = repository_rule(
    implementation = _crate_git_repository_implementation,
    attrs = {
        "git_repo_label": attr.label(),
        "remote": attr.string(
            mandatory = True,
            doc = "The URI of the remote Git repository",
        ),
        "commit": attr.string(
            mandatory = True,
            doc =
                "specific commit to be checked out." +
                " Precisely one of branch, tag, or commit must be specified.",
        ),
        "shallow_since": attr.string(),
        "init_submodules": attr.bool(
            default = True,
            doc = "Whether to clone submodules in the repository.",
        ),
        "recursive_init_submodules": attr.bool(
            default = True,
            doc = "Whether to clone submodules recursively in the repository.",
        ),
        "verbose": attr.bool(default = False),
        "workspace_cargo_toml": attr.string(default = "Cargo.toml"),
    } | common_attrs,
)
