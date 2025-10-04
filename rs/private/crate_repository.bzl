load("@bazel_tools//tools/build_defs/repo:cache.bzl", "get_default_canonical_id")
load("@bazel_tools//tools/build_defs/repo:git_worker.bzl", "git_repo")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "patch")

def run_toml2json(ctx, wasm_blob, toml_file):
    if wasm_blob == None:
        result = ctx.execute([Label("@toml2json_host_bin//:toml2json"), toml_file])
        if result.return_code != 0:
            fail(result.stdout + result.stderr)

        return json.decode(result.stdout)
    else:
        data = ctx.read(toml_file)
        result = ctx.execute_wasm(wasm_blob, "toml2json", input = data)
        if result.return_code != 0:
            fail(result.output)

        return json.decode(result.output)

def _generate_build_file(attr, cargo_toml):
    package = cargo_toml["package"]
    bazel_metadata = package.get("metadata", {}).get("bazel", {})

    if attr.gen_build_script == "off":
        build_script = False
    else:
        # What does `on` do? Fail the build if we don't detect one?
        build_script = package.get("build")
        if build_script:
            build_script = build_script.removeprefix("./")
        if bazel_metadata.get("gen_build_script") == False:
            build_script = False

    lib = cargo_toml.get("lib", {})
    is_proc_macro = lib.get("proc-macro") or lib.get("proc_macro") or False
    lib_path = (lib.get("path") or "src/lib.rs").removeprefix("./")

    edition = package.get("edition", "2015")
    crate_name = lib.get("name")
    links = package.get("links")

    build_content = """
load("@rules_rs//rs:rust_crate.bzl", "rust_crate")

rust_crate(
    name = {crate},
    crate_name = {crate_name},
    version = {version},
    aliases = {{
        {aliases}
    }},
    deps = [
        {deps}
    ]{conditional_deps},
    data = [
        {data}
    ],
    crate_features = {crate_features}{conditional_crate_features},
    crate_root = {lib_path},
    edition = {edition},
    rustc_flags = {rustc_flags},
    target_compatible_with = select({{
        {target_compatible_with},
        "//conditions:default": ["@platforms//:incompatible"],
    }}),
    links = {links},
    build_script = {build_script},
    build_script_data = [
        {build_script_data}
    ],
    build_deps = [
        {build_deps}
    ]{conditional_build_deps},
    build_script_env = {build_script_env},
    build_script_toolchains = {build_script_toolchains},
    is_proc_macro = {is_proc_macro},
)

"""

    build_content += bazel_metadata.get("additive_build_file_content", "")

    return build_content.format(
        crate = repr(attr.crate),
        crate_name = repr(crate_name),
        version = repr(package["version"]),
        aliases = ",\n        ".join(['"%s": "%s"' % (k, v) for (k, v) in attr.aliases.items()]),
        deps = ",\n        ".join(['"%s"' % d for d in attr.deps + bazel_metadata.get("deps", [])]),
        conditional_deps = attr.conditional_deps,
        data = ",\n        ".join(['"%s"' % d for d in attr.data]),
        crate_features = attr.crate_features,
        conditional_crate_features = attr.conditional_crate_features,
        lib_path = repr(lib_path),
        edition = repr(edition),
        rustc_flags = repr(attr.rustc_flags or []),
        target_compatible_with = ",\n        ".join(['"%s": []' % t for t in attr.target_compatible_with]),
        links = repr(links),
        build_script = repr(build_script),
        build_script_data = ",\n        ".join(['"%s"' % d for d in attr.build_script_data]),
        build_deps = ",\n        ".join(['"%s"' % d for d in attr.build_deps]),
        conditional_build_deps = attr.conditional_build_deps,
        build_script_env = repr(attr.build_script_env),
        build_script_toolchains = repr([str(t) for t in attr.build_script_toolchains]),
        is_proc_macro = repr(is_proc_macro),
    )

def _crate_repository_impl(rctx):
    rctx.download_and_extract(
        rctx.attr.url,
        type = "tar.gz",
        canonical_id = get_default_canonical_id(rctx, urls = [rctx.attr.url]),
        strip_prefix = rctx.attr.strip_prefix,
        sha256 = rctx.attr.checksum,
    )

    patch(rctx)

    if rctx.attr.use_wasm:
        wasm_blob = rctx.load_wasm(Label("@rules_rs//toml2json:toml2json.wasm"))
    else:
        wasm_blob = None
    cargo_toml = run_toml2json(rctx, wasm_blob, "Cargo.toml")

    rctx.file("BUILD.bazel", _generate_build_file(rctx.attr, cargo_toml))

    return rctx.repo_metadata(reproducible = True)

_common_attrs = {
    "crate": attr.string(mandatory = True),
    # TODO(zbarsky): Do we need the above?
    "gen_build_script": attr.string(),
    "build_deps": attr.label_list(default = []),
    "conditional_build_deps": attr.string(default = ""),
    "build_script_data": attr.label_list(default = []),
    "build_script_env": attr.string_dict(),
    "build_script_toolchains": attr.label_list(),
    "rustc_flags": attr.string_list(),
    "data": attr.label_list(default = []),
    "deps": attr.string_list(default = []),
    "conditional_deps": attr.string(default = ""),
    "aliases": attr.string_dict(),
    "crate_features": attr.string(mandatory = True),
    "conditional_crate_features": attr.string(default = ""),
    "target_compatible_with": attr.string_list(mandatory = True),
    "use_wasm": attr.bool(),
} | {
    "strip_prefix": attr.string(
        default = "",
        doc = "A directory prefix to strip from the extracted files.",
    ),
    "patches": attr.label_list(
        default = [],
        doc =
            "A list of files that are to be applied as patches after " +
            "extracting the archive. By default, it uses the Bazel-native patch implementation " +
            "which doesn't support fuzz match and binary patch, but Bazel will fall back to use " +
            "patch command line tool if `patch_tool` attribute is specified or there are " +
            "arguments other than `-p` in `patch_args` attribute.",
    ),
    "patch_tool": attr.string(
        default = "",
        doc = "The patch(1) utility to use. If this is specified, Bazel will use the specified " +
              "patch tool instead of the Bazel-native patch implementation.",
    ),
    "patch_args": attr.string_list(
        default = [],
        doc =
            "The arguments given to the patch tool. Defaults to -p0 (see the `patch_strip` " +
            "attribute), however -p1 will usually be needed for patches generated by " +
            "git. If multiple -p arguments are specified, the last one will take effect." +
            "If arguments other than -p are specified, Bazel will fall back to use patch " +
            "command line tool instead of the Bazel-native patch implementation. When falling " +
            "back to patch command line tool and patch_tool attribute is not specified, " +
            "`patch` will be used.",
    ),
    "patch_strip": attr.int(
        default = 0,
        doc = "When set to `N`, this is equivalent to inserting `-pN` to the beginning of `patch_args`.",
    ),
    "patch_cmds": attr.string_list(
        default = [],
        doc = "Sequence of Bash commands to be applied on Linux/Macos after patches are applied.",
    ),
    "patch_cmds_win": attr.string_list(
        default = [],
        doc = "Sequence of Powershell commands to be applied on Windows after patches are " +
              "applied. If this attribute is not set, patch_cmds will be executed on Windows, " +
              "which requires Bash binary to exist.",
    ),
}

crate_repository = repository_rule(
    implementation = _crate_repository_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "checksum": attr.string(),
    } | _common_attrs,
)

# TODO(zbarsky): Fix this up once Fabian fixes the upstream
# https://github.com/bazelbuild/bazel/blob/master/tools/build_defs/repo/git.bzl#L32
def _clone_or_update_repo(ctx, wasm_blob):
    root = ctx.path(".")
    directory = str(root)
    if ctx.attr.strip_prefix:
        directory = root.get_child(".tmp_git_root")

    # Return root Cargo.toml
    git_repo(ctx, directory)
    workspace_cargo_toml = None

    if ctx.attr.strip_prefix:
        workspace_cargo_toml = run_toml2json(ctx, wasm_blob, "Cargo.toml")

        dest_link = "{}/{}".format(directory, ctx.attr.strip_prefix)
        if not ctx.path(dest_link).exists:
            fail("strip_prefix at {} does not exist in repo".format(ctx.attr.strip_prefix))
        for item in ctx.path(dest_link).readdir():
            ctx.symlink(item, root.get_child(item.basename))

    return workspace_cargo_toml

# TODO(zbarsky): Inherit metadata fields?
_INHERITABLE_FIELDS = ["edition"]

def _crate_git_repository_implementation(rctx):
    if rctx.attr.use_wasm:
        wasm_blob = rctx.load_wasm(Label("@rules_rs//toml2json:toml2json.wasm"))
    else:
        wasm_blob = None

    workspace_cargo_toml = _clone_or_update_repo(rctx, wasm_blob)
    patch(rctx)

    if rctx.attr.strip_prefix:
        rctx.delete(rctx.path(".tmp_git_root/.git"))
    else:
        rctx.delete(rctx.path(".git"))

    cargo_toml = run_toml2json(rctx, wasm_blob, "Cargo.toml")

    if workspace_cargo_toml:
        crate_package = cargo_toml["package"]
        workspace_package = workspace_cargo_toml["package"]
        for field in _INHERITABLE_FIELDS:
            value = crate_package.get(field)
            if type(value) == "dict" and value.get("workspace") == True:
                crate_package[field] = workspace_package.get(field)

    rctx.file("BUILD.bazel", _generate_build_file(rctx.attr, cargo_toml))

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
    } | _common_attrs,
)
