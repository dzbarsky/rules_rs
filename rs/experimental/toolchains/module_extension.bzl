"""Module extension for configuring experimental Rust toolchains."""

load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "DEFAULT_STATIC_RUST_URL_TEMPLATES",
    "check_version_valid",
    "load_cargo",
    "load_clippy",
    "load_rust_compiler",
    "load_rustfmt",
    "produce_tool_suburl",
)
load("@rules_rust//rust/platform:triple.bzl", _parse_triple = "triple")
load("//rs/experimental/platforms:triples.bzl", "SUPPORTED_EXEC_TRIPLES", "SUPPORTED_TARGET_TRIPLES")
load("//rs/experimental/toolchains:toolchain_utils.bzl", "sanitize_triple", "sanitize_version")
load("//rs/private:cargo_repository.bzl", "cargo_repository")
load("//rs/private:host_tools_repository.bzl", "host_tools_repository")
load("//rs/private:stdlib_repository.bzl", "stdlib_repository")
load("//rs/private:toolchains_repository.bzl", "toolchains_repository")

_DEFAULT_RUSTC_VERSION = "1.92.0"
_DEFAULT_EDITION = "2021"

def _normalize_os_name(os_name):
    os_name = os_name.lower()
    if os_name.startswith("mac os"):
        return "macos"
    if os_name.startswith("windows"):
        return "windows"
    return os_name

def _normalize_arch_name(arch):
    arch = arch.lower()
    if arch in ("amd64", "x86_64", "x64"):
        return "x86_64"
    if arch in ("aarch64", "arm64"):
        return "aarch64"
    return arch

def _sanitize_path_fragment(path):
    return path.replace("/", "_").replace(":", "_")

def _tool_extension(urls):
    url = urls[0] if urls else ""
    if url.endswith(".tar.gz"):
        return ".tar.gz"
    if url.endswith(".tar.xz"):
        return ".tar.xz"
    return ""

def _archive_path(tool_name, target_triple, version, iso_date):
    return produce_tool_suburl(tool_name, target_triple, version, iso_date) + _tool_extension(DEFAULT_STATIC_RUST_URL_TEMPLATES)

def _rust_toolchain_artifacts_impl(rctx):
    sha256s = dict(rctx.attr.sha256s)
    iso_date = None
    version = rctx.attr.version
    if "/" in version:
        version, iso_date = version.split("/", 1)
    check_version_valid(version, iso_date)

    rustfmt_version = rctx.attr.rustfmt_version or version
    rustfmt_iso_date = None
    if "/" in rustfmt_version:
        rustfmt_version, rustfmt_iso_date = rustfmt_version.split("/", 1)
    elif rustfmt_version in ("nightly", "beta"):
        if not iso_date:
            fail("rustfmt_version requires an iso_date for nightly/beta")
        rustfmt_iso_date = iso_date

    exec_triple = _parse_triple(rctx.attr.exec_triple)
    build_parts = []

    # TODO(zbarsky): Can we avoid some of these other tools...
    rustc_content, rustc_sha = load_rust_compiler(
        ctx = rctx,
        iso_date = iso_date,
        target_triple = exec_triple,
        version = version,
        include_objcopy = True,
    )
    clippy_content, clippy_sha = load_clippy(
        ctx = rctx,
        iso_date = iso_date,
        target_triple = exec_triple,
        version = version,
    )
    cargo_content, cargo_sha = load_cargo(
        ctx = rctx,
        iso_date = iso_date,
        target_triple = exec_triple,
        version = version,
    )
    rustfmt_content, rustfmt_sha = load_rustfmt(
        ctx = rctx,
        target_triple = exec_triple,
        version = rustfmt_version,
        iso_date = rustfmt_iso_date,
    )

    build_parts.extend([rustc_content, clippy_content, cargo_content, rustfmt_content])
    sha256s.update(rustc_sha | clippy_sha | cargo_sha | rustfmt_sha)

    rctx.file("BUILD.bazel", "\n\n".join(build_parts))
    rctx.file(rctx.name, "")

    return rctx.repo_metadata(reproducible = True)

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

def _toolchains_impl(mctx):
    # TODO(zbarsky): we should have some per-version dedupe or something? Edition doesnt make sense to key off of.
    version_order = []
    for mod in mctx.modules:
        for tag in mod.tags.toolchain:
            version_order.append((tag.version, tag.edition))

    if not version_order:
        version_order.append((_DEFAULT_RUSTC_VERSION, _DEFAULT_EDITION))

    versions = []
    for version, edition in version_order:
        base_version = version
        iso_date = None
        if "/" in version:
            base_version, iso_date = version.split("/", 1)
        check_version_valid(base_version, iso_date)

        versions.append(struct(
            version = version,
            base = base_version,
            iso_date = iso_date,
            edition = edition,
        ))

    existing_facts = getattr(mctx, "facts", {}) or {}
    pending_downloads = {}
    new_facts = {}

    def _request_sha(tool_name, version, iso_date, target_triple):
        archive_path = _archive_path(tool_name, target_triple, version, iso_date)
        if archive_path in new_facts or archive_path in pending_downloads:
            return archive_path

        existing = existing_facts.get(archive_path)
        if existing:
            new_facts[archive_path] = existing
            return archive_path

        suburl = produce_tool_suburl(tool_name, target_triple, version, iso_date)
        sha_filename = _sanitize_path_fragment(archive_path) + ".sha256"
        pending_downloads[archive_path] = struct(
            token = mctx.download(
                DEFAULT_STATIC_RUST_URL_TEMPLATES[0].format(suburl) + ".sha256",
                sha_filename,
                block = False,
            ),
            file = sha_filename,
        )
        return archive_path

    # First pass: enqueue all sha downloads we don't already have.
    for version in versions:
        for triple in SUPPORTED_EXEC_TRIPLES:
            exec_triple = _parse_triple(triple)
            for tool_name in ["rustc", "clippy", "cargo", "rustfmt"]:
                _request_sha(tool_name, version.base, version.iso_date, exec_triple)

        for target_triple in SUPPORTED_TARGET_TRIPLES:
            _request_sha("rust-std", version.base, version.iso_date, _parse_triple(target_triple))

    # Finish downloads and record facts.
    for archive_path, req in pending_downloads.items():
        req.token.wait()
        sha_text = mctx.read(req.file).strip()
        sha = sha_text.split(" ")[0] if sha_text else ""
        if not sha:
            fail("Could not parse sha256 for {}".format(archive_path))
        new_facts[archive_path] = sha

    def _sha_for(tool_name, version, iso_date, target_triple):
        archive_path = _archive_path(tool_name, target_triple, version, iso_date)
        return archive_path, new_facts[archive_path]

    host_os = _normalize_os_name(mctx.os.name)
    host_arch = _normalize_arch_name(mctx.os.arch)
    host_cargo_repo = None

    for version in versions:
        version_key = sanitize_version(version.version)
        version_sha256s = {}

        for triple in SUPPORTED_EXEC_TRIPLES:
            exec_triple = _parse_triple(triple)

            cargo_sha = None
            for tool_name in ["rustc", "clippy", "cargo", "rustfmt"]:
                archive_path, sha256 = _sha_for(
                    tool_name,
                    version.base,
                    version.iso_date,
                    exec_triple,
                )
                version_sha256s[archive_path] = sha256
                if tool_name == "cargo":
                    cargo_sha = sha256

            if cargo_sha == None:
                fail("Could not determine cargo sha for {}".format(triple))

            triple_suffix = exec_triple.system + "_" + exec_triple.arch

            rust_toolchain_artifacts(
                name = "rust_toolchain_artifacts_{}_{}".format(triple_suffix, version_key),
                exec_triple = triple,
                version = version.version,
                sha256s = version_sha256s,
            )

            cargo_name = "cargo_{}_{}".format(triple_suffix, version_key)
            if host_cargo_repo == None and exec_triple.arch == host_arch and exec_triple.system == host_os:
                host_cargo_repo = cargo_name

            cargo_repository(
                name = cargo_name,
                exec_triple = triple,
                version = version.base,
                iso_date = version.iso_date,
                sha256 = cargo_sha,
            )

        for target_triple in SUPPORTED_TARGET_TRIPLES:
            _, sha256 = _sha_for(
                "rust-std",
                version.base,
                version.iso_date,
                _parse_triple(target_triple),
            )
            stdlib_repository(
                name = "rust_stdlib_{}_{}".format(sanitize_triple(target_triple), version_key),
                target_triple = target_triple,
                version = version.base,
                iso_date = version.iso_date,
                sha256 = sha256,
            )

        toolchains_repository(
            name = "experimental_rust_toolchains_{}".format(version_key),
            version = version.version,
            edition = version.edition,
        )

    host_tools_repository(
        name = "rs_rust_host_tools",
        host_cargo_repo = host_cargo_repo,
        binary_suffix = ".exe" if host_os == "windows" else "",
    )

    kwargs = {"reproducible": True}

    if hasattr(mctx, "facts"):
        kwargs["facts"] = new_facts

    return mctx.extension_metadata(**kwargs)

toolchains = module_extension(
    implementation = _toolchains_impl,
    tag_classes = {"toolchain": _TOOLCHAIN_TAG},
)
