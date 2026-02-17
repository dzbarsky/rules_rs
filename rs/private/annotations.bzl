_DEFAULT_CRATE_ANNOTATION = struct(
    additive_build_file = None,
    additive_build_file_content = "",
    gen_build_script = "auto",
    build_script_data = [],
    build_script_data_select = {},
    build_script_env = {},
    build_script_env_select = {},
    build_script_tools = [],
    build_script_tools_select = {},
    build_script_toolchains = [],
    build_script_tags = [],
    data = [],
    deps = [],
    tags = [],
    crate_features = [],
    gen_binaries = [],
    rustc_flags = [],
    patch_args = [],
    patch_tool = None,
    patches = [],
    strip_prefix = None,
    workspace_cargo_toml = "Cargo.toml",
)

def annotation_for(annotations_by_crate, crate_name, version):
    """Return the annotation matching crate/version, falling back to '*' or default."""
    version_map = annotations_by_crate.get(crate_name, {})
    return version_map.get(version) or version_map.get("*", _DEFAULT_CRATE_ANNOTATION)

def build_annotation_map(mod, cfg_name):
    """Build mapping {crate: {version|\"*\": annotation}} for a cfg name."""
    annotations = {}
    for annotation in mod.tags.annotation:
        if cfg_name not in (annotation.repositories or [cfg_name]):
            continue

        version_key = annotation.version or "*"
        crate_map = annotations.setdefault(annotation.crate, {})
        if version_key in crate_map:
            fail("Duplicate crate.annotation for %s version %s in repo %s" % (annotation.crate, version_key, cfg_name))
        crate_map[version_key] = annotation
    return annotations

def format_well_known_annotation(crate, annotation):
    target = annotation.target
    idx = target.find("//")
    if idx == -1:
        module_name = target[1:]
    else:
        module_name = target[1:idx]

    return """\
bazel_dep(name = "{module_name}", version = "{module_version}")

crate.annotation(
    crate = "{crate}",
    gen_build_script = "off",
    deps = ["{target}"],
)

inject_repo(crate, "{module_name}")""".format(
        crate = crate,
        target = target,
        module_name = module_name,
        module_version = annotation.module_version,
    )

def _bazel_dep(target, module_version):
    return struct(
        target = target,
        module_version = module_version,
    )

WELL_KNOWN_ANNOTATIONS = {
    "alsa-sys": _bazel_dep("@alsa_lib", "1.2.9.bcr.4"),
    "atk-sys": _bazel_dep("@at-spi2-core//atk", "2.58.2"),
    "bzip2-sys": _bazel_dep("@bzip2//:bz2", "1.0.8.bcr.3"),
    "cairo-sys-rs": _bazel_dep("@cairo", "1.18.4"),
    "gdk-pixbuf-sys": _bazel_dep("@gdk-pixbuf", "2.44.4"),
    "gio-sys": _bazel_dep("@glib//gio", "2.82.2.bcr.7"),
    "glib-sys": _bazel_dep("@glib//glib", "2.82.2.bcr.7"),
    "gobject-sys": _bazel_dep("@glib//gobject", "2.82.2.bcr.7"),
    "libz-sys": _bazel_dep("@zlib", "1.3.1.bcr.8"),
    "libgit2-sys": _bazel_dep("@libgit2", "1.9.1"),
    "lzma-sys": _bazel_dep("@xz//:lzma", "5.4.5.bcr.7"),
    "tikv-jemalloc-sys": _bazel_dep("@jemalloc", "5.3.0-bcr.alpha.4"),
    "zstd-sys": _bazel_dep("@zstd", "1.5.7.bcr.1"),
}
