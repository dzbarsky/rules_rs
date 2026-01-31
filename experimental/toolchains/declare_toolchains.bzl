"""Rust toolchain declarations driven by a macro."""

load("@rules_rust//rust:toolchain.bzl", "rust_toolchain")
load("//experimental/toolchains:toolchain_utils.bzl", "sanitize_triple", "sanitize_version")
load("//experimental/platforms:triples.bzl", "triple_to_constraint_set", "SUPPORTED_TARGET_TRIPLES")

_EXEC_CONFIGS = [
    struct(name = "linux_x86_64", exec_triple = "x86_64-unknown-linux-musl", exec_os = "linux", exec_cpu = "x86_64"),
    struct(name = "linux_aarch64", exec_triple = "aarch64-unknown-linux-musl", exec_os = "linux", exec_cpu = "aarch64"),
    struct(name = "windows_x86_64", exec_triple = "x86_64-pc-windows-msvc", exec_os = "windows", exec_cpu = "x86_64"),
    struct(name = "windows_aarch64", exec_triple = "aarch64-pc-windows-msvc", exec_os = "windows", exec_cpu = "aarch64"),
    struct(name = "macos_x86_64", exec_triple = "x86_64-apple-darwin", exec_os = "macos", exec_cpu = "x86_64"),
    struct(name = "macos_aarch64", exec_triple = "aarch64-apple-darwin", exec_os = "macos", exec_cpu = "aarch64"),
]

def _toolchain_declarations_repo_impl(rctx):
    rctx.file(
        "BUILD.bazel",
        """\
load("@rules_rs//experimental/toolchains:declare_toolchains.bzl", "declare_toolchains")

declare_toolchains(
    version = {version},
    edition = {edition},
)
""".format(
            version = repr(rctx.attr.version),
            edition = repr(rctx.attr.edition),
        ),
    )

    return rctx.repo_metadata(reproducible = True)

rust_toolchain_declarations = repository_rule(
    implementation = _toolchain_declarations_repo_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "edition": attr.string(mandatory = True),
    },
)

def _channel(version):
    if version.startswith("nightly"):
        return "nightly"
    if version.startswith("beta"):
        return "beta"
    return "stable"

SUPPORTED_EXECS = _EXEC_CONFIGS

def declare_toolchains(
    *,
    version,
    edition,
    execs = SUPPORTED_EXECS,
    targets = SUPPORTED_TARGET_TRIPLES):
    """Declare toolchains for all supported target platforms."""

    version_key = sanitize_version(version)
    channel = _channel(version)

    for config in execs:
        repo_name = "rust_toolchain_artifacts_{}_{}".format(config.name, version_key)
        repo_label = "@{}//:".format(repo_name)

        for target_triple in targets:
            target_key = sanitize_triple(target_triple)
            rust_std_label = "@rust_stdlib_{}_{}//:rust_std-{}".format(target_key, version_key, target_triple)
            rust_toolchain_name = "{}_{}_{}_{}_rust_toolchain".format(
                config.exec_os,
                config.exec_cpu,
                target_key,
                version_key,
            )

            rust_toolchain(
                name = rust_toolchain_name,
                rust_doc = "{}rustdoc".format(repo_label),
                rust_std = rust_std_label,
                rustc = "{}rustc".format(repo_label),
                rustfmt = "{}rustfmt_bin".format(repo_label),
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
                exec_triple = config.exec_triple,
                target_triple = target_triple,
                visibility = ["//visibility:public"],
                tags = ["rust_version={}".format(version)],
            )

            native.toolchain(
                name = "{}_{}_to_{}_{}".format(config.exec_os, config.exec_cpu, target_key, version_key),
                exec_compatible_with = [
                    "@platforms//os:" + config.exec_os,
                    "@platforms//cpu:" + config.exec_cpu,
                ],
                target_compatible_with = triple_to_constraint_set(target_triple),
                target_settings = [
                    "@rules_rust//rust/toolchain/channel:" + channel,
                ],
                toolchain = rust_toolchain_name,
                toolchain_type = "@rules_rust//rust:toolchain_type",
                visibility = ["//visibility:public"],
            )
