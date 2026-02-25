load("@package_metadata//rules:package_metadata.bzl", "package_metadata")
load("//rs:cargo_build_script.bzl", "cargo_build_script")
load("//rs:rust_binary.bzl", "rust_binary")
load("//rs:rust_library.bzl", "rust_library")
load("//rs:rust_proc_macro.bzl", "rust_proc_macro")

def _platform(triple, use_experimental_platforms):
    if use_experimental_platforms:
        return "@rules_rs//rs/experimental/platforms/config:" + triple
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
        binaries,
        use_experimental_platforms):
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
        build_script_kwargs = dict(
            build_deps = build_deps,
            aliases = aliases,
            compile_data = compile_data,
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

        if conditional_crate_features:
            branches = {}

            # The build script is cfg-exec, but the features must be selected according to the target.
            # Only stamp out one target per triple when there are per-platform feature deltas.
            for triple in triples:
                build_script_name = "_bs_" + triple
                branches[_platform(triple, use_experimental_platforms)] = build_script_name

                cargo_build_script(
                    name = build_script_name,
                    crate_features = crate_features + conditional_crate_features.get(triple, []),
                    **build_script_kwargs
                )

            native.alias(
                name = "_bs",
                actual = select(branches),
                tags = build_script_target_tags,
            )

        else:
            cargo_build_script(
                name = "_bs",
                crate_features = crate_features,
                **build_script_kwargs
            )

        maybe_build_script = ["_bs"]
    else:
        maybe_build_script = []

    deps = deps + maybe_build_script

    kwargs = dict(
        name = name,
        crate_name = crate_name,
        version = version,
        srcs = srcs,
        compile_data = compile_data,
        aliases = aliases,
        deps = deps,
        data = data,
        crate_features = crate_features + select(
            {_platform(k, use_experimental_platforms): v for k, v in conditional_crate_features.items()} |
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

