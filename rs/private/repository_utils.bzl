
load(":semver.bzl", "parse_full_version")

def _platform(triple):
    return "@rules_rust//rust/platform:" + triple.replace("-musl", "-gnu")

def _format_branches(branches):
    return """select({
        %s
    })""" % (
        ",\n        ".join(['"%s": %s' % branch for branch in branches])
    )

def _select(non_platform_items, platform_items):
    if not platform_items:
        return non_platform_items, ""

    item_values = platform_items.values()
    common_items = set(item_values[0])
    for values in item_values[1:]:
        common_items.intersection_update(values)
        if not common_items:
            break

    common_items.update(non_platform_items)

    branches = []

    for triple, items in platform_items.items():
        items = set(items)
        items.difference_update(non_platform_items)
        items.difference_update(common_items)
        if items:
            branches.append((_platform(triple), repr(sorted(items))))

    if not branches:
        return common_items, ""

    branches.append(("//conditions:default", "[],"))

    return common_items, _format_branches(branches)

def _select_build_script_env(platform_items):
    branches = [
        (_platform(triple), items)
        for triple, items in platform_items.items()
    ]

    if not branches:
        return ""

    branches.append(("//conditions:default", "{},"))

    return _format_branches(branches)

def _exclude_deps_from_features(features):
    return [f for f in features if not f.startswith("dep:")]

def generate_build_file(rctx, cargo_toml):
    attr = rctx.attr
    package = cargo_toml["package"]

    name = package["name"]
    version = package["version"]
    parsed_version = parse_full_version(version)

    readme = package.get("readme", "")
    if (not readme or readme == True) and rctx.path("README.md").exists:
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
        "cargo_toml_env_vars.env",
        "\n".join(["%s=%s" % kv for kv in cargo_toml_env_vars.items()]),
    )

    bazel_metadata = package.get("metadata", {}).get("bazel", {})

    if attr.gen_build_script == "off" or bazel_metadata.get("gen_build_script") == False:
        build_script = None
    else:
        # What does `gen_build_script="on"` do? Fail the build if we don't detect one?
        build_script = package.get("build")
        if build_script:
            build_script = build_script.removeprefix("./")
        elif rctx.path("build.rs").exists:
            build_script = "build.rs"

    lib = cargo_toml.get("lib", {})
    is_proc_macro = lib.get("proc-macro") or lib.get("proc_macro") or False
    crate_root = (lib.get("path") or "src/lib.rs").removeprefix("./")

    edition = package.get("edition", "2015")
    crate_name = lib.get("name")
    links = package.get("links")

    build_content = \
"""load("@rules_rs//rs:rust_crate.bzl", "rust_crate")
load("@rules_rust//rust:defs.bzl", "rust_binary")
load("@{hub_name}//:defs.bzl", "RESOLVED_PLATFORMS")

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
    crate_features = {crate_features}{conditional_crate_features},
    crate_root = {crate_root},
    edition = {edition},
    rustc_flags = {rustc_flags},
    target_compatible_with = RESOLVED_PLATFORMS,
    links = {links},
    build_script = {build_script},
    build_script_data = {build_script_data},
    build_deps = [
        {build_deps}
    ]{conditional_build_deps},
    build_script_env = {build_script_env}{conditional_build_script_env},
    build_script_toolchains = {build_script_toolchains},
    is_proc_macro = {is_proc_macro},
    binaries = {binaries},
)
"""

    if attr.additive_build_file:
        build_content += rctx.read(attr.additive_build_file)
    build_content += attr.additive_build_file_content
    build_content += bazel_metadata.get("additive_build_file_content", "")

    crate_features, conditional_crate_features = _select(
        _exclude_deps_from_features(attr.crate_features),
        {platform: _exclude_deps_from_features(features) for platform, features in attr.crate_features_select.items()},
    )
    build_deps, conditional_build_deps = _select(attr.build_script_deps, attr.build_script_deps_select)
    build_script_data, conditional_build_script_data = _select(attr.build_script_data, attr.build_script_data_select)
    deps, conditional_deps = _select(attr.deps + bazel_metadata.get("deps", []), attr.deps_select)

    conditional_build_script_env = _select_build_script_env(attr.build_script_env_select)

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
        conditional_crate_features = " + " + conditional_crate_features if conditional_crate_features else "",
        crate_root = repr(crate_root),
        edition = repr(edition),
        rustc_flags = repr(attr.rustc_flags or []),
        links = repr(links),
        build_script = repr(build_script),
        build_script_data = repr([str(t) for t in build_script_data]),
        conditional_build_script_data = " + " + conditional_build_script_data if conditional_build_script_data else "",
        build_deps = ",\n        ".join(['"%s"' % d for d in sorted(build_deps)]),
        conditional_build_deps = " + " + conditional_build_deps if conditional_build_deps else "",
        build_script_env = repr(attr.build_script_env),
        conditional_build_script_env = " | " + conditional_build_script_env if conditional_build_script_env else "",
        build_script_toolchains = repr([str(t) for t in attr.build_script_toolchains]),
        is_proc_macro = repr(is_proc_macro),
        binaries = binaries,
    )

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
    "rustc_flags": attr.string_list(),
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
}