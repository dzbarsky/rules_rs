load("@bazel_tools//tools/build_defs/repo:cache.bzl", "get_default_canonical_id")

# TODO(zbarsky): Don't see any way in the API response to determine if a crate is a proc_macro :(
# We only find out once we download the Cargo.toml, which is inside the spoke repo, which is too late.
# For now just hardcode it; try to get crates.io fixed to tell us
_PROC_MACROS = set([
    "arg_enum_proc_macro",
    "asn1-rs-derive",
    "asn1-rs-impl",
    "async-attributes",
    "async-generic",
    "async-recursion",
    "async-stream-impl",
    "async-trait",
    "auto_enums",
    "bytecheck_derive",
    "clap_derive",
    "clap_derive",
    "clickhouse-derive",
    "const-random-macro",
    "const_fn",
    "ctor-proc-macro",
    "cxxbridge-macro",
    "darling_macro",
    "data-encoding-macro-internal",
    "delegate",
    "derivative",
    "derive-new ",
    "derive-new",
    "derive_builder_macro",
    "derive_more",
    "derive_more-impl",
    "displaydoc",
    "document-features",
    "enum-as-inner",
    "enum_dispatch",
    "enumflags2_derive",
    "equator-macro",
    "err-derive",
    "foreign-types-macros",
    "futures-macro",
    "indoc",
    "macro_rules_attribute-proc_macro",
    "maybe-async",
    "mockall_derive",
    "monostate-impl",
    "neli-proc-macros",
    "noop_proc_macro",
    "num-derive",
    "openssl-macros",
    "paste",
    "pest_derive",
    "pin-project-internal",
    "proc-macro-error-attr",
    "proc-macro-error-attr2",
    "proc-macro-hack",
    "profiling-procmacros",
    "prost-derive",
    "prost-reflect-derive",
    "ptr_meta_derive",
    "pyo3-macros",
    "pyo3-stub-gen-derive",
    "rasn-derive",
    "ref-cast-impl",
    "rkyv_derive",
    "rustversion",
    "sealed",
    "seq-macro",
    "serde_derive",
    "serde_repr",
    "serde_with_macros",
    "serial_test_derive",
    "simd_helpers",
    "snafu-derive",
    "static-iref",
    "static-regular-grammar",
    "stdweb-derive",
    "stdweb-internal-macros",
    "strum_macros",
    "test-case-macros",
    "test-log-macros",
    "thiserror-impl",
    "time-macros",
    "time-macros-impl",
    "tokio-macros",
    "tracing-attributes",
    "traitful",
    "typed-builder-macro",
    "typespec_macros",
    "wasm-bindgen-macro",
    "windows-implement",
    "windows-interface",
    "wstd-macro",
    "yoke-derive",
    "zbus_macros",
    "zerofrom-derive",
    "zeroize_derive",
    "zerovec-derive",
    "zvariant_derive",
])

_PROC_MACROS_EXCEPTIONS = {
    "derive_more": ["2.0.1"],
    "prost-derive": ["0.10.1"],
    "time-macros": ["0.1.1"],
}

def _sanitize_crate(name):
    return name.replace("+", "_")

def _select(windows = [], linux = [], osx = []):
    branches = []

    if windows:
        branches.append(("@platforms//os:windows", windows))

    if linux:
        branches.append(("@platforms//os:linux", linux))

    if osx:
        branches.append(("@platforms//os:osx", osx))

    if not branches:
        return ""

    branches.append(("//conditions:default", []))

    return """select({
        %s
    })""" % (
        ",\n        ".join(['"%s": %s' % (condition, repr(data)) for (condition, data) in branches])
    )

def _add_to_dict(d, k, v):
    existing = d.get(k, [])
    if not existing:
        d[k] = existing
    existing.extend(v)

def _fq_crate(name, version):
    return _sanitize_crate(name + "_" + version)

def _new_feature_resolutions(possible_deps, possible_dep_version_by_name, possible_features):
    return struct(
        features_enabled = set(),

        # TODO(zbarsky): Do these also need the platform-specific variants?
        build_deps = set(),
        proc_macro_deps = set(),
        proc_macro_build_deps = set(),
        deps = set(),
        windows_deps = set(),
        linux_deps = set(),
        osx_deps = set(),

        # Following data is immutable, it comes from crates.io + Cargo.lock
        possible_deps = possible_deps,
        possible_dep_version_by_name = possible_dep_version_by_name,
        possible_features = possible_features,
    )

def _count(feature_resolutions_by_fq_crate):
    n = 0
    for feature_resolutions in feature_resolutions_by_fq_crate.values():
        n += len(feature_resolutions.features_enabled)
        n += len(feature_resolutions.build_deps)
        n += len(feature_resolutions.proc_macro_deps)
        n += len(feature_resolutions.proc_macro_build_deps)
        n += len(feature_resolutions.deps)
        n += len(feature_resolutions.windows_deps)
        n += len(feature_resolutions.linux_deps)
        n += len(feature_resolutions.osx_deps)

    print("Got count", n)
    return n

def _resolve_one_round(hub_name, feature_resolutions_by_fq_crate):
    # Resolution process always enables new crates/features so we can just count total enabled
    # instead of being careful about change tracking.
    initial_count = _count(feature_resolutions_by_fq_crate)

    for fq_crate, feature_resolutions in feature_resolutions_by_fq_crate.items():
        features_enabled = feature_resolutions.features_enabled

        deps = feature_resolutions.deps
        windows_deps = feature_resolutions.windows_deps
        linux_deps = feature_resolutions.linux_deps
        osx_deps = feature_resolutions.osx_deps

        build_deps = feature_resolutions.build_deps
        proc_macro_build_deps = feature_resolutions.proc_macro_build_deps
        proc_macro_deps = feature_resolutions.proc_macro_deps

        possible_dep_version_by_name = feature_resolutions.possible_dep_version_by_name
        possible_features = feature_resolutions.possible_features

        # Propagate features across currently enabled dependencies.
        for dep in feature_resolutions.possible_deps:
            dep_name = dep["crate_id"]
            if dep.get("optional") and dep_name not in features_enabled:
                continue

            resolved_version = possible_dep_version_by_name.get(dep_name)
            if not resolved_version:
                # print("NOT FOUND", dep)
                continue

            bazel_target = _sanitize_crate("@{}//:{}_{}".format(hub_name, dep_name, resolved_version))

            proc_macro = dep_name in _PROC_MACROS and resolved_version not in _PROC_MACROS_EXCEPTIONS.get(dep_name, [])

            kind = dep.get("kind", "normal")
            if kind == "dev":
                # Drop dev deps
                continue
            elif kind == "build":
                if proc_macro:
                    proc_macro_build_deps.add(bazel_target)
                else:
                    build_deps.add(bazel_target)

            # TODO(zbarsky): Real parser?
            target = dep.get("target")
            if not target:
                if proc_macro:
                    proc_macro_deps.add(bazel_target)
                else:
                    deps.add(bazel_target)

                    # TODO(zbarsky): per-platform features?
                    dep_feature_resolutions = feature_resolutions_by_fq_crate[_fq_crate(dep_name, resolved_version)]
                    dep_feature_resolutions.features_enabled.update(dep.get("features", []))
                    if dep.get("default_features", True):
                        dep_feature_resolutions.features_enabled.add("default")

            elif target == "cfg(windows)" or target == 'cfg(target_os = "windows")':
                windows_deps.add(bazel_target)
            elif target == "cfg(unix)" or target == "cfg(not(windows))":
                linux_deps.add(bazel_target)
                osx_deps.add(bazel_target)
            elif target == 'cfg(target_os = "linux")':
                linux_deps.add(bazel_target)
            elif target == 'cfg(target_os = "macos")':
                osx_deps.add(bazel_target)

        # Enable any features that are implied by previously-enabled features.
        implied_features = [
            implied_feature.removeprefix("dep:")
            for enabled_feature in features_enabled
            for implied_feature in possible_features.get(enabled_feature, [])
        ]

        dep_features = [feature for feature in implied_features if "/" in feature]
        for feature in dep_features:
            dep_name, dep_feature = feature.split("/")

            # TODO(zbarsky): Is this correct?
            if dep_name.endswith("?"):
                print("Skipping", feature, "for", fq_crate, "it's optional")
                continue
            if dep_name not in possible_dep_version_by_name:
                print("Skipping", feature, "for", fq_crate, "it's not a dep...")
                continue
            dep_version = possible_dep_version_by_name[dep_name]
            feature_resolutions_by_fq_crate[_fq_crate(dep_name, dep_version)].features_enabled.add(dep_feature)

        feature_resolutions.features_enabled.update([
            f
            for f in implied_features
            if "/" not in f
        ])

    final_count = _count(feature_resolutions_by_fq_crate)
    return final_count > initial_count

def _git_url_to_cargo_toml(url):
    # Drop query params (?rev=...) and keep only before '#'
    parts = url.split("#")
    base = parts[0]
    sha = parts[1] if len(parts) > 1 else None

    if sha == None:
        fail("No commit SHA (#...) fragment found in URL: " + url)

    # Example base: https://github.com/dovahcrow/tldextract-rs?rev=63d75b0
    # Strip query parameters
    base = base.split("?")[0]

    repo_path = base.removeprefix("git+https://github.com/").removesuffix(".git")

    return "https://raw.githubusercontent.com/{}/{}/Cargo.toml".format(
        repo_path,
        sha,
    )

def _git_url_to_archive(url):
    # Drop query params (?rev=...) and keep only before '#'
    parts = url.split("#")
    base = parts[0]
    sha = parts[1] if len(parts) > 1 else None

    if sha == None:
        fail("No commit SHA (#...) fragment found in URL: " + url)

    # Example base: https://github.com/dovahcrow/tldextract-rs?rev=63d75b0
    # Strip query parameters
    base = base.split("?")[0]

    repo_path = base.removeprefix("git+https://github.com/").removesuffix(".git")

    url = "https://github.com/{}/archive/{}.tar.gz".format(repo_path, sha)

    repo = repo_path.split("/")[1]
    strip_prefix = repo + "-" + sha

    return url, strip_prefix

def _generate_hub_and_spokes(
        mctx,
        hub_name,
        cargo_lock):
    """Generates repositories for the transitive closure of the Cargo workspace.

    Args:
        mctx (module_ctx): The module context object.
        hub_name (string): name
        cargo_lock (object): Cargo.lock in json format
    """

    existing_facts = getattr(mctx, "facts") or {}
    facts = {}

    # Ignore workspace members
    packages = [p for p in cargo_lock["package"] if p.get("source")]

    download_tokens = []

    versions_by_name = dict()
    for package in packages:
        name = package["name"]
        version = package["version"]

        _add_to_dict(versions_by_name, name, [version])

        source = package["source"]

        # TODO(zbarsky): Persist these in lockfile facts?
        if source == "registry+https://github.com/rust-lang/crates.io-index":
            key = name + "_" + version
            fact = existing_facts.get(key)
            if fact:
                facts[key] = fact
                continue

            url = "https://crates.io/api/v1/crates/{}/{}".format(name, version)
            file = key + ".json"
            token = mctx.download(
                url,
                file,
                canonical_id = get_default_canonical_id(mctx, urls = [url]),
                block = False,
            )
            download_tokens.append(token)

            url += "/dependencies"
            file = key + "_dependencies.json"
            token = mctx.download(
                url,
                file,
                canonical_id = get_default_canonical_id(mctx, urls = [url]),
                block = False,
            )
            download_tokens.append(token)
        elif source.startswith("git+https://github.com/"):
            url = _git_url_to_cargo_toml(source)
            file = "{}_{}.Cargo.toml".format(name, version)
            token = mctx.download(
                url,
                file,
                canonical_id = get_default_canonical_id(mctx, urls = [url]),
                block = False,
            )
            download_tokens.append(token)
        else:
            fail("Unknown source " + source)

    # TODO(zbarsky): we should run downloads across all hubs in parallel instead of blocking here.
    mctx.report_progress("Downloading metadata")
    for token in download_tokens:
        result = token.wait()
        if not result.success:
            fail("Could not download")

    mctx.report_progress("Computing dependencies and features")

    feature_resolutions_by_fq_crate = dict()

    for package in packages:
        name = package["name"]
        version = package["version"]

        possible_dep_version_by_name = {}
        for dep in package.get("dependencies", []):
            if " " not in dep:
                # Only one version
                resolved_version = versions_by_name[dep][0]
            else:
                dep, resolved_version = dep.split(" ")
            possible_dep_version_by_name[dep] = resolved_version

        if package["source"] == "registry+https://github.com/rust-lang/crates.io-index":
            key = name + "_" + version
            fact = facts.get(key)
            if fact:
                fact = json.decode(fact)
            else:
                file = key + ".json"

                features = json.decode(mctx.read(file))["version"]["features"]
                dependencies = json.decode(mctx.read(key + "_dependencies.json"))["dependencies"]
                for dep in dependencies:
                    dep.pop("downloads")
                    dep.pop("id")
                    dep.pop("req")
                    dep.pop("version_id")
                    if dep["default_features"]:
                        dep.pop("default_features")
                    if not dep["features"]:
                        dep.pop("features")
                    if not dep["target"]:
                        dep.pop("target")
                    if dep["kind"] == "normal":
                        dep.pop("kind")
                    if not dep["optional"]:
                        dep.pop("optional")

                # Nest a serialized JSON since max path depth is 5.
                fact = dict(
                    features = features,
                    dependencies = dependencies,
                )
                facts[key] = json.encode(fact)

            possible_features = fact["features"]
            possible_deps = fact["dependencies"]
        else:
            file = "{}_{}.Cargo.toml".format(name, version)
            cargo_toml_json = _exec_convert_py(mctx, file)
            possible_features = cargo_toml_json.get("features", {})

            possible_deps = []
            for dep, spec in cargo_toml_json.get("dependencies", {}).items():
                if type(spec) == "string":
                    possible_deps.append({
                        "kind": "normal",
                        "crate_id": dep,
                    })
                else:
                    possible_deps.append({
                        "kind": "normal",
                        "crate_id": dep,
                        "optional": spec.get("optional", False),
                        "default_features": spec.get("default_features", True),
                        "features": spec.get("features", []),
                    })

            # TODO(zbarsky): build deps?
            if not possible_deps:
                print(name, version, package["source"])
                print(result.stdout)

        feature_resolutions_by_fq_crate[_fq_crate(name, version)] = (
            _new_feature_resolutions(possible_deps, possible_dep_version_by_name, possible_features)
        )

    # Do some round of mutual resolution; bail when no more changes
    for i in range(10):
        mctx.report_progress("Running round {} of dependency/feature resolution".format(i))

        had_change = _resolve_one_round(hub_name, feature_resolutions_by_fq_crate)
        if not had_change:
            break

    mctx.report_progress("Initializing spokes")

    for package in packages:
        name = package["name"]
        version = package["version"]
        checksum = package.get("checksum")

        feature_resolutions = feature_resolutions_by_fq_crate[_fq_crate(name, version)]

        conditional_deps = _select(
            windows = sorted(feature_resolutions.windows_deps),
            linux = sorted(feature_resolutions.linux_deps),
            osx = sorted(feature_resolutions.osx_deps),
        )

        if checksum:
            url = "https://crates.io/api/v1/crates/{}/{}/download".format(name, version)
            strip_prefix = "{}-{}".format(name, version)
        else:
            url, strip_prefix = _git_url_to_archive(package["source"])

        _crate_repository(
            name = _sanitize_crate("{}__{}_{}".format(hub_name, name, version)),
            crate = name,
            version = version,
            url = url,
            strip_prefix = strip_prefix,
            checksum = checksum,
            build_deps = sorted(feature_resolutions.build_deps),
            proc_macro_deps = sorted(feature_resolutions.proc_macro_deps),
            proc_macro_build_deps = sorted(feature_resolutions.proc_macro_build_deps),
            deps = sorted(feature_resolutions.deps),
            conditional_deps = " + " + conditional_deps if conditional_deps else "",
            crate_features = repr(sorted(feature_resolutions.features_enabled)),
        )

    mctx.report_progress("Initializing hub")

    hub_contents = []
    for name, versions in versions_by_name.items():
        for version in versions:
            qualified_name = _fq_crate(name, version)
            spoke_name = "@{}__{}//:{}".format(hub_name, qualified_name, name)
            hub_contents.append("""
alias(
    name = "{}",
    actual = "{}",
    visibility = ["//visibility:public"],
)""".format(
                qualified_name,
                spoke_name,
            ))

        if len(versions) == 1:
            hub_contents.append("""
alias(
    name = "{}",
    actual = ":{}",
    visibility = ["//visibility:public"],
)""".format(
                name,
                qualified_name,
            ))

    _hub_repo(
        name = hub_name,
        contents = {
            "BUILD.bazel": "\n".join(hub_contents),
        },
    )

    return facts

def _create_convert_py(ctx):
    ctx.file("convert.py", """
import sys
import tomllib
import json

with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)

print(json.dumps(data, indent=2))
""")

def _exec_convert_py(ctx, file):
    # TODO(zbarsky): This relies on host python 3.11+, we will need a better solution.
    result = ctx.execute(["python", "convert.py", file])
    if result.return_code != 0:
        fail(result.stdout + "\n" + result.stderr)

    return json.decode(result.stdout)

def _crate_impl(mctx):
    _create_convert_py(mctx)

    facts = {}
    direct_deps = []
    for mod in mctx.modules:
        if not mod.tags.from_cargo:
            fail("`.from_cargo` is required. Please update {}".format(mod.name))

        for cfg in mod.tags.from_cargo:
            direct_deps.append(cfg.name)
            mctx.watch(cfg.cargo_lock)
            cargo_lock = _exec_convert_py(mctx, cfg.cargo_lock)
            facts.update(_generate_hub_and_spokes(mctx, cfg.name, cargo_lock))

    kwargs = dict(
        root_module_direct_deps = direct_deps,
        root_module_direct_dev_deps = [],
        reproducible = True,
    )

    if True:
        kwargs["facts"] = facts

    return mctx.extension_metadata(**kwargs)

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
    _create_convert_py(rctx)

    crate = rctx.attr.crate
    version = rctx.attr.version
    checksum = rctx.attr.checksum
    deps = rctx.attr.deps

    # Compute the URL
    rctx.download_and_extract(
        rctx.attr.url,
        type = "tar.gz",
        canonical_id = get_default_canonical_id(rctx, urls = [rctx.attr.url]),
        strip_prefix = rctx.attr.strip_prefix,
        sha256 = checksum,
    )

    cargo_toml = _exec_convert_py(rctx, "Cargo.toml")

    build_script = cargo_toml.get("package", {}).get("build")
    if rctx.path("build.rs").exists:
        build_script = "build.rs"

    is_proc_macro = cargo_toml.get("lib", {}).get("proc-macro", False)
    lib_path = cargo_toml.get("lib", {}).get("path", "src/lib.rs")
    edition = cargo_toml.get("package", {}).get("edition", "2015")
    crate_name = cargo_toml.get("lib", {}).get("name")

    # Create a BUILD file with a deps attribute

    tags = [
        "crate-name=" + crate,
        "manual",
        "noclippy",
        "norustfmt",
    ]

    compile_data = """glob(
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
    )"""

    build_content = """
load("@rules_rust//cargo:defs.bzl", "cargo_build_script", "cargo_toml_env_vars")
load("@rules_rust//rust:defs.bzl", "{library_rule_type}")

package(default_visibility = ["//visibility:public"])

cargo_toml_env_vars(
    name = "cargo_toml_env_vars",
    src = "Cargo.toml",
)

{library_rule_type}(
    name = {crate},
    crate_name = {crate_name},
    srcs = glob(
        include = ["**/*.rs"],
        allow_empty = True,
    ),
    deps = [
        {deps}
    ]{conditional_deps},
    proc_macro_deps = [
        {proc_macro_deps}
    ],
    compile_data = {compile_data},
    crate_features = {crate_features},
    crate_root = {lib_path},
    edition = {edition},
    rustc_env_files = [
        ":cargo_toml_env_vars",
    ],
    rustc_flags = [
        "--cap-lints=allow",
    ],
    tags = [
        {tags}
    ],
    version = {version}
)
"""

    if build_script:
        deps = [":_bs"] + deps
        build_content += """

cargo_build_script(
    name = "_bs",
    compile_data = {compile_data},
    crate_features = {crate_features},
    crate_name = "build_script_build",
    crate_root = {build_script},
    data = {compile_data},
    deps = [
        {build_deps}
    ],
    proc_macro_deps = [
        {proc_macro_build_deps}
    ],
    edition = {edition},
    pkg_name = {crate},
    rustc_env_files = [
        ":cargo_toml_env_vars",
    ],
    rustc_flags = [
        "--cap-lints=allow",
    ],
    srcs = glob(
        allow_empty = True,
        include = ["**/*.rs"],
    ),
    tags = [
        {tags}
    ],
    version = {version},
    visibility = ["//visibility:private"],
)"""

    rctx.file("BUILD.bazel", build_content.format(
        library_rule_type = "rust_proc_macro" if is_proc_macro else "rust_library",
        crate = repr(crate),
        crate_name = repr(crate_name),
        version = repr(version),
        edition = repr(edition),
        crate_features = rctx.attr.crate_features,
        lib_path = repr(lib_path),
        proc_macro_deps = ",\n        ".join(['"%s"' % d for d in rctx.attr.proc_macro_deps]),
        proc_macro_build_deps = ",\n        ".join(['"%s"' % d for d in rctx.attr.proc_macro_build_deps]),
        build_deps = ",\n        ".join(['"%s"' % d for d in rctx.attr.build_deps]),
        deps = ",\n        ".join(['"%s"' % d for d in deps]),
        conditional_deps = rctx.attr.conditional_deps,
        tags = ",\n        ".join(['"%s"' % t for t in tags]),
        build_script = repr(build_script),
        compile_data = compile_data,
    ))

_crate_repository = repository_rule(
    implementation = _crate_repository_impl,
    attrs = {
        "crate": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "url": attr.string(mandatory = True),
        "strip_prefix": attr.string(mandatory = True),
        "checksum": attr.string(),
        "crate_features": attr.string(mandatory = True),
        "build_deps": attr.string_list(default = []),
        "proc_macro_build_deps": attr.string_list(default = []),
        "proc_macro_deps": attr.string_list(default = []),
        "deps": attr.string_list(default = []),
        "conditional_deps": attr.string(default = ""),
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
