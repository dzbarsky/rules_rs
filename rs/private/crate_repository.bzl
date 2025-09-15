load("@bazel_tools//tools/build_defs/repo:cache.bzl", "get_default_canonical_id")

def run_toml2json(ctx, toml2json, toml_file):
    if type(toml2json) == "path":
        # Non-hermetic fastpath; `cargo install toml2json`
        ctx.read(toml_file)
        result = ctx.execute([toml2json, toml_file])
        if result.return_code != 0:
            fail(result.stdout)

        return json.decode(result.stdout)

    data = ctx.read(toml_file)
    result = ctx.execute_wasm(toml2json, "toml2json", input=data)
    if result.return_code != 0:
        fail(result.output)

    return json.decode(result.output)

# Keep in sync with below
def prune_cargo_toml_json(cargo_toml_json):
   package = cargo_toml_json.get("package", {})
   lib = cargo_toml_json.get("lib", {})

   return dict(
       package = dict(
           metadata = dict(
               bazel = package.get("metadata", {}).get("bazel", {}),
           ),
           build = package.get("build"),
           edition = package.get("edition"),
           links = package.get("links"),
       ),
       lib = dict(
           name = lib.get("name"),
           proc_macro = lib.get("proc-macro") or lib.get("proc_macro"),
           path = lib.get("path"),
       ),
   )

def generate_build_file(attr, cargo_toml):
    package = cargo_toml.get("package", {})
    bazel_metadata = package.get("metadata", {}).get("bazel", {})

    build_script = package.get("build")
    if build_script:
        build_script = build_script.removeprefix("./")
    if bazel_metadata.get("gen_build_script") == False:
        build_script = False

    lib = cargo_toml.get("lib", {})
    is_proc_macro = lib.get("proc-macro") or lib.get("proc_macro") or False
    lib_path = (lib.get("path") or "src/lib.rs").removeprefix("./")

    edition = package.get("edition")
    if not edition or (type(edition) == "dict" and edition.get("workspace") == True):
        edition = attr.fallback_edition

    crate_name = lib.get("name")
    links = package.get("links")

    build_content = """
load("@rules_rs//rs:rust_crate.bzl", "rust_crate")

rust_crate(
    name = {crate},
    crate_name = {crate_name},
    version = {version},
    aliases = {{
        {aliases}
    }}{conditional_aliases},
    deps = [
        {deps}
    ]{conditional_deps},
    extra_deps = {extra_deps},
    data = [
        {data}
    ],
    proc_macro_deps = [
        {proc_macro_deps}
    ],
    crate_features = {crate_features}{conditional_crate_features},
    crate_root = {lib_path},
    edition = {edition},
    rustc_flags = {rustc_flags},
    target_compatible_with = select({{
        {target_compatible_with},
        "//conditions:default": ["@platforms//:incompatible"],
    }}),
    links = {links},
    build_script = {build_script},
    build_script_data = [
        {build_script_data}
    ],
    build_deps = [
        {build_deps}
    ],
    build_script_env = {build_script_env},
    build_script_toolchains = {build_script_toolchains},
    proc_macro_build_deps = [
        {proc_macro_build_deps}
    ],
    is_proc_macro = {is_proc_macro},
)

"""

    build_content += bazel_metadata.get("additive_build_file_content", "")

    return build_content.format(
        crate = repr(attr.crate),
        crate_name = repr(crate_name),
        version = repr(attr.version),
        aliases = ",\n        ".join(['"%s": "%s"' % (k, v) for (k, v) in attr.aliases.items()]),
        conditional_aliases = attr.conditional_aliases,
        deps = ",\n        ".join(['"%s"' % d for d in attr.deps]),
        extra_deps = repr(bazel_metadata.get("deps", [])),
        conditional_deps = attr.conditional_deps,
        data = ",\n        ".join(['"%s"' % d for d in attr.data]),
        proc_macro_deps = ",\n        ".join(['"%s"' % d for d in attr.proc_macro_deps]),
        crate_features = attr.crate_features,
        conditional_crate_features = attr.conditional_crate_features,
        lib_path = repr(lib_path),
        edition = repr(edition),
        rustc_flags = repr(attr.rustc_flags or []),
        target_compatible_with = ",\n        ".join(['"%s": []' % t for t in attr.target_compatible_with]),
        links = repr(links),
        build_script = repr(build_script),
        build_script_data = ",\n        ".join(['"%s"' % d for d in attr.build_script_data]),
        build_deps = ",\n        ".join(['"%s"' % d for d in attr.build_deps]),
        build_script_env = repr(attr.build_script_env),
        build_script_toolchains = repr([str(t) for t in attr.build_script_toolchains]),
        proc_macro_build_deps = ",\n        ".join(['"%s"' % d for d in attr.proc_macro_build_deps]),
        is_proc_macro = repr(is_proc_macro),
    )

def _crate_repository_impl(rctx):
    rctx.download_and_extract(
        rctx.attr.url,
        type = "tar.gz",
        canonical_id = get_default_canonical_id(rctx, urls = [rctx.attr.url]),
        strip_prefix = rctx.attr.strip_prefix,
        sha256 = rctx.attr.checksum,
    )

    toml2json = rctx.which("toml2json")
    if not toml2json:
        toml2json = rctx.load_wasm(rctx.attr._toml2json)

    cargo_toml = run_toml2json(rctx, toml2json, "Cargo.toml")

    rctx.file("BUILD.bazel", generate_build_file(rctx.attr, cargo_toml))

    return rctx.repo_metadata(reproducible = True)

crate_repository = repository_rule(
    implementation = _crate_repository_impl,
    attrs = {
        "crate": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "url": attr.string(mandatory = True),
        "strip_prefix": attr.string(mandatory = True),
        "checksum": attr.string(),
        "build_deps": attr.label_list(default = []),
        "build_script_data": attr.label_list(default = []),
        "build_script_env": attr.string_dict(),
        "build_script_toolchains": attr.label_list(),
        "rustc_flags": attr.string_list(),
        "proc_macro_deps": attr.string_list(default = []),
        "proc_macro_build_deps": attr.string_list(default = []),
        "data": attr.label_list(default = []),
        "deps": attr.string_list(default = []),
        "conditional_deps": attr.string(default = ""),
        "aliases": attr.string_dict(),
        "conditional_aliases": attr.string(default = ""),
        "crate_features": attr.string(mandatory = True),
        "conditional_crate_features": attr.string(default = ""),
        "target_compatible_with": attr.string_list(mandatory = True),
        "fallback_edition": attr.string(default = "2015"),
        "_toml2json": attr.label(default = "@rules_rs//toml2json:toml2json.wasm"),
    },
)
