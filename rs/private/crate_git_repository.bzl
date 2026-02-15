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
    strip_prefix = rctx.attr.strip_prefix

    repo_dir = rctx.path(rctx.attr.git_repo_label).dirname

    root = rctx.path(".")
    dest_dir = root.get_child(".tmp_git_root") if strip_prefix else root

    result = rctx.execute([
        "git",
        "--git-dir=" + str(repo_dir.get_child(".git")),
        "worktree",
        "add",
        str(dest_dir),
        "--force",
        "--force",
        "--detach",
        "HEAD"
    ])
    if result.return_code != 0:
        fail(result.stderr)

    if strip_prefix:
        dest_link = dest_dir.get_child(strip_prefix)
        if not dest_link.exists:
            fail("strip_prefix at {} does not exist in repo".format(strip_prefix))
        for item in dest_link.readdir():
            rctx.symlink(item, root.get_child(item.basename))

    patch(rctx)

    cargo_toml = run_toml2json(rctx, "Cargo.toml")

    if strip_prefix:
        workspace_cargo_toml_path = repo_dir.get_child(rctx.attr.workspace_cargo_toml)
    else:
        workspace_cargo_toml_path = rctx.path(rctx.attr.workspace_cargo_toml)
    workspace_cargo_toml = run_toml2json(rctx, workspace_cargo_toml_path)
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
        "workspace_cargo_toml": attr.string(default = "Cargo.toml"),
    } | common_attrs,
)
