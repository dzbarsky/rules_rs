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
load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "DEFAULT_STATIC_RUST_URL_TEMPLATES",
    "check_version_valid",
    "load_cargo",
    "load_clippy",
    "load_llvm_tools",
    "load_rust_compiler",
    "load_rust_stdlib",
    "load_rustfmt",
)
load("@rules_rust//rust/private:common.bzl", "rust_common")
load("@toolchains_llvm_bootstrapped//constraints/libc:libc_versions.bzl", "DEFAULT_LIBC")
load("//experimental/toolchains:toolchain_utils.bzl", "sanitize_triple")

_DEFAULT_VERSION = "1.92.0"

_EXEC_CONFIGS = [
    struct(name = "linux_x86_64", exec_triple = "x86_64-unknown-linux-gnu"),
    struct(name = "linux_aarch64", exec_triple = "aarch64-unknown-linux-gnu"),
    struct(name = "windows_x86_64", exec_triple = "x86_64-pc-windows-msvc"),
    struct(name = "windows_aarch64", exec_triple = "aarch64-pc-windows-msvc"),
    struct(name = "macos_aarch64", exec_triple = "aarch64-apple-darwin"),
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
    return {
        "//experimental/toolchains:cfg_{}".format(sanitize_triple(triple)): value_fn(triple)
        for triple in triples
    } | {
        "//conditions:default": value_fn(triples[0]),
    }

def _rust_toolchain_artifacts_impl(ctx):
    sha256s = dict(ctx.attr.sha256s)
    iso_date = None
    version = ctx.attr.version
    if "/" in version:
        version, iso_date = version.split("/", 1)
    check_version_valid(version, iso_date)

    rustfmt_version = ctx.attr.rustfmt_version or version
    rustfmt_iso_date = None
    if "/" in rustfmt_version:
        rustfmt_version, rustfmt_iso_date = rustfmt_version.split("/", 1)
    elif rustfmt_version in ("nightly", "beta"):
        if not iso_date:
            fail("rustfmt_version requires an iso_date for nightly/beta")
        rustfmt_iso_date = iso_date

    exec_triple = triple(ctx.attr.exec_triple)
    build_parts = []

    rustc_content, rustc_sha = load_rust_compiler(
        ctx = ctx,
        iso_date = iso_date,
        target_triple = exec_triple,
        version = version,
    )
    clippy_content, clippy_sha = load_clippy(
        ctx = ctx,
        iso_date = iso_date,
        target_triple = exec_triple,
        version = version,
    )
    cargo_content, cargo_sha = load_cargo(
        ctx = ctx,
        iso_date = iso_date,
        target_triple = exec_triple,
        version = version,
    )
    rustfmt_content, rustfmt_sha = load_rustfmt(
        ctx = ctx,
        target_triple = exec_triple,
        version = rustfmt_version,
        iso_date = rustfmt_iso_date,
    )

    build_parts.extend([rustc_content, clippy_content, cargo_content, rustfmt_content])
    sha256s.update(rustc_sha | clippy_sha | cargo_sha | rustfmt_sha)

    for target_triple in SUPPORTED_PLATFORM_TRIPLES:
        stdlib_content, stdlib_sha = load_rust_stdlib(
            ctx = ctx,
            target_triple = triple(target_triple),
            version = version,
            iso_date = iso_date,
        )
        build_parts.append(stdlib_content)
        sha256s.update(stdlib_sha)

    ctx.file("WORKSPACE.bazel", 'workspace(name = "{}")'.format(ctx.name))
    ctx.file("BUILD.bazel", "\n\n".join(build_parts))
    ctx.file(ctx.name, "")

rust_toolchain_artifacts = repository_rule(
    implementation = _rust_toolchain_artifacts_impl,
    attrs = {
        "exec_triple": attr.string(mandatory = True),
        "version": attr.string(default = rust_common.default_version),
        "rustfmt_version": attr.string(),
        "sha256s": attr.string_dict(),
        "urls": attr.string_list(default = DEFAULT_STATIC_RUST_URL_TEMPLATES),
    },
)

SUPPORTED_EXECS = [
    ("macos", "aarch64"),
    ("linux", "x86_64"),
    ("linux", "aarch64"),
    ("windows", "x86_64"),
    ("windows", "aarch64"),
]

def declare_toolchains(
        *,
        version = _DEFAULT_VERSION,
        edition = "2021",
        execs = SUPPORTED_EXECS,
        targets = SUPPORTED_TARGETS):
    """Declare and register toolchains for all supported target platforms."""

    for target_triple in SUPPORTED_PLATFORM_TRIPLES:
        native.config_setting(
            name = "cfg_{}".format(sanitize_triple(target_triple)),
            constraint_values = _constraints_for_triple(target_triple),
        )

    for (exec_os, exec_cpu) in execs:
        repo_name = "rust_toolchain_artifacts_{}".format(config.name)
        repo_label = "@{}//:".format(repo_name)

        if version.startswith("nightly"):
            channel = "nightly"
        elif version.startswith("beta"):
            channel = "beta"
        else:
            channel = "stable"

        rust_std_select = _select_map(
            SUPPORTED_PLATFORM_TRIPLES,
            lambda t: "{}rust_std-{}".format(repo_label, t),
        )

        rust_toolchain_name = "{}_{}_rust_toolchain".format(exec_os, exec_cpu)

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

        for target_triple in SUPPORTED_PLATFORM_TRIPLES:
            native.toolchain(
                name = "{}_{}_to_{}".format(exec_os, exec_cpu, target_triple),
                exec_compatible_with = [
                    "@platforms//os:" + exec_os,
                    "@platforms//cpu:" + exec_cpu,
                ],
                target_compatible_with = _constraints_for_triple(target_triple),
                target_settings = [
                    "@rules_rust//rust/toolchain/channel:" + channel
                ],
                toolchain = rust_toolchain_name,
                toolchain_type = "@rules_rust//rust:toolchain",
                visibility = ["//visibility:public"],
            )
