load("@bazel_tools//tools/build_defs/repo:git_worker.bzl", "git_repo")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "patch")
load(":repository_utils.bzl", "common_attrs", "generate_build_file")
load(":toml2json.bzl", "run_toml2json")

# TODO(zbarsky): Fix this up once Fabian fixes the upstream
# https://github.com/bazelbuild/bazel/blob/master/tools/build_defs/repo/git.bzl#L32
def _clone_or_update_repo(ctx, wasm_blob):
    root = ctx.path(".")
    directory = str(root)
    if ctx.attr.strip_prefix:
        directory = root.get_child(".tmp_git_root")

    git_repo(ctx, directory)

    # If the repo corresponds to a workspace of crates, return the root's Cargo.toml
    workspace_cargo_toml = None

    if ctx.attr.strip_prefix:
        workspace_cargo_toml = run_toml2json(ctx, wasm_blob, directory.get_child(ctx.attr.workspace_cargo_toml))

        dest_link = "{}/{}".format(directory, ctx.attr.strip_prefix)
        if not ctx.path(dest_link).exists:
            fail("strip_prefix at {} does not exist in repo".format(ctx.attr.strip_prefix))
        for item in ctx.path(dest_link).readdir():
            ctx.symlink(item, root.get_child(item.basename))

    return workspace_cargo_toml

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
    if rctx.attr.use_wasm:
        wasm_blob = rctx.load_wasm(Label("@rules_rs//toml2json:toml2json.wasm"))
    else:
        wasm_blob = None

    if rctx.attr.name == "piiclient":
        print("pii", "strip", rctx.attr.strip_prefix, "root", rctx.attr.workspace_cargo_toml)

    workspace_cargo_toml = _clone_or_update_repo(rctx, wasm_blob)
    patch(rctx)

    if rctx.attr.strip_prefix:
        rctx.delete(rctx.path(".tmp_git_root/.git"))
    else:
        rctx.delete(rctx.path(".git"))

    cargo_toml = run_toml2json(rctx, wasm_blob, "Cargo.toml")

    if workspace_cargo_toml:
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
            default = False,
            doc = "Whether to clone submodules in the repository.",
        ),
        "recursive_init_submodules": attr.bool(
            default = False,
            doc = "Whether to clone submodules recursively in the repository.",
        ),
        "verbose": attr.bool(default = False),
        "workspace_cargo_toml": attr.string(default = "Cargo.toml"),
    } | common_attrs,
)
