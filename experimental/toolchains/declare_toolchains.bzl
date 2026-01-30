"""Rust toolchain declarations driven by a macro."""

load("@rules_rust//rust:toolchain.bzl", "rust_toolchain")
load("@rules_rust//rust/platform:triple.bzl", "triple")
load(
    "@rules_rust//rust/platform:triple_mappings.bzl",
    "SUPPORTED_PLATFORM_TRIPLES",
    "system_to_binary_ext",
    "system_to_dylib_ext",
    "system_to_staticlib_ext",
    "system_to_stdlib_linkflags",
    "triple_to_constraint_set",
)
load("@rules_rust//rust/private:repository_utils.bzl", "DEFAULT_STATIC_RUST_URL_TEMPLATES")
load("@toolchains_llvm_bootstrapped//constraints/libc:libc_versions.bzl", "DEFAULT_LIBC")
load("//experimental/toolchains:toolchain_utils.bzl", "sanitize_triple", "sanitize_version")

_EXEC_CONFIGS = [
    struct(name = "linux_x86_64", exec_triple = "x86_64-unknown-linux-gnu"),
    struct(name = "linux_aarch64", exec_triple = "aarch64-unknown-linux-gnu"),
    struct(name = "windows_x86_64", exec_triple = "x86_64-pc-windows-msvc"),
    struct(name = "windows_aarch64", exec_triple = "aarch64-pc-windows-msvc"),
    struct(name = "macos_aarch64", exec_triple = "aarch64-apple-darwin"),
]

# wasm64 does not provide a stdlib artifact today, so skip it for std downloads.
_STD_TARGET_TRIPLES = [
    t
    for t in SUPPORTED_PLATFORM_TRIPLES
    if t != "wasm64-unknown-unknown"
]

def _libc_constraint(target_triple):
    t = triple(target_triple)
    if t.system not in ("linux", "nixos"):
        return None
    if t.abi == "musl" or "musl" in target_triple:
        return "@toolchains_llvm_bootstrapped//constraints/libc:musl"
    return "@toolchains_llvm_bootstrapped//constraints/libc:{}".format(DEFAULT_LIBC)

def _constraints_for_triple(target_triple):
    constraints = list(triple_to_constraint_set(target_triple))
    libc = _libc_constraint(target_triple)
    if libc and libc not in constraints:
        constraints.append(libc)
    return constraints

def _select_map(triples, value_fn):
    """Return a select map keyed by config_settings for triples."""
    first = triples[0]
    return {
        "//experimental/toolchains:cfg_{}".format(sanitize_triple(triple)): value_fn(triple)
        for triple in triples
    } | {
        "//conditions:default": value_fn(first),
    }

def _toolchain_declarations_repo_impl(ctx):
    ctx.file("WORKSPACE.bazel", 'workspace(name = "{}")'.format(ctx.name))
    ctx.file(
        "BUILD.bazel",
        """\
load("@rules_rs//experimental/toolchains:declare_toolchains.bzl", "declare_toolchains")

declare_toolchains(
    version = {version},
    edition = {edition},
)
""".format(
            version = repr(ctx.attr.version),
            edition = repr(ctx.attr.edition),
        ),
    )

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

SUPPORTED_EXECS = [
    ("macos", "aarch64"),
    ("linux", "x86_64"),
    ("linux", "aarch64"),
    ("windows", "x86_64"),
    ("windows", "aarch64"),
]

def declare_toolchains(
    *,
    version,
    edition,
    execs = SUPPORTED_EXECS,
    targets = SUPPORTED_TARGETS):

    """Declare toolchains for all supported target platforms."""

    for target_triple in _STD_TARGET_TRIPLES:
        native.config_setting(
            name = "cfg_{}".format(sanitize_triple(target_triple)),
            constraint_values = _constraints_for_triple(target_triple),
        )

    channel = _channel(version)
    version_key = sanitize_version(version)

    for (exec_os, exec_cpu) in execs:
        repo_name = "rust_toolchain_artifacts_{}_{}".format(config.name, version_key)
        repo_label = "@{}//:".format(repo_name)

        rust_std_select = _select_map(
            _STD_TARGET_TRIPLES,
            lambda t: "@rust_stdlib_{}_{}//:rust_std-{}".format(sanitize_triple(t), version_key, t),
        )

        rust_toolchain_name = "{}_{}_{}_rust_toolchain".format(exec_os, exec_cpu, version_key)

        rust_toolchain(
            name = rust_toolchain_name,
            rust_doc = "{}rustdoc".format(repo_label),
            rust_std = select(rust_std_select),
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
            target_triple = _select_map(
                SUPPORTED_PLATFORM_TRIPLES,
                lambda t: t,
            ),
            visibility = ["//visibility:public"],
            tags = ["rust_version={}".format(version)],
        )

        for target_triple in _STD_TARGET_TRIPLES:
            native.toolchain(
                name = "{}_{}_to_{}_{}".format(exec_os, exec_cpu, sanitize_triple(target_triple), version_key),
                exec_compatible_with = [
                    "@platforms//os:" + exec_os,
                    "@platforms//cpu:" + exec_cpu,
                ],
                target_compatible_with = _constraints_for_triple(target_triple),
                target_settings = [
                    "@rules_rust//rust/toolchain/channel:" + channel,
                ],
                toolchain = rust_toolchain_name,
                toolchain_type = "@rules_rust//rust:toolchain",
                visibility = ["//visibility:public"],
            )
