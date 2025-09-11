load("@bazel_tools//tools/build_defs/repo:cache.bzl", "get_default_canonical_id")

def create_convert_py(ctx):
    ctx.file("convert.py", """
import sys
import tomllib
import json

with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)

print(json.dumps(data, indent=2))
""")

def exec_convert_py(ctx, file):
    # TODO(zbarsky): This relies on host python 3.11+, we will need a better solution.
    result = ctx.execute(["python", "convert.py", file])
    if result.return_code != 0:
        fail(result.stdout + "\n" + result.stderr)

    return json.decode(result.stdout)

def generate_build_file(attr, cargo_toml):
    # TODO(zbarsky): Handle implicit build.rs case for git repo??
    package = cargo_toml.get("package", {})
    build_script = package.get("build")
    if build_script:
        build_script = build_script.removeprefix("./")

    lib = cargo_toml.get("lib", {})
    is_proc_macro = lib.get("proc-macro") or lib.get("proc_macro") or False
    lib_path = lib.get("path", "src/lib.rs").removeprefix("./")

    edition = package.get("edition")
    if not edition or (type(edition) == "dict" and edition.get("workspace") == True):
        edition = attr.fallback_edition

    crate_name = lib.get("name")
    links = package.get("links")

    tags = [
        "crate-name=" + attr.crate,
        "manual",
        "noclippy",
        "norustfmt",
    ]

    compile_data = """glob(
        include = ["**"],
        allow_empty = True,
        exclude = [
            "**/* *",
            ".tmp_git_root/**/*",
            "BUILD",
            "BUILD.bazel",
            "WORKSPACE",
            "WORKSPACE.bazel",
        ],
    )"""

    build_content = """
load("@rules_rust//cargo:defs.bzl", "cargo_build_script", "cargo_toml_env_vars")
load("@rules_rust//rust:defs.bzl", "{library_rule_type}")

package(default_visibility = ["//visibility:public"])

cargo_toml_env_vars(
    name = "cargo_toml_env_vars",
    src = "Cargo.toml",
)

{library_rule_type}(
    name = {crate},
    crate_name = {crate_name},
    srcs = glob(
        include = ["**/*.rs"],
        allow_empty = True,
    ),
    aliases = {{
        {aliases}
    }}{conditional_aliases},
    deps = [
        {deps}
    ]{conditional_deps},
    data = [
        {data}
    ],
    proc_macro_deps = [
        {proc_macro_deps}
    ],
    compile_data = {compile_data},
    crate_features = {crate_features}{conditional_crate_features},
    crate_root = {lib_path},
    edition = {edition},
    rustc_env_files = [
        ":cargo_toml_env_vars",
    ],
    rustc_flags = {rustc_flags} + [
        "--cap-lints=allow",
    ],
    tags = [
        {tags}
    ],
    target_compatible_with = select({{
        {target_compatible_with},
        "//conditions:default": ["@platforms//:incompatible"],
    }}),
    version = {version}
)
"""

    deps = attr.deps
    if attr.crate != "libduckdb-sys" and build_script:
        deps = [":_bs"] + deps
        build_content += """

cargo_build_script(
    name = "_bs",
    compile_data = {compile_data},
    crate_features = {crate_features}{conditional_crate_features},
    crate_name = "build_script_build",
    crate_root = {build_script},
    links = {links},
    data = {compile_data} + [
        {build_script_data}
    ],
    deps = [
        {build_deps}
    ],
    build_script_env = {build_script_env},
    toolchains = {build_script_toolchains},
    proc_macro_deps = [
        {proc_macro_build_deps}
    ],
    edition = {edition},
    pkg_name = {crate},
    rustc_env_files = [
        ":cargo_toml_env_vars",
    ],
    rustc_flags = [
        "--cap-lints=allow",
    ],
    srcs = glob(
        allow_empty = True,
        include = ["**/*.rs"],
    ),
    target_compatible_with = select({{
        {target_compatible_with},
        "//conditions:default": ["@platforms//:incompatible"],
    }}),
    tags = [
        {tags}
    ],
    version = {version},
    visibility = ["//visibility:private"],
)"""

    return build_content.format(
        library_rule_type = "rust_proc_macro" if is_proc_macro else "rust_library",
        crate = repr(attr.crate),
        crate_name = repr(crate_name),
        version = repr(attr.version),
        edition = repr(edition),
        links = repr(links),
        crate_features = attr.crate_features,
        conditional_crate_features = attr.conditional_crate_features,
        lib_path = repr(lib_path),
        proc_macro_deps = ",\n        ".join(['"%s"' % d for d in attr.proc_macro_deps]),
        proc_macro_build_deps = ",\n        ".join(['"%s"' % d for d in attr.proc_macro_build_deps]),
        build_deps = ",\n        ".join(['"%s"' % d for d in attr.build_deps]),
        build_script_data = ",\n        ".join(['"%s"' % d for d in attr.build_script_data]),
        build_script_env = repr(attr.build_script_env),
        build_script_toolchains = repr([str(t) for t in attr.build_script_toolchains]),
        rustc_flags = repr(attr.rustc_flags or []),
        deps = ",\n        ".join(['"%s"' % d for d in deps]),
        data = ",\n        ".join(['"%s"' % d for d in attr.data]),
        conditional_deps = attr.conditional_deps,
        aliases = ",\n        ".join(['"%s": "%s"' % (k, v) for (k, v) in attr.aliases.items()]),
        conditional_aliases = attr.conditional_aliases,
        tags = ",\n        ".join(['"%s"' % t for t in tags]),
        build_script = repr(build_script),
        compile_data = compile_data,
        target_compatible_with = ",\n        ".join(['"%s": []' % t for t in attr.target_compatible_with]),
    )

def _crate_repository_impl(rctx):
    create_convert_py(rctx)

    # Compute the URL
    rctx.download_and_extract(
        rctx.attr.url,
        type = "tar.gz",
        canonical_id = get_default_canonical_id(rctx, urls = [rctx.attr.url]),
        strip_prefix = rctx.attr.strip_prefix,
        sha256 = rctx.attr.checksum,
    )

    cargo_toml = exec_convert_py(rctx, "Cargo.toml")
    rctx.delete("convert.py")

    build_script = cargo_toml.get("package", {}).get("build")
    if not build_script and rctx.path("build.rs").exists:
        if "package" not in cargo_toml:
            cargo_toml["package"] = {}
        cargo_toml["package"]["build"] = "build.rs"

    rctx.file("BUILD.bazel", generate_build_file(rctx.attr, cargo_toml))

    return rctx.repo_metadata(reproducible = True)

crate_repository = repository_rule(
    implementation = _crate_repository_impl,
    attrs = {
        "crate": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "url": attr.string(mandatory = True),
        "strip_prefix": attr.string(mandatory = True),
        "checksum": attr.string(),
        "build_deps": attr.label_list(default = []),
        "build_script_data": attr.label_list(default = []),
        "build_script_env": attr.string_dict(),
        "build_script_toolchains": attr.label_list(),
        "rustc_flags": attr.string_list(),
        "proc_macro_deps": attr.string_list(default = []),
        "proc_macro_build_deps": attr.string_list(default = []),
        "data": attr.label_list(default = []),
        "deps": attr.string_list(default = []),
        "conditional_deps": attr.string(default = ""),
        "aliases": attr.string_dict(),
        "conditional_aliases": attr.string(default = ""),
        "crate_features": attr.string(mandatory = True),
        "conditional_crate_features": attr.string(default = ""),
        "target_compatible_with": attr.string_list(mandatory = True),
        "fallback_edition": attr.string(default = "2015"),
    },
)
