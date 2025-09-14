load("@rules_rust//cargo:defs.bzl", "cargo_build_script", "cargo_toml_env_vars")
load("@rules_rust//rust:defs.bzl", "rust_library", "rust_proc_macro")

def rust_crate(
    name,
    crate_name,
    version,
    aliases,
    deps,
    extra_deps,
    data,
    proc_macro_deps, # TODO(zbarsky): Remove this
    crate_features,
    crate_root,
    edition,
    rustc_flags,
    target_compatible_with,
    links,
    build_script,
    build_script_data,
    build_deps,
    build_script_env,
    build_script_toolchains,
    proc_macro_build_deps, # TODO(zbarsky): remove this
    is_proc_macro,
):
    compile_data = native.glob(
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
    )

    srcs = native.glob(
        allow_empty = True,
        include = ["**/*.rs"],
    )

    tags = [
        "crate-name=" + name,
        "manual",
        "noclippy",
        "norustfmt",
    ]

    if not build_script and build_script != False and len(native.glob(["build.rs"], allow_empty = True)) == 1:
        build_script = "build.rs"

    cargo_toml_env_vars(
        name = "cargo_toml_env_vars",
        src = "Cargo.toml",
    )

    if name != "libduckdb-sys" and build_script:
        cargo_build_script(
            name = "_bs",
            compile_data = native.glob(
                include = ["**"],
                allow_empty = True,
                exclude = [
                    "**/* *",
                    "**/*.rs",
                    ".tmp_git_root/**/*",
                    "BUILD",
                    "BUILD.bazel",
                    "WORKSPACE",
                    "WORKSPACE.bazel",
                ],
            ),
            crate_features = crate_features,
            crate_name = "build_script_build",
            crate_root = build_script,
            links = links,
            data = compile_data + build_script_data,
            deps = build_deps,
            link_deps = deps,
            build_script_env = build_script_env,
            toolchains = build_script_toolchains,
            proc_macro_deps = proc_macro_build_deps,
            edition = edition,
            pkg_name = crate_name,
            rustc_env_files = [":cargo_toml_env_vars"],
            rustc_flags = ["--cap-lints=allow"],
            srcs = srcs,
            target_compatible_with = target_compatible_with,
            tags = tags,
            version = version,
        )

        maybe_build_script = [":_bs"]
    else:
        maybe_build_script = []

    rule = rust_proc_macro if is_proc_macro else rust_library

    rule(
        name = name,
        crate_name = crate_name,
        version = version,
        srcs = srcs,
        compile_data = compile_data,
        aliases = aliases,
        deps = deps + extra_deps + maybe_build_script,
        data = data,
        proc_macro_deps = proc_macro_deps,
        crate_features = crate_features,
        crate_root = crate_root,
        edition = edition,
        rustc_env_files = [":cargo_toml_env_vars"],
        rustc_flags = rustc_flags + ["--cap-lints=allow"],
        tags = tags,
        target_compatible_with = target_compatible_with,
        visibility = ["//visibility:public"],
    )

