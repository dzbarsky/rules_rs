"""Module extension for configuring experimental Rust toolchains."""

load("@rules_rust//rust/platform:triple.bzl", _parse_triple = "triple")
load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "DEFAULT_STATIC_RUST_URL_TEMPLATES",
    "check_version_valid",
    "produce_tool_suburl",
)
load("//rs/experimental/platforms:triples.bzl", "SUPPORTED_EXEC_TRIPLES", "SUPPORTED_TARGET_TRIPLES")
load("//rs/experimental/toolchains:toolchain_utils.bzl", "sanitize_triple", "sanitize_version")
load("//rs/private:cargo_repository.bzl", "cargo_repository")
load("//rs/private:clippy_repository.bzl", "clippy_repository")
load("//rs/private:host_tools_repository.bzl", "host_tools_repository")
load("//rs/private:rustc_repository.bzl", "rustc_repository")
load("//rs/private:rustfmt_repository.bzl", "rustfmt_repository")
load("//rs/private:stdlib_repository.bzl", "stdlib_repository")
load("//rs/private:toolchains_repository.bzl", "toolchains_repository")

_DEFAULT_RUSTC_VERSION = "1.92.0"
_DEFAULT_EDITION = "2021"
_DEFAULT_TOOLCHAIN_REPO_NAME = "default_rust_toolchains"

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

_TOOLCHAIN_TAG = tag_class(
    attrs = {
        "name": attr.string(
            doc = "Name of the generated toolchain repo.",
            default = _DEFAULT_TOOLCHAIN_REPO_NAME,
        ),
        "version": attr.string(
            doc = "Rust version (e.g. 1.86.0 or nightly/2025-04-03)",
            default = _DEFAULT_RUSTC_VERSION,
        ),
        "rustfmt_version": attr.string(
            doc = "Rustfmt version (e.g. 1.86.0 or nightly/2025-04-03)",
            default = "",
        ),
        "edition": attr.string(
            doc = "Default edition to apply to toolchains.",
            default = _DEFAULT_EDITION,
        ),
    },
)

def _parse_version(version):
    base_version = version
    iso_date = None
    if "/" in version:
        base_version, iso_date = version.split("/", 1)
    check_version_valid(base_version, iso_date)

    return base_version, iso_date

def _toolchains_impl(mctx):
    root_module_name = None
    for mod in mctx.modules:
        if mod.is_root:
            root_module_name = mod.name
            break

    version_tags = []
    had_tags = True
    for mod in mctx.modules:
        for tag in mod.tags.toolchain:
            version_tags.append(tag)

    if not version_tags:
        had_tags = False
        version_tags.append(struct(
            name = _DEFAULT_TOOLCHAIN_REPO_NAME,
            version = _DEFAULT_RUSTC_VERSION,
            rustfmt_version = "",
            edition = _DEFAULT_EDITION,
        ))

    versions = set([])
    rustfmt_versions = set([])

    for tag in version_tags:
        versions.add(tag.version)
        rustfmt_versions.add(tag.rustfmt_version or tag.version)

    existing_facts = getattr(mctx, "facts", {}) or {}
    pending_downloads = {}
    new_facts = {}

    def _request_sha(tool_name, version, iso_date, target_triple):
        archive_path = _archive_path(tool_name, target_triple, version, iso_date)
        if archive_path in new_facts or archive_path in pending_downloads:
            return

        existing = existing_facts.get(archive_path)
        if existing:
            new_facts[archive_path] = existing
            return

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

    # First pass: enqueue all sha downloads we don't already have.
    for version in versions:
        base_version, iso_date = _parse_version(version)

        for triple in SUPPORTED_EXEC_TRIPLES:
            exec_triple = _parse_triple(triple)
            for tool_name in ["rustc", "clippy", "cargo"]:
                _request_sha(tool_name, base_version, iso_date, exec_triple)

        for target_triple in SUPPORTED_TARGET_TRIPLES:
            _request_sha("rust-std", base_version, iso_date, _parse_triple(target_triple))

    for version in rustfmt_versions:
        base_version, iso_date = _parse_version(version)

        for triple in SUPPORTED_EXEC_TRIPLES:
            exec_triple = _parse_triple(triple)

            # Rustfmt dynamically links against components in rustc, so we need both.
            for tool_name in ["rustc", "rustfmt"]:
                _request_sha(tool_name, base_version, iso_date, exec_triple)

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
        return new_facts[archive_path]

    host_os = _normalize_os_name(mctx.os.name)
    host_arch = _normalize_arch_name(mctx.os.arch)
    host_cargo_repo = None

    for version in versions | rustfmt_versions:
        version_key = sanitize_version(version)
        base_version, iso_date = _parse_version(version)

        for triple in SUPPORTED_EXEC_TRIPLES:
            exec_triple = _parse_triple(triple)

            triple_suffix = exec_triple.system + "_" + exec_triple.arch
            rustc_name = "rustc_{}_{}".format(triple_suffix, version_key)

            rustc_repository(
                name = rustc_name,
                triple = triple,
                version = base_version,
                iso_date = iso_date,
                sha256 = _sha_for("rustc", base_version, iso_date, exec_triple),
            )

            if version in versions:
                cargo_name = "cargo_{}_{}".format(triple_suffix, version_key)
                if host_cargo_repo == None and exec_triple.arch == host_arch and exec_triple.system == host_os:
                    host_cargo_repo = cargo_name

                cargo_repository(
                    name = cargo_name,
                    triple = triple,
                    version = base_version,
                    iso_date = iso_date,
                    sha256 = _sha_for("cargo", base_version, iso_date, exec_triple),
                )

                clippy_repository(
                    name = "clippy_{}_{}".format(triple_suffix, version_key),
                    triple = triple,
                    version = base_version,
                    iso_date = iso_date,
                    sha256 = _sha_for("clippy", base_version, iso_date, exec_triple),
                    rustc_repo_build_file = "@rustc_{}_{}//:BUILD.bazel".format(triple_suffix, version_key),
                )

        if version in versions:
            for target_triple in SUPPORTED_TARGET_TRIPLES:
                stdlib_repository(
                    name = "rust_stdlib_{}_{}".format(sanitize_triple(target_triple), version_key),
                    triple = target_triple,
                    version = base_version,
                    iso_date = iso_date,
                    sha256 = _sha_for("rust-std", base_version, iso_date, _parse_triple(target_triple)),
                )

    for version in rustfmt_versions:
        version_key = sanitize_version(version)
        base_version, iso_date = _parse_version(version)

        for triple in SUPPORTED_EXEC_TRIPLES:
            exec_triple = _parse_triple(triple)
            triple_suffix = exec_triple.system + "_" + exec_triple.arch

            rustfmt_repository(
                name = "rustfmt_{}_{}".format(triple_suffix, version_key),
                triple = triple,
                version = base_version,
                iso_date = iso_date,
                sha256 = _sha_for("rustfmt", base_version, iso_date, exec_triple),
                rustc_repo_build_file = "@rustc_{}_{}//:BUILD.bazel".format(triple_suffix, version_key),
            )

    host_tools_repository(
        name = "rs_rust_host_tools",
        host_cargo_repo = host_cargo_repo,
        binary_suffix = ".exe" if host_os == "windows" else "",
    )

    # `rs_rust_host_tools` is an implementation detail of rules_rs itself.
    # Report it as a direct dependency only for the rules_rs root module so
    # user modules are not asked to import it.
    direct_deps = ["rs_rust_host_tools"] if root_module_name == "rules_rs" else []
    direct_dev_deps = []
    repo_configs = {}
    for tag in version_tags:
        repo_name = tag.name
        rustfmt_version = tag.rustfmt_version or tag.version
        existing = repo_configs.get(repo_name)
        if existing and (
            existing.version != tag.version or
            (existing.rustfmt_version or existing.version) != rustfmt_version or
            existing.edition != tag.edition
        ):
            fail("Toolchain repo {} has conflicting tag configurations".format(repo_name))

        if not existing:
            repo_configs[repo_name] = tag
            toolchains_repository(
                name = repo_name,
                version = tag.version,
                rustfmt_version = rustfmt_version,
                edition = tag.edition,
            )
        is_dev_dependency = had_tags and mctx.is_dev_dependency(tag)
        if is_dev_dependency:
            if repo_name not in direct_dev_deps:
                direct_dev_deps.append(repo_name)
        elif repo_name not in direct_deps:
            direct_deps.append(repo_name)

    kwargs = dict(
        reproducible = True,
        root_module_direct_deps = direct_deps,
        root_module_direct_dev_deps = direct_dev_deps,
    )

    if hasattr(mctx, "facts"):
        kwargs["facts"] = new_facts

    return mctx.extension_metadata(**kwargs)

toolchains = module_extension(
    implementation = _toolchains_impl,
    tag_classes = {"toolchain": _TOOLCHAIN_TAG},
)
