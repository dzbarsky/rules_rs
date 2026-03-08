load("@bazel_lib//lib:repo_utils.bzl", "repo_utils")
load("@bazel_skylib//lib:paths.bzl", "paths")
load(":semver.bzl", "parse_full_version")
load(":select_utils.bzl", "compute_select")

BUILD_FILE_DIR = "__crate"
_ROOT_EXCLUDES = [
    BUILD_FILE_DIR,
    ".git",
    ".tmp_git_root",
    "BUILD",
    "BUILD.bazel",
    "REPO.bazel",
    "WORKSPACE",
    "WORKSPACE.bazel",
]
_PACKAGE_METADATA_FILES = [
    "BUILD",
    "BUILD.bazel",
    "REPO.bazel",
    "WORKSPACE",
    "WORKSPACE.bazel",
]

def _build_file_path(rctx, basename):
    return paths.join(BUILD_FILE_DIR, basename)

def _package_root(rctx):
    return rctx.path(BUILD_FILE_DIR)

def _manifest_dir_path(rctx):
    return paths.join("external", rctx.name, BUILD_FILE_DIR)

def _relative_manifest_dir_for_build_script(build_script):
    dirname = paths.dirname(build_script)
    if not dirname:
        return "."

    depth = len([part for part in dirname.split("/") if part and part != "."])
    if depth == 0:
        return "."

    return "/".join([".."] * depth)

def _detect_build_script(attr, bazel_metadata, package_root, package):
    if attr.gen_build_script == "off" or bazel_metadata.get("gen_build_script") == False:
        return None

    build_script = package.get("build")
    if build_script:
        return build_script.removeprefix("./")
    if package_root.get_child("build.rs").exists:
        return "build.rs"
    return None

def _materialize_crate_tree_unix_cmd():
    root_excludes = " ".join(["! -name '%s'" % name for name in _ROOT_EXCLUDES])
    metadata_match = " -o ".join(["-name %s" % name for name in _PACKAGE_METADATA_FILES])
    return """\
set -eu
mkdir -p '{dir}'
find . -mindepth 1 -maxdepth 1 {root_excludes} -exec cp -RL {{}} '{dir}/' ';'
find '{dir}' '(' {metadata_match} ')' -exec rm -rf {{}} +
""".format(
        dir = BUILD_FILE_DIR,
        root_excludes = root_excludes,
        metadata_match = metadata_match,
    )

def _materialize_crate_tree_windows_cmd():
    return """\
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path '{dir}' -Force | Out-Null
Get-ChildItem -Force | Where-Object {{ $_.Name -notin @({root_excludes}) }} | ForEach-Object {{
    Copy-Item -LiteralPath $_.FullName -Destination '{dir}' -Recurse -Force
}}
Get-ChildItem -LiteralPath '{dir}' -Recurse -Force -Include {metadata_files} | Remove-Item -Force -Recurse
""".format(
        dir = BUILD_FILE_DIR,
        root_excludes = ", ".join(["'%s'" % name for name in _ROOT_EXCLUDES]),
        metadata_files = ",".join(_PACKAGE_METADATA_FILES),
    )

def materialize_crate_tree(rctx):
    if repo_utils.is_windows(rctx):
        result = rctx.execute(["powershell", "-NoProfile", "-Command", _materialize_crate_tree_windows_cmd()])
    else:
        result = rctx.execute(["/bin/sh", "-c", _materialize_crate_tree_unix_cmd()])

    if result.return_code != 0:
        fail("failed to materialize crate tree at {}:\nstdout:\n{}\nstderr:\n{}".format(
            BUILD_FILE_DIR,
            result.stdout,
            result.stderr,
        ))

def _platform(triple, use_experimental_platforms):
    if use_experimental_platforms:
        return "@rules_rs//rs/experimental/platforms/config:" + triple
    return "@rules_rust//rust/platform:" + triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc")

def _format_branches(branches):
    return """select({
        %s
    })""" % (
        ",\n        ".join(['"%s": %s' % branch for branch in branches])
    )

def render_select(non_platform_items, platform_items, use_experimental_platforms):
    common_items, branches = compute_select(non_platform_items, platform_items)

    if not branches:
        return common_items, ""

    branches = [(_platform(k, use_experimental_platforms), repr(v)) for k, v in branches.items()]
    branches.append(("//conditions:default", "[],"))

    return common_items, _format_branches(branches)

def render_select_build_script_env(platform_items, use_experimental_platforms):
    branches = [
        (_platform(triple, use_experimental_platforms), _rebase_make_var_paths(items))
        for triple, items in platform_items.items()
    ]

    if not branches:
        return ""

    branches.append(("//conditions:default", "{},"))

    return _format_branches(branches)

def _exclude_deps_from_features(features):
    return [f for f in features if not f.startswith("dep:")]

def _rebase_make_var_paths(value):
    for token in [
        "$(rootpath ",
        "$(rootpaths ",
    ]:
        value = value.replace(token, "../" + token)

    return value

def _execpathify_make_var_paths(value):
    return value.replace("$(rootpaths ", "$${pwd}/$(execpaths ").replace("$(rootpath ", "$${pwd}/$(execpaths ")

def render_exec_build_script_env(platform_items, use_experimental_platforms):
    branches = [
        (_platform(triple, use_experimental_platforms), _execpathify_make_var_paths(items))
        for triple, items in platform_items.items()
    ]

    if not branches:
        return ""

    branches.append(("//conditions:default", "{}," ))

    return _format_branches(branches)

def generate_build_file(rctx, cargo_toml):
    attr = rctx.attr
    package_root = _package_root(rctx)
    package = cargo_toml["package"]

    name = package["name"]
    version = package["version"]
    parsed_version = parse_full_version(version)

    readme = package.get("readme", "")
    if (not readme or readme == True) and package_root.get_child("README.md").exists:
        readme = "README.md"

    cargo_toml_env_vars = {
        "CARGO_PKG_VERSION": version,
        "CARGO_PKG_VERSION_MAJOR": str(parsed_version[0]),
        "CARGO_PKG_VERSION_MINOR": str(parsed_version[1]),
        "CARGO_PKG_VERSION_PATCH": str(parsed_version[2]),
        "CARGO_PKG_VERSION_PRE": parsed_version[3],
        "CARGO_PKG_NAME": name,
        "CARGO_PKG_AUTHORS": ":".join(package.get("authors", [])),
        "CARGO_PKG_DESCRIPTION": package.get("description", "").replace("\n", "\\"),
        "CARGO_PKG_HOMEPAGE": package.get("homepage", ""),
        "CARGO_PKG_REPOSITORY": package.get("repository", ""),
        "CARGO_PKG_LICENSE": package.get("license", ""),
        "CARGO_PKG_LICENSE_FILE": package.get("license_file", ""),
        "CARGO_PKG_RUST_VERSION": package.get("rust-version", ""),
        "CARGO_PKG_README": readme,
    }

    rctx.file(
        _build_file_path(rctx, "cargo_toml_env_vars.env"),
        "\n".join(["%s=%s" % kv for kv in cargo_toml_env_vars.items()]),
    )

    bazel_metadata = package.get("metadata", {}).get("bazel", {})

    build_script = _detect_build_script(attr, bazel_metadata, package_root, package)

    lib = cargo_toml.get("lib", {})
    is_proc_macro = lib.get("proc-macro") or lib.get("proc_macro") or False
    crate_root = (lib.get("path") or "src/lib.rs").removeprefix("./")

    edition = package.get("edition", "2015")
    crate_name = lib.get("name")
    links = package.get("links")

    build_content = \
"""load("@rules_rs//rs:rust_crate.bzl", "rust_crate")
load("@rules_rs//rs:rust_binary.bzl", "rust_binary")
load("@{hub_name}//:defs.bzl", "RESOLVED_PLATFORMS")

filegroup(
    name = "__compile_data",
    srcs = ["."],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "__rs_srcs",
    srcs = glob(
        include = ["**/*.rs"],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
)

exports_files(
    [
        "cargo_toml_env_vars.env"{exported_build_script}
    ],
    visibility = ["//visibility:public"],
)

rust_crate(
    name = {name},
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
    crate_features = {crate_features},
    triples = {triples},
    conditional_crate_features = {conditional_crate_features},
    crate_root = {crate_root},
    edition = {edition},
    rustc_flags = {rustc_flags}{conditional_rustc_flags},
    tags = {tags},
    target_compatible_with = RESOLVED_PLATFORMS,
    links = {links},
    build_script = {build_script},
    build_script_target = {build_script_target},
    build_script_data = {build_script_data},
    build_deps = [
        {build_deps}
    ]{conditional_build_deps},
    build_script_env = {build_script_env}{conditional_build_script_env},
    build_script_toolchains = {build_script_toolchains},
    build_script_tools = {build_script_tools}{conditional_build_script_tools},
    build_script_tags = {build_script_tags},
    is_proc_macro = {is_proc_macro},
    binaries = {binaries},
    use_experimental_platforms = {use_experimental_platforms},
)
"""

    if attr.additive_build_file:
        build_content += rctx.read(attr.additive_build_file)
    build_content += attr.additive_build_file_content
    build_content += bazel_metadata.get("additive_build_file_content", "")

    # We keep conditional_crate_features unrendered here because it must be treated specially for build scripts.
    # See `rust_crate.bzl` for details.
    crate_features, conditional_crate_features = compute_select(
        _exclude_deps_from_features(attr.crate_features),
        {platform: _exclude_deps_from_features(features) for platform, features in attr.crate_features_select.items()},
    )
    use_experimental_platforms = rctx.attr.use_experimental_platforms
    build_deps, conditional_build_deps = render_select(attr.build_script_deps, attr.build_script_deps_select, use_experimental_platforms)
    build_script_data, conditional_build_script_data = render_select(attr.build_script_data, attr.build_script_data_select, use_experimental_platforms)
    build_script_tools, conditional_build_script_tools = render_select(attr.build_script_tools, attr.build_script_tools_select, use_experimental_platforms)
    rustc_flags, conditional_rustc_flags = render_select(attr.rustc_flags, attr.rustc_flags_select, use_experimental_platforms)
    deps, conditional_deps = render_select(attr.deps + bazel_metadata.get("deps", []), attr.deps_select, use_experimental_platforms)

    conditional_build_script_env = render_select_build_script_env(
        attr.build_script_env_select,
        use_experimental_platforms,
    )
    build_script_env = {k: _rebase_make_var_paths(v) for k, v in attr.build_script_env.items()}

    binaries = {bin["name"]: bin["path"] for bin in cargo_toml.get("bin", []) if bin["name"] in rctx.attr.gen_binaries}

    return build_content.format(
        name = repr(name),
        hub_name = rctx.attr.hub_name,
        crate_name = repr(crate_name),
        version = repr(version),
        aliases = ",\n        ".join(['"%s": "%s"' % kv for kv in attr.aliases.items()]),
        deps = ",\n        ".join(['"%s"' % d for d in sorted(deps)]),
        conditional_deps = " + " + conditional_deps if conditional_deps else "",
        data = ",\n        ".join(['"%s"' % d for d in attr.data]),
        crate_features = repr(sorted(crate_features)),
        triples = repr(attr.crate_features_select.keys()),
        conditional_crate_features = repr(conditional_crate_features),
        crate_root = repr(crate_root),
        edition = repr(edition),
        rustc_flags = repr(rustc_flags),
        conditional_rustc_flags = " + " + conditional_rustc_flags if conditional_rustc_flags else "",
        tags = repr(attr.crate_tags),
        links = repr(links),
        build_script = repr(build_script),
        build_script_target = repr("//:_bs" if build_script else None),
        exported_build_script = ',\n        %r' % build_script if build_script else "",
        build_script_data = repr([str(t) for t in build_script_data]),
        conditional_build_script_data = " + " + conditional_build_script_data if conditional_build_script_data else "",
        build_deps = ",\n        ".join(['"%s"' % d for d in sorted(build_deps)]),
        conditional_build_deps = " + " + conditional_build_deps if conditional_build_deps else "",
        build_script_env = repr(build_script_env),
        conditional_build_script_env = " | " + conditional_build_script_env if conditional_build_script_env else "",
        build_script_toolchains = repr([str(t) for t in attr.build_script_toolchains]),
        build_script_tools = repr([str(t) for t in build_script_tools]),
        conditional_build_script_tools = " + " + conditional_build_script_tools if conditional_build_script_tools else "",
        build_script_tags = repr(attr.build_script_tags),
        is_proc_macro = repr(is_proc_macro),
        binaries = binaries,
        use_experimental_platforms = use_experimental_platforms,
    )

def generate_root_build_file(rctx, cargo_toml):
    attr = rctx.attr
    package_root = _package_root(rctx)
    package = cargo_toml["package"]
    bazel_metadata = package.get("metadata", {}).get("bazel", {})
    name = package["name"]
    build_script = _detect_build_script(attr, bazel_metadata, package_root, package)
    binaries = [bin["name"] for bin in cargo_toml.get("bin", []) if bin["name"] in rctx.attr.gen_binaries]

    contents = []

    if build_script:
        use_experimental_platforms = rctx.attr.use_experimental_platforms
        crate_features, conditional_crate_features = compute_select(
            _exclude_deps_from_features(attr.crate_features),
            {platform: _exclude_deps_from_features(features) for platform, features in attr.crate_features_select.items()},
        )
        build_deps, conditional_build_deps = render_select(attr.build_script_deps, attr.build_script_deps_select, use_experimental_platforms)
        build_script_data, conditional_build_script_data = render_select(attr.build_script_data, attr.build_script_data_select, use_experimental_platforms)
        build_script_tools, conditional_build_script_tools = render_select(attr.build_script_tools, attr.build_script_tools_select, use_experimental_platforms)
        deps, conditional_deps = render_select(attr.deps + bazel_metadata.get("deps", []), attr.deps_select, use_experimental_platforms)
        conditional_build_script_env = render_exec_build_script_env(
            attr.build_script_env_select,
            use_experimental_platforms,
        )
        build_script_env = {k: _execpathify_make_var_paths(v) for k, v in attr.build_script_env.items()}

        compile_data_target = "//%s:__compile_data" % BUILD_FILE_DIR
        build_script_root = "//%s:%s" % (BUILD_FILE_DIR, build_script)
        cargo_toml_env_file = "//%s:cargo_toml_env_vars.env" % BUILD_FILE_DIR
        rs_srcs_target = "//%s:__rs_srcs" % BUILD_FILE_DIR
        build_script_tags = [
            "crate-name=" + name,
            "manual",
            "noclippy",
            "norustfmt",
        ] + attr.crate_tags + attr.build_script_tags + ["manual"]
        build_script_template = """cargo_build_script(
    name = {name},
    crate_features = {crate_features},
    deps = [
        {build_deps}
    ]{conditional_build_deps},
    aliases = {{
        {aliases}
    }},
    compile_data = [{compile_data_target}],
    crate_name = "build_script_build",
    crate_root = {build_script_root},
    links = {links},
    data = [{compile_data_target}] + {build_script_data}{conditional_build_script_data},
    link_deps = [
        {deps}
    ]{conditional_deps},
    build_script_env = {build_script_env}{conditional_build_script_env} | {manifest_dir_env},
    build_script_env_files = [{cargo_toml_env_file}],
    toolchains = {build_script_toolchains},
    tools = {build_script_tools}{conditional_build_script_tools},
    edition = {edition},
    pkg_name = {pkg_name},
    rustc_env = {rustc_env},
    rustc_env_files = [{cargo_toml_env_file}],
    rustc_flags = ["--cap-lints=allow"],
    srcs = [{rs_srcs_target}],
    target_compatible_with = RESOLVED_PLATFORMS,
    tags = {build_script_tags},
    version = {version},
)
"""

        contents.extend([
            'load("@rules_rs//rs:cargo_build_script.bzl", "cargo_build_script")',
            'load("@%s//:defs.bzl", "RESOLVED_PLATFORMS")' % rctx.attr.hub_name,
            "",
            'package(default_visibility = ["//visibility:public"])',
            "",
        ])

        if conditional_crate_features:
            for triple in attr.crate_features_select.keys():
                contents.append(build_script_template.format(
                    name = repr("_bs_" + triple),
                    crate_features = repr(sorted(crate_features) + conditional_crate_features.get(triple, [])),
                    build_deps = ",\n        ".join(['"%s"' % d for d in sorted(build_deps)]),
                    conditional_build_deps = " + " + conditional_build_deps if conditional_build_deps else "",
                    aliases = ",\n        ".join(['"%s": "%s"' % kv for kv in attr.aliases.items()]),
                    compile_data_target = repr(compile_data_target),
                    build_script_root = repr(build_script_root),
                    links = repr(package.get("links")),
                    build_script_data = repr([str(t) for t in build_script_data]),
                    conditional_build_script_data = " + " + conditional_build_script_data if conditional_build_script_data else "",
                    deps = ",\n        ".join(['"%s"' % d for d in sorted(deps)]),
                    conditional_deps = " + " + conditional_deps if conditional_deps else "",
                    build_script_env = repr(build_script_env),
                    conditional_build_script_env = " | " + conditional_build_script_env if conditional_build_script_env else "",
                    manifest_dir_env = repr({"CARGO_MANIFEST_DIR": _manifest_dir_path(rctx)}),
                    cargo_toml_env_file = repr(cargo_toml_env_file),
                    build_script_toolchains = repr([str(t) for t in attr.build_script_toolchains]),
                    build_script_tools = repr([str(t) for t in build_script_tools]),
                    conditional_build_script_tools = " + " + conditional_build_script_tools if conditional_build_script_tools else "",
                    edition = repr(package.get("edition", "2015")),
                    pkg_name = repr(cargo_toml.get("lib", {}).get("name")),
                    rustc_env = repr({"CARGO_MANIFEST_DIR": _relative_manifest_dir_for_build_script(build_script)}),
                    rs_srcs_target = repr(rs_srcs_target),
                    build_script_tags = repr(build_script_tags),
                    version = repr(package["version"]),
                ))

            contents.extend([
                'alias(',
                '    name = "_bs",',
                "    actual = select({",
            ])
            for triple in attr.crate_features_select.keys():
                contents.append('        "%s": %r,' % (_platform(triple, use_experimental_platforms), "_bs_" + triple))
            contents.extend([
                "    }),",
                ")",
                "",
            ])
        else:
            contents.append(build_script_template.format(
                name = repr("_bs"),
                crate_features = repr(sorted(crate_features)),
                build_deps = ",\n        ".join(['"%s"' % d for d in sorted(build_deps)]),
                conditional_build_deps = " + " + conditional_build_deps if conditional_build_deps else "",
                aliases = ",\n        ".join(['"%s": "%s"' % kv for kv in attr.aliases.items()]),
                compile_data_target = repr(compile_data_target),
                build_script_root = repr(build_script_root),
                links = repr(package.get("links")),
                build_script_data = repr([str(t) for t in build_script_data]),
                conditional_build_script_data = " + " + conditional_build_script_data if conditional_build_script_data else "",
                deps = ",\n        ".join(['"%s"' % d for d in sorted(deps)]),
                conditional_deps = " + " + conditional_deps if conditional_deps else "",
                build_script_env = repr(build_script_env),
                conditional_build_script_env = " | " + conditional_build_script_env if conditional_build_script_env else "",
                manifest_dir_env = repr({"CARGO_MANIFEST_DIR": _manifest_dir_path(rctx)}),
                cargo_toml_env_file = repr(cargo_toml_env_file),
                build_script_toolchains = repr([str(t) for t in attr.build_script_toolchains]),
                build_script_tools = repr([str(t) for t in build_script_tools]),
                conditional_build_script_tools = " + " + conditional_build_script_tools if conditional_build_script_tools else "",
                edition = repr(package.get("edition", "2015")),
                pkg_name = repr(cargo_toml.get("lib", {}).get("name")),
                rustc_env = repr({"CARGO_MANIFEST_DIR": _relative_manifest_dir_for_build_script(build_script)}),
                rs_srcs_target = repr(rs_srcs_target),
                build_script_tags = repr(build_script_tags),
                version = repr(package["version"]),
            ))
            contents.append("")
    else:
        contents.extend([
            'package(default_visibility = ["//visibility:public"])',
            "",
        ])

    contents.extend([
        'alias(',
        '    name = %r,' % name,
        '    actual = "//%s:%s",' % (BUILD_FILE_DIR, name),
        ')',
    ])

    for binary in binaries:
        contents.extend([
            "",
            "alias(",
            '    name = %r,' % (binary + "__bin"),
            '    actual = "//%s:%s",' % (BUILD_FILE_DIR, binary + "__bin"),
            ")",
        ])

    return "\n".join(contents) + "\n"

common_attrs = {
    "hub_name": attr.string(),
    "additive_build_file": attr.label(),
    "additive_build_file_content": attr.string(),
    "gen_build_script": attr.string(),
    "build_script_deps": attr.label_list(default = []),
    "build_script_deps_select": attr.string_list_dict(),
    "build_script_data": attr.label_list(default = []),
    "build_script_data_select": attr.string_list_dict(),
    "build_script_env": attr.string_dict(),
    "build_script_env_select": attr.string_dict(),
    "build_script_toolchains": attr.label_list(),
    "build_script_tools": attr.label_list(default = []),
    "build_script_tools_select": attr.string_list_dict(),
    "build_script_tags": attr.string_list(),
    "rustc_flags": attr.string_list(),
    "rustc_flags_select": attr.string_list_dict(),
    "crate_tags": attr.string_list(),
    "data": attr.label_list(default = []),
    "deps": attr.string_list(default = []),
    "deps_select": attr.string_list_dict(),
    "aliases": attr.string_dict(),
    "crate_features": attr.string_list(),
    "crate_features_select": attr.string_list_dict(),
    "gen_binaries": attr.string_list(),
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
} | {
    "use_experimental_platforms": attr.bool(),
}
