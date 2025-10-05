load("@rules_rust//cargo:defs.bzl", "cargo_build_script", "cargo_toml_env_vars")
load("@rules_rust//rust:defs.bzl", "rust_library", "rust_proc_macro")
load("//rs/private:rust_deps.bzl", "rust_deps")

def rust_crate(
        name,
        crate_name,
        version,
        aliases,
        deps,
        data,
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
        is_proc_macro):
    compile_data = native.glob(
        include = ["**"],
        exclude = [
            "**/* *",
            ".tmp_git_root/**/*",
            "BUILD",
            "BUILD.bazel",
            "REPO.bazel",
            "Cargo.toml.orig",
            "WORKSPACE",
            "WORKSPACE.bazel",
        ],
        allow_empty = True,
    )

    srcs = native.glob(
        include = ["**/*.rs"],
        allow_empty = True,
    )

    tags = [
        "crate-name=" + name,
        "manual",
        "noclippy",
        "norustfmt",
    ]

    cargo_toml_env_vars(
        name = "cargo_toml_env_vars",
        src = "Cargo.toml",
    )

    if build_script:
        rust_deps(
            name = "_bs_deps",
            deps = build_deps,
        )

        rust_deps(
            name = "_bs_proc_macro_deps",
            deps = build_deps,
            proc_macros = True,
        )

        cargo_build_script(
            name = "_bs",
            aliases = aliases,
            compile_data = compile_data,
            crate_features = crate_features,
            crate_name = "build_script_build",
            crate_root = build_script,
            links = links,
            data = compile_data + build_script_data,
            deps = [":_bs_deps"],
            link_deps = deps,
            build_script_env = build_script_env,
            toolchains = build_script_toolchains,
            proc_macro_deps = [":_bs_proc_macro_deps"],
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

    rust_deps(
        name = "deps",
        deps = deps,
    )

    rust_deps(
        name = "proc_macro_deps",
        deps = deps,
        proc_macros = True,
    )

    rule(
        name = name,
        crate_name = crate_name,
        version = version,
        srcs = srcs,
        compile_data = compile_data,
        aliases = aliases,
        deps = [":deps"] + maybe_build_script,
        data = data,
        proc_macro_deps = [":proc_macro_deps"],
        crate_features = crate_features,
        crate_root = crate_root,
        edition = edition,
        rustc_env_files = [":cargo_toml_env_vars"],
        rustc_flags = rustc_flags + ["--cap-lints=allow"],
        tags = tags,
        target_compatible_with = target_compatible_with,
        visibility = ["//visibility:public"],
    )
