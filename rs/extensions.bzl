load("@bazel_tools//tools/build_defs/repo:cache.bzl", "get_default_canonical_id")

def _sanitize_crate(name):
    return name.replace("+", "_")

def _generate_hub_and_spokes(
        mctx,
        hub_name,
        data,
        ):
    """Generates repositories for the transitive closure of the Cargo workspace.

    Args:
        mctx (module_ctx): The module context object.
        hub_name (string): name
        data (object): Cargo.lock in json format
    """

    packages = data["package"]

    download_tokens = []
    files = []

    versions_by_name = dict()
    for package in packages:
        source = package.get("source")
        if not source:
            # Not from crates.io
            continue

        name = package["name"]
        version = package["version"]
        
        versions = versions_by_name.get(name, [])
        if not versions:
            versions_by_name[name] = versions
        versions.append(version)
        
        # TODO(zbarsky): Persist these in lockfile facts?
        url = "https://crates.io/api/v1/crates/{}/{}".format(name, version)
        file = "{}_{}.json".format(name, version)
        token = mctx.download(
            url,
            file,
            canonical_id = get_default_canonical_id(mctx, urls = [url]),
            block = False)
        download_tokens.append(token)
        files.append(file)

        url += "/dependencies"
        file = "{}_{}_dependencies.json".format(name, version)
        token = mctx.download(
            url,
            file,
            canonical_id = get_default_canonical_id(mctx, urls = [url]),
            block = False)
        download_tokens.append(token)
        #print(name, version, source) #package.get("dependencies"))

    mctx.report_progress("Downloading metadata")
    for token in download_tokens:
        result = token.wait()
        if not result.success:
            fail("Could not download")

    # TODO(zbarsky): Compute features
    mctx.report_progress("Computing features")
    
    mctx.report_progress("Initializing hub and spokes")
    for package in packages:
        source = package.get("source")
        if not source:
            # Not from crates.io
            continue

        name = package["name"]
        version = package["version"]
        checksum = package["checksum"]

        resolved_versions = {}
        for dep in package.get("dependencies", []):
            if " " not in dep:
                # Only one version
                resolved_version = versions_by_name[dep][0]
            else:
                dep, resolved_version = dep.split(" ")
            resolved_versions[dep] = resolved_version

        file = "{}_{}.json".format(name, version)
        data = json.decode(mctx.read(file))["version"]
        #print(data)

        dependencies = json.decode(mctx.read(file.replace(".json", "_dependencies.json")))["dependencies"]
        
        deps = []
        windows_deps = []
        linux_deps = []
        osx_deps = []

        for dep in dependencies:
            # Drop dev deps
            if dep["kind"] == "dev":
                continue

            dep_name = dep["crate_id"]
            if dep_name not in resolved_versions:
                print("NOT FOUND", dep)
                continue

            bazel_target = _sanitize_crate("@{}//:{}_{}".format(hub_name, dep_name, resolved_versions[dep_name]))

            # TODO(zbarsky): Real parser?
            target = dep["target"]
            if not target or target == "cfg(any())":
                deps.append(bazel_target)
            elif target == "cfg(windows)" or target == 'cfg(target_os = "windows")':
                windows_deps.append(bazel_target)
            elif target == "cfg(unix)" or target == 'cfg(not(windows))':
                linux_deps.append(bazel_target)
                osx_deps.append(bazel_target)
            elif target == 'cfg(target_os = "linux")':
                linux_deps.append(bazel_target)
            elif target == 'cfg(target_os = "macos")':
                osx_deps.append(bazel_target)

        _crate_repository(
            name = _sanitize_crate("{}__{}_{}".format(hub_name, name, version)),
            crate = name,
            version = version,
            checksum = checksum,
            deps = deps,
            windows_deps = windows_deps,
            linux_deps = linux_deps,
            osx_deps = osx_deps,
        )
        print(name, deps, windows_deps, linux_deps, osx_deps)

    hub_contents = []
    for name, versions in versions_by_name.items():
        for version in versions:
            qualified_name = _sanitize_crate("{}_{}").format(name, version)
            spoke_name = "@{}__{}//:{}".format(hub_name, qualified_name, name)
            hub_contents.append("""
alias(
    name = "{}",
    actual = "{}",
    visibility = ["//visibility:public"],
)""".format(
        qualified_name, spoke_name,
    ))

        if len(versions) == 1:
            hub_contents.append("""
alias(
    name = "{}",
    actual = ":{}",
    visibility = ["//visibility:public"],
)""".format(
        name, qualified_name,
    ))

    print("\n".join(hub_contents))

    _hub_repo(
        name = hub_name,
        contents = {
            "BUILD.bazel": "\n".join(hub_contents),
        },
    )

def _crate_impl(mctx):
    mctx.file("convert.py", """
import sys
import tomllib
import json

with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)

print(json.dumps(data, indent=2))
""")

    direct_deps = []
    for mod in mctx.modules:
        if not mod.tags.from_cargo:
            fail("`.from_specs` is required. Please update {}".format(mod.name))

        for cfg in mod.tags.from_cargo:
            direct_deps.append(cfg.name)
            result = mctx.execute(["python", "convert.py", cfg.cargo_lock])
            if result.return_code != 0:
                fail(result.stdout + "\n" + result.stderr)

            data = json.decode(result.stdout)
            _generate_hub_and_spokes(mctx, cfg.name, data)

    return mctx.extension_metadata(
        root_module_direct_deps = direct_deps,
        root_module_direct_dev_deps = [],
        reproducible = True,
    )


_from_cargo = tag_class(
    doc = "Generates a repo @crates from a Cargo.toml / Cargo.lock pair.",
    # Ordering is controlled for readability in generated docs.
    attrs = {
        "name": attr.string(
            doc = "The name of the repo to generate",
            default = "crates",
        ),
    } | {
        "cargo_toml": attr.label(),
        "cargo_lock": attr.label(),
    },
)

_relative_label_list = attr.string

# This should be kept in sync with crate_universe/private/crate.bzl.
_annotation = tag_class(
    doc = "A collection of extra attributes and settings for a particular crate.",
    attrs = {
        "additive_build_file": attr.label(
            doc = "A file containing extra contents to write to the bottom of generated BUILD files.",
        ),
        "additive_build_file_content": attr.string(
            doc = "Extra contents to write to the bottom of generated BUILD files.",
        ),
        "alias_rule": attr.string(
            doc = "Alias rule to use instead of `native.alias()`.  Overrides [render_config](#render_config)'s 'default_alias_rule'.",
        ),
        "build_script_data": _relative_label_list(
            doc = "A list of labels to add to a crate's `cargo_build_script::data` attribute.",
        ),
        "build_script_data_glob": attr.string_list(
            doc = "A list of glob patterns to add to a crate's `cargo_build_script::data` attribute",
        ),
        "build_script_data_select": attr.string_list_dict(
            doc = "A list of labels to add to a crate's `cargo_build_script::data` attribute. Keys should be the platform triplet. Value should be a list of labels.",
        ),
        "build_script_deps": _relative_label_list(
            doc = "A list of labels to add to a crate's `cargo_build_script::deps` attribute.",
        ),
        "build_script_env": attr.string_dict(
            doc = "Additional environment variables to set on a crate's `cargo_build_script::env` attribute.",
        ),
        "build_script_env_select": attr.string_dict(
            doc = "Additional environment variables to set on a crate's `cargo_build_script::env` attribute. Key should be the platform triplet. Value should be a JSON encoded dictionary mapping variable names to values, for example `{\"FOO\": \"bar\"}`.",
        ),
        "build_script_link_deps": _relative_label_list(
            doc = "A list of labels to add to a crate's `cargo_build_script::link_deps` attribute.",
        ),
        "build_script_proc_macro_deps": _relative_label_list(
            doc = "A list of labels to add to a crate's `cargo_build_script::proc_macro_deps` attribute.",
        ),
        "build_script_rundir": attr.string(
            doc = "An override for the build script's rundir attribute.",
        ),
        "build_script_rustc_env": attr.string_dict(
            doc = "Additional environment variables to set on a crate's `cargo_build_script::env` attribute.",
        ),
        "build_script_toolchains": attr.label_list(
            doc = "A list of labels to set on a crates's `cargo_build_script::toolchains` attribute.",
        ),
        "build_script_tools": _relative_label_list(
            doc = "A list of labels to add to a crate's `cargo_build_script::tools` attribute.",
        ),
        "compile_data": _relative_label_list(
            doc = "A list of labels to add to a crate's `rust_library::compile_data` attribute.",
        ),
        "compile_data_glob": attr.string_list(
            doc = "A list of glob patterns to add to a crate's `rust_library::compile_data` attribute.",
        ),
        "compile_data_glob_excludes": attr.string_list(
            doc = "A list of glob patterns to be excllued from a crate's `rust_library::compile_data` attribute.",
        ),
        "crate": attr.string(
            doc = "The name of the crate the annotation is applied to",
            mandatory = True,
        ),
        "crate_features": attr.string_list(
            doc = "A list of strings to add to a crate's `rust_library::crate_features` attribute.",
        ),
        "data": _relative_label_list(
            doc = "A list of labels to add to a crate's `rust_library::data` attribute.",
        ),
        "data_glob": attr.string_list(
            doc = "A list of glob patterns to add to a crate's `rust_library::data` attribute.",
        ),
        "deps": _relative_label_list(
            doc = "A list of labels to add to a crate's `rust_library::deps` attribute.",
        ),
        "disable_pipelining": attr.bool(
            doc = "If True, disables pipelining for library targets for this crate.",
        ),
        "extra_aliased_targets": attr.string_dict(
            doc = "A list of targets to add to the generated aliases in the root crate_universe repository.",
        ),
        "gen_all_binaries": attr.bool(
            doc = "If true, generates `rust_binary` targets for all of the crates bins",
        ),
        "gen_binaries": attr.string_list(
            doc = "As a list, the subset of the crate's bins that should get `rust_binary` targets produced.",
        ),
        #"gen_build_script": attr.string(
        #    doc = "An authoritative flag to determine whether or not to produce `cargo_build_script` targets for the current crate. Supported values are 'on', 'off', and 'auto'.",
        #    values = _OPT_BOOL_VALUES.keys(),
        #    default = "auto",
        #),
        "override_target_bin": attr.label(
            doc = "An optional alternate target to use when something depends on this crate to allow the parent repo to provide its own version of this dependency.",
        ),
        "override_target_build_script": attr.label(
            doc = "An optional alternate target to use when something depends on this crate to allow the parent repo to provide its own version of this dependency.",
        ),
        "override_target_lib": attr.label(
            doc = "An optional alternate target to use when something depends on this crate to allow the parent repo to provide its own version of this dependency.",
        ),
        "override_target_proc_macro": attr.label(
            doc = "An optional alternate target to use when something depends on this crate to allow the parent repo to provide its own version of this dependency.",
        ),
        "patch_args": attr.string_list(
            doc = "The `patch_args` attribute of a Bazel repository rule. See [http_archive.patch_args](https://docs.bazel.build/versions/main/repo/http.html#http_archive-patch_args)",
        ),
        "patch_tool": attr.string(
            doc = "The `patch_tool` attribute of a Bazel repository rule. See [http_archive.patch_tool](https://docs.bazel.build/versions/main/repo/http.html#http_archive-patch_tool)",
        ),
        "patches": attr.label_list(
            doc = "The `patches` attribute of a Bazel repository rule. See [http_archive.patches](https://docs.bazel.build/versions/main/repo/http.html#http_archive-patches)",
        ),
        "proc_macro_deps": _relative_label_list(
            doc = "A list of labels to add to a crate's `rust_library::proc_macro_deps` attribute.",
        ),
        "repositories": attr.string_list(
            doc = "A list of repository names specified from `crate.from_cargo(name=...)` that this annotation is applied to. Defaults to all repositories.",
            default = [],
        ),
        "rustc_env": attr.string_dict(
            doc = "Additional variables to set on a crate's `rust_library::rustc_env` attribute.",
        ),
        "rustc_env_files": _relative_label_list(
            doc = "A list of labels to set on a crate's `rust_library::rustc_env_files` attribute.",
        ),
        "rustc_flags": attr.string_list(
            doc = "A list of strings to set on a crate's `rust_library::rustc_flags` attribute.",
        ),
        "shallow_since": attr.string(
            doc = "An optional timestamp used for crates originating from a git repository instead of a crate registry. This flag optimizes fetching the source code.",
        ),
        "version": attr.string(
            doc = "The versions of the crate the annotation is applied to. Defaults to all versions.",
            default = "*",
        ),
    },
)

crate = module_extension(
    implementation = _crate_impl,
    tag_classes = {
        "annotation": _annotation,
        "from_cargo": _from_cargo,
    },
)


def _crate_repository_impl(rctx):
    crate = rctx.attr.crate
    version = rctx.attr.version
    checksum = rctx.attr.checksum
    deps = rctx.attr.deps

    # Compute the URL
    url = "https://crates.io/api/v1/crates/{}/{}/download".format(crate, version)
    rctx.download_and_extract(
        url,
        type = "tar.gz",
        canonical_id = get_default_canonical_id(rctx, urls = [url]),
        strip_prefix = "{}-{}".format(crate, version),
        sha256 = checksum,
    )

    # Create a BUILD file with a deps attribute
    build_content = """
load("@rules_rust//cargo:defs.bzl", "cargo_toml_env_vars")
load("@rules_rust//rust:defs.bzl", "rust_library")

package(default_visibility = ["//visibility:public"])

cargo_toml_env_vars(
    name = "cargo_toml_env_vars",
    src = "Cargo.toml",
)

rust_library(
    name = {crate},
    srcs = glob(
        include = ["**/*.rs"],
        allow_empty = True,
    ),
    deps = [
        {deps}
    ],
    compile_data = glob(
        include = ["**"],
        allow_empty = True,
        exclude = [
            "**/* *",
            ".tmp_git_root/**/*",
            "BUILD",
            "BUILD.bazel",
            "WORKSPACE",
            "WORKSPACE.bazel",
        ],
    ),
    crate_root = "src/lib.rs",
    edition = "2021",
    rustc_env_files = [
        ":cargo_toml_env_vars",
    ],
    rustc_flags = [
        "--cap-lints=allow",
    ],
    tags = [
        "crate-name=adler2",
        "manual",
        "noclippy",
        "norustfmt",
    ],
    version = {version}
)
""".format(
    crate = repr(crate),
    version = repr(version),
    deps = ",\n        ".join(['"%s"' % d for d in deps]),
)

    rctx.file("BUILD.bazel", build_content)

_crate_repository = repository_rule(
    implementation = _crate_repository_impl,
    attrs = {
        "crate": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "checksum": attr.string(mandatory = True),
        "deps": attr.string_list(default = []),
        "windows_deps": attr.string_list(default = []),
        "linux_deps": attr.string_list(default = []),
        "osx_deps": attr.string_list(default = []),
    },
)

def _hub_repo_impl(rctx):
    for path, contents in rctx.attr.contents.items():
        rctx.file(path, contents)
    rctx.file("WORKSPACE.bazel", """workspace(name = "{}")""".format(
        rctx.name,
    ))

_hub_repo = repository_rule(
    implementation = _hub_repo_impl,
    attrs = {
        "contents": attr.string_dict(
            doc = "A mapping of file names to text they should contain.",
            mandatory = True,
        ),
    },
)