def _crate_annotation(
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
        crate_features_select = {},
        gen_binaries = [],
        rustc_flags = [],
        rustc_flags_select = {},
        patch_args = [],
        patch_tool = None,
        patches = [],
        strip_prefix = None,
        workspace_cargo_toml = "Cargo.toml"):
    return struct(
        additive_build_file = additive_build_file,
        additive_build_file_content = additive_build_file_content,
        gen_build_script = gen_build_script,
        build_script_data = build_script_data,
        build_script_data_select = build_script_data_select,
        build_script_env = build_script_env,
        build_script_env_select = build_script_env_select,
        build_script_tools = build_script_tools,
        build_script_tools_select = build_script_tools_select,
        build_script_toolchains = build_script_toolchains,
        build_script_tags = build_script_tags,
        data = data,
        deps = deps,
        tags = tags,
        crate_features = crate_features,
        crate_features_select = crate_features_select,
        gen_binaries = gen_binaries,
        rustc_flags = rustc_flags,
        rustc_flags_select = rustc_flags_select,
        patch_args = patch_args,
        patch_tool = patch_tool,
        patches = patches,
        strip_prefix = strip_prefix,
        workspace_cargo_toml = workspace_cargo_toml,
    )

_DEFAULT_CRATE_ANNOTATION = _crate_annotation()

_WINDOWS_GNULLVM_IMPLICIT_ANNOTATION = _crate_annotation(
    additive_build_file_content = """
load("@rules_cc//cc:defs.bzl", "cc_import")

cc_import(
    name = "windows_import_lib",
    static_library = glob(["lib/*.a"])[0],
)
""",
    gen_build_script = "off",
    deps = [":windows_import_lib"],
)

_IMPLICIT_ANNOTATIONS_BY_CRATE = {
    # These crates publish the needed import library in their package archive.
    # Treat the well-known snippet as a built-in default so users do not need
    # to include it manually.
    "windows_aarch64_gnullvm": _WINDOWS_GNULLVM_IMPLICIT_ANNOTATION,
    "windows_x86_64_gnullvm": _WINDOWS_GNULLVM_IMPLICIT_ANNOTATION,
}

def annotation_for(annotations_by_crate, crate_name, version):
    """Return the annotation matching crate/version, falling back to '*' or default."""
    version_map = annotations_by_crate.get(crate_name, {})
    return (
        version_map.get(version) or
        version_map.get("*") or
        _IMPLICIT_ANNOTATIONS_BY_CRATE.get(crate_name, _DEFAULT_CRATE_ANNOTATION)
    )

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
