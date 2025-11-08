load("@package_metadata//rules:package_metadata.bzl", "package_metadata")
load("@rules_rust//cargo/private:cargo_build_script_wrapper.bzl", "cargo_build_script")
load("@rules_rust//rust:defs.bzl", "rust_binary", "rust_library", "rust_proc_macro")
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
        is_proc_macro,
        binaries):

    package_metadata(
        name = name + "_package_metadata",
        # TODO(zbarsky): repository url for git deps?
        purl = "pkg:cargo/%s/%s" % (crate_name, version),
        visibility = ["//visibility:public"],
    )

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

    if build_script:
        rust_deps(
            name = name + "_build_script_deps",
            deps = build_deps,
        )

        rust_deps(
            name = name + "_build_script_proc_macro_deps",
            deps = build_deps,
            proc_macros = True,
        )

        cargo_build_script(
            name = name + "_build_script",
            aliases = aliases,
            compile_data = compile_data,
            crate_features = crate_features,
            crate_name = "build_script_build",
            crate_root = build_script,
            links = links,
            data = compile_data + build_script_data,
            deps = [name + "_build_script_deps"],
            link_deps = deps,
            build_script_env = build_script_env,
            build_script_env_files = ["cargo_toml_env_vars.env"],
            toolchains = build_script_toolchains,
            proc_macro_deps = [name + "_build_script_proc_macro_deps"],
            edition = edition,
            pkg_name = crate_name,
            rustc_env_files = ["cargo_toml_env_vars.env"],
            rustc_flags = ["--cap-lints=allow"],
            srcs = srcs,
            target_compatible_with = target_compatible_with,
            tags = tags,
            version = version,
        )

        maybe_build_script = [name + "_build_script"]
    else:
        maybe_build_script = []

    rust_deps(
        name = name + "_deps",
        deps = deps,
    )

    rust_deps(
        name = name + "_proc_macro_deps",
        deps = deps,
        proc_macros = True,
    )

    deps = [name + "_deps"] + maybe_build_script

    kwargs = dict(
        name = name,
        crate_name = crate_name,
        version = version,
        srcs = srcs,
        compile_data = compile_data,
        aliases = aliases,
        deps = deps,
        data = data,
        proc_macro_deps = [name + "_proc_macro_deps"],
        crate_features = crate_features,
        crate_root = crate_root,
        edition = edition,
        rustc_env_files = ["cargo_toml_env_vars.env"],
        rustc_flags = rustc_flags + ["--cap-lints=allow"],
        tags = tags,
        target_compatible_with = target_compatible_with,
        package_metadata = [name + "_package_metadata"],
        visibility = ["//visibility:public"],
    )

    if is_proc_macro:
        rust_proc_macro(**kwargs)
    else:
        rust_library(**kwargs)

    for binary, crate_root in binaries.items():
        rust_binary(
            name = binary + "__bin",
            compile_data = compile_data,
            aliases = aliases,
            deps = [name] + deps,
            data = data,
            crate_features = crate_features,
            crate_root = crate_root,
            edition = edition,
            rustc_env_files = ["cargo_toml_env_vars.env"],
            rustc_flags = rustc_flags + ["--cap-lints=allow"],
            srcs = srcs,
            tags = tags,
            target_compatible_with = target_compatible_with,
            version = version,
            visibility = ["//visibility:public"],
        )
