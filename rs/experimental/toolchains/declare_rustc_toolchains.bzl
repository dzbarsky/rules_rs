load("@rules_rust//rust:toolchain.bzl", "rust_toolchain")
load("@rules_rust//rust/platform:triple.bzl", _parse_triple = "triple")
load("//rs/experimental/platforms:triples.bzl", "SUPPORTED_EXEC_TRIPLES", "SUPPORTED_TARGET_TRIPLES", "triple_to_constraint_set")
load("//rs/experimental/toolchains:toolchain_utils.bzl", "sanitize_triple", "sanitize_version")

def _channel(version):
    if version.startswith("nightly"):
        return "nightly"
    if version.startswith("beta"):
        return "beta"
    return "stable"

def declare_rustc_toolchains(
        *,
        version,
        edition,
        execs = SUPPORTED_EXEC_TRIPLES,
        targets = SUPPORTED_TARGET_TRIPLES):
    """Declare toolchains for all supported target platforms."""

    version_key = sanitize_version(version)
    channel = _channel(version)

    for triple in execs:
        exec_triple = _parse_triple(triple)
        triple_suffix = exec_triple.system + "_" + exec_triple.arch

        rustc_repo_label = "@rustc_{}_{}//:".format(triple_suffix, version_key)
        cargo_repo_label = "@cargo_{}_{}//:".format(triple_suffix, version_key)
        clippy_repo_label = "@clippy_{}_{}//:".format(triple_suffix, version_key)

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
            rust_doc = "{}rustdoc".format(rustc_repo_label),
            rust_std = select(rust_std_select),
            rustc = "{}rustc".format(rustc_repo_label),
            cargo = "{}cargo".format(cargo_repo_label),
            clippy_driver = "{}clippy_driver_bin".format(clippy_repo_label),
            cargo_clippy = "{}cargo_clippy_bin".format(clippy_repo_label),
            # TODO(zbarsky): Enable these once we ship them.
            #llvm_cov = "@llvm//tools:llvm-cov",
            #llvm_profdata = "@llvm//tools:llvm-profdata",
            rustc_lib = "{}rustc_lib".format(rustc_repo_label),
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
