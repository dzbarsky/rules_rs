"""Module extension for configuring experimental Rust toolchains."""

load(
    "@rules_rust//rust/platform:triple_mappings.bzl",
    "SUPPORTED_PLATFORM_TRIPLES",
)
load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "DEFAULT_STATIC_RUST_URL_TEMPLATES",
    "check_version_valid",
    "load_cargo",
    "load_clippy",
    "load_rust_compiler",
    "load_rust_stdlib",
    "load_rustfmt",
)
load("@rules_rust//rust/platform:triple.bzl", "triple")
load("//experimental/toolchains:declare_toolchains.bzl", "rust_toolchain_declarations")
load("//experimental/toolchains:toolchain_utils.bzl", "sanitize_triple", "sanitize_version")

_DEFAULT_RUSTC_VERSION = "1.92.0"
_DEFAULT_EDITION = "2021"


_EXEC_CONFIGS = [
    ("linux_x86_64", "x86_64-unknown-linux-gnu"),
    ("linux_aarch64", "aarch64-unknown-linux-gnu"),
    ("windows_x86_64", "x86_64-pc-windows-msvc"),
    ("windows_aarch64", "aarch64-pc-windows-msvc"),
    ("macos_aarch64", "aarch64-apple-darwin"),
]

_STD_TARGET_TRIPLES = [
    t
    for t in SUPPORTED_PLATFORM_TRIPLES
    if t != "wasm64-unknown-unknown"
]

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

    # TODO(zbarsky): Can we avoid some of these other tools...
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

    ctx.file("WORKSPACE.bazel", 'workspace(name = "{}")'.format(ctx.name))
    ctx.file("BUILD.bazel", "\n\n".join(build_parts))
    ctx.file(ctx.name, "")

rust_toolchain_artifacts = repository_rule(
    implementation = _rust_toolchain_artifacts_impl,
    attrs = {
        "exec_triple": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "rustfmt_version": attr.string(),
        "sha256s": attr.string_dict(),
        "urls": attr.string_list(default = DEFAULT_STATIC_RUST_URL_TEMPLATES),
    },
)

def _rust_stdlib_repo_impl(ctx):
    sha256s = dict(ctx.attr.sha256s)
    iso_date = None
    version = ctx.attr.version
    if "/" in version:
        version, iso_date = version.split("/", 1)
    check_version_valid(version, iso_date)

    target = triple(ctx.attr.target_triple)
    stdlib_content, stdlib_sha = load_rust_stdlib(
        ctx = ctx,
        target_triple = target,
        version = version,
        iso_date = iso_date,
    )
    sha256s.update(stdlib_sha)

    ctx.file("WORKSPACE.bazel", 'workspace(name = "{}")'.format(ctx.name))
    ctx.file("BUILD.bazel", stdlib_content)
    ctx.file(ctx.name, "")

rust_stdlib_artifacts = repository_rule(
    implementation = _rust_stdlib_repo_impl,
    attrs = {
        "target_triple": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "sha256s": attr.string_dict(),
        "urls": attr.string_list(default = DEFAULT_STATIC_RUST_URL_TEMPLATES),
    },
)

_TOOLCHAIN_TAG = tag_class(
    attrs = {
        "version": attr.string(
            doc = "Rust version (e.g. 1.86.0 or nightly/2025-04-03)",
            default = _DEFAULT_RUSTC_VERSION,
        ),
        "edition": attr.string(
            doc = "Default edition to apply to toolchains.",
            default = _DEFAULT_EDITION,
        ),
    },
)

def _toolchains_impl(module_ctx):
    versions_and_editions = []
    for mod in module_ctx.modules:
        for tag in mod.tags.toolchain:
            versions_and_editions.append((tag.version, tag.edition))

    if not versions_and_editions:
        versions_and_editions = [(_DEFAULT_RUSTC_VERSION, _DEFAULT_RUSTC_VERSION)]

    for version, edition in versions_and_editions:
        version_key = sanitize_version(version)

        for name, exec_triple in _EXEC_CONFIGS:
            rust_toolchain_artifacts(
                name = "rust_toolchain_artifacts_{}_{}".format(name, version_key),
                exec_triple = exec_triple,
                version = version,
            )

        seen = {}
        for target_triple in _STD_TARGET_TRIPLES:
            key = sanitize_triple(target_triple)
            if key in seen:
                continue
            seen[key] = True
            rust_stdlib_artifacts(
                name = "rust_stdlib_{}_{}".format(key, version_key),
                target_triple = target_triple,
                version = version,
            )

        rust_toolchain_declarations(
            name = "experimental_rust_toolchains_{}".format(version_key),
            version = version,
            edition = edition,
        )

toolchains = module_extension(
    implementation = _toolchains_impl,
    tag_classes = {"toolchain": _TOOLCHAIN_TAG},
)
