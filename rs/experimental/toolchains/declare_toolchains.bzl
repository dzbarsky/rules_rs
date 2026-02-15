"""Rust toolchain declarations driven by a macro."""

load("@rules_rust//rust:toolchain.bzl", "rust_toolchain", "rustfmt_toolchain")
load("@rules_rust//rust/platform:triple.bzl", _parse_triple = "triple")
load("//rs/experimental/platforms:triples.bzl", "SUPPORTED_EXEC_TRIPLES", "SUPPORTED_TARGET_TRIPLES", "triple_to_constraint_set")
load("//rs/experimental/toolchains:toolchain_utils.bzl", "sanitize_triple", "sanitize_version")

def _channel(version):
    if version.startswith("nightly"):
        return "nightly"
    if version.startswith("beta"):
        return "beta"
    return "stable"

def declare_toolchains(
        *,
        version,
        edition,
        execs = SUPPORTED_EXEC_TRIPLES,
        targets = SUPPORTED_TARGET_TRIPLES):
    """Declare toolchains for all supported target platforms."""

    version_key = sanitize_version(version)
    channel = _channel(version)

    # Rustfmt
    for triple in execs:
        exec_triple = _parse_triple(triple)
        triple_suffix = exec_triple.system + "_" + exec_triple.arch

        repo_label = "@rust_toolchain_artifacts_{}_{}//:".format(triple_suffix, version_key)

        rustfmt_toolchain_name = "{}_{}_{}_rustfmt_toolchain".format(
            exec_triple.system,
            exec_triple.arch,
            version_key,
        )

        rustfmt_toolchain(
            name = rustfmt_toolchain_name,
            rustfmt = "{}rustfmt_bin".format(repo_label),
            rustc = "{}rustc".format(repo_label),
            rustc_lib = "{}rustc_lib".format(repo_label),
            visibility = ["//visibility:public"],
            tags = ["rust_version={}".format(version)],
        )

        native.toolchain(
            name = "{}_{}_rustfmt_{}".format(exec_triple.system, exec_triple.arch, version_key),
            exec_compatible_with = [
                "@platforms//os:" + exec_triple.system,
                "@platforms//cpu:" + exec_triple.arch,
            ],
            target_compatible_with = [],
            target_settings = [
                "@rules_rust//rust/toolchain/channel:" + channel,
            ],
            toolchain = rustfmt_toolchain_name,
            toolchain_type = "@rules_rust//rust/rustfmt:toolchain_type",
            visibility = ["//visibility:public"],
        )

    # Rustc
    for triple in execs:
        exec_triple = _parse_triple(triple)
        triple_suffix = exec_triple.system + "_" + exec_triple.arch

        repo_label = "@rust_toolchain_artifacts_{}_{}//:".format(triple_suffix, version_key)

        rust_toolchain_name = "{}_{}_{}_rust_toolchain".format(
            exec_triple.system,
            exec_triple.arch,
            version_key,
        )

        rust_std_select = {}
        target_triple_select = {}
        for target_triple in targets:
            target_key = sanitize_triple(target_triple)
            config_label = "@rules_rs//rs/experimental/platforms/config:{}".format(target_triple)
            rust_std_select[config_label] = "@rust_stdlib_{}_{}//:rust_std-{}".format(target_key, version_key, target_triple)
            target_triple_select[config_label] = target_triple

        rust_toolchain(
            name = rust_toolchain_name,
            rust_doc = "{}rustdoc".format(repo_label),
            rust_std = select(rust_std_select),
            rustc = "{}rustc".format(repo_label),
            rustfmt = "{}rustfmt_bin".format(repo_label),
            rust_objcopy = "{}rust-objcopy".format(repo_label),
            cargo = "{}cargo".format(repo_label),
            clippy_driver = "{}clippy_driver_bin".format(repo_label),
            cargo_clippy = "{}cargo_clippy_bin".format(repo_label),
            # TODO(zbarsky): Enable these once we ship them.
            #llvm_cov = "@toolchains_llvm_bootstrapped//tools:llvm-cov",
            #llvm_profdata = "@toolchains_llvm_bootstrapped//tools:llvm-profdata",
            rustc_lib = "{}rustc_lib".format(repo_label),
            allocator_library = None,
            global_allocator_library = None,
            binary_ext = select({
                "@platforms//os:none": ".wasm",
                "@platforms//os:windows": ".exe",
                "//conditions:default": "",
            }),
            staticlib_ext = select({
                "@platforms//os:none": "",
                "@platforms//os:windows": ".lib",
                "//conditions:default": ".a",
            }),
            dylib_ext = select({
                "@platforms//os:none": "",
                "@platforms//os:windows": ".dll",
                "@platforms//os:macos": ".dylib",
                "//conditions:default": ".so",
            }),
            stdlib_linkflags = select({
                "@platforms//os:freebsd": ["-lexecinfo", "-lpthread"],
                "@platforms//os:macos": ["-lSystem", "-lresolv"],
                # TODO: windows
                "//conditions:default": [],
            }),
            default_edition = edition,
            exec_triple = triple,
            target_triple = select(target_triple_select),
            visibility = ["//visibility:public"],
            tags = ["rust_version={}".format(version)],
        )

        for target_triple in targets:
            target_key = sanitize_triple(target_triple)

            native.toolchain(
                name = "{}_{}_to_{}_{}".format(exec_triple.system, exec_triple.arch, target_key, version_key),
                exec_compatible_with = [
                    "@platforms//os:" + exec_triple.system,
                    "@platforms//cpu:" + exec_triple.arch,
                ],
                target_compatible_with = triple_to_constraint_set(target_triple),
                target_settings = [
                    "@rules_rust//rust/toolchain/channel:" + channel,
                ],
                toolchain = rust_toolchain_name,
                toolchain_type = "@rules_rust//rust:toolchain_type",
                visibility = ["//visibility:public"],
            )
