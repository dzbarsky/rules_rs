load("@package_metadata//rules:package_metadata.bzl", "package_metadata")
load("@rules_rust//cargo/private:cargo_build_script_wrapper.bzl", "cargo_build_script")
load("@rules_rust//rust:defs.bzl", "rust_binary", "rust_library", "rust_proc_macro")
load("//rs/private:rust_deps.bzl", "rust_deps")

def _platform(triple):
    return "@rules_rust//rust/platform:" + triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc")

def rust_crate(
        name,
        crate_name,
        version,
        aliases,
        deps,
        data,
        crate_features,
        triples,
        conditional_crate_features,
        crate_root,
        edition,
        rustc_flags,
        tags,
        target_compatible_with,
        links,
        build_script,
        build_script_data,
        build_deps,
        build_script_env,
        build_script_toolchains,
        build_script_tools,
        build_script_tags,
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

    default_tags = [
        "crate-name=" + name,
        "manual",
        "noclippy",
        "norustfmt",
    ]
    crate_tags = default_tags + tags
    build_script_target_tags = crate_tags + build_script_tags

    if build_script:
        branches = {}

        # The build script is cfg-exec, but the features must be selected according to the target. The easiest way to
        # do this is to stamp out a build script per target with the right feature set, and then select among them.
        for triple in triples:
            build_script_name = name + "_" + triple + "_build_script"
            branches[_platform(triple)] = build_script_name

            _build_script(
                name = build_script_name,
                build_deps = build_deps,
                aliases = aliases,
                compile_data = compile_data,
                crate_features = crate_features + conditional_crate_features.get(triple, []),
                crate_name = "build_script_build",
                crate_root = build_script,
                links = links,
                data = compile_data + build_script_data,
                link_deps = deps,
                build_script_env = build_script_env,
                build_script_env_files = ["cargo_toml_env_vars.env"],
                toolchains = build_script_toolchains,
                tools = build_script_tools,
                edition = edition,
                pkg_name = crate_name,
                rustc_env_files = ["cargo_toml_env_vars.env"],
                rustc_flags = ["--cap-lints=allow"],
                srcs = srcs,
                target_compatible_with = target_compatible_with,
                tags = build_script_target_tags + ["manual"],
                version = version,
            )

        native.alias(
            name = name + "_build_script",
            actual = select(branches),
            tags = build_script_target_tags,
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
        crate_features = crate_features + select(
            {_platform(k): v for k, v in conditional_crate_features.items()} |
            {"//conditions:default": []},
        ),
        crate_root = crate_root,
        edition = edition,
        rustc_env_files = ["cargo_toml_env_vars.env"],
        rustc_flags = rustc_flags + ["--cap-lints=allow"],
        tags = crate_tags,
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
            tags = crate_tags,
            target_compatible_with = target_compatible_with,
            version = version,
            visibility = ["//visibility:public"],
        )

def _build_script(
    name,
    build_deps,
    **kwargs,
):
    rust_deps(
        name = name + "_deps",
        deps = build_deps,
    )

    rust_deps(
        name = name + "_proc_macro_deps",
        deps = build_deps,
        proc_macros = True,
    )

    cargo_build_script(
        name = name,
        deps = [name + "_deps"],
        proc_macro_deps = [name + "_proc_macro_deps"],
        **kwargs,
    )