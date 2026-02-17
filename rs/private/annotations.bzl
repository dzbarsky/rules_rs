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

def well_known_annotation_snippet_paths(mctx):
    """Returns {crate: snippet_path} for crates with include.MODULE.bazel snippets."""
    return {
        crate_dir.basename: crate_dir.get_child("include.MODULE.bazel")
        for crate_dir in mctx.path(Label("//:3rd_party")).readdir()
    }
