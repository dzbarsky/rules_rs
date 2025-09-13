load("@bazel_tools//tools/build_defs/repo:cache.bzl", "get_default_canonical_id")
load("@bazel_tools//tools/build_defs/repo:git.bzl", "new_git_repository")
load("//rs/private:cfg_parser.bzl", "cfg_matches_ast_for_triples", "cfg_parse")
load(
    "//rs/private:crate_repository.bzl",
    "crate_repository",
    "generate_build_file",
    "run_toml2json",
)
load("//rs/private:semver.bzl", "select_matching_version")

# TODO(zbarsky): Don't see any way in the API response to determine if a crate is a proc_macro :(
# We only find out once we download the Cargo.toml, which is inside the spoke repo, which is too late.
# For now just hardcode it; try to get crates.io fixed to tell us
_PROC_MACROS = set([
    "arg_enum_proc_macro",
    "arrow_convert_derive",
    "asn1-rs-derive",
    "asn1-rs-impl",
    "async-attributes",
    "curve25519-dalek-derive",
    "async-generic",
    "async-recursion",
    "async-stream-impl",
    "async-trait",
    "auto_enums",
    "axum-macros",
    "biscuit-quote",
    "bytecheck_derive",
    "cached_proc_macro",
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
    "failure_derive",
    "fix-hidden-lifetime-bug-proc_macros",
    "foreign-types-macros",
    "futures-macro",
    "indoc",
    "macro_rules_attribute-proc_macro",
    "maybe-async",
    "mockall_derive",
    "monostate-impl",
    "nalgebra-macros",
    "neli-proc-macros",
    "noop_proc_macro",
    "num-derive",
    "openssl-macros",
    "paste",
    "pest_derive",
    "phf_macros",
    "pin-project-internal",
    "proc-macro-error-attr",
    "proc-macro-error-attr2",
    "proc-macro-hack",
    "profiling-procmacros",
    "prost-derive",
    "prost-reflect-derive",
    "ptr_meta_derive",
    "pyo3-async-runtimes-macros",
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
    "validator_derive",
    "valuable-derive",
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
    "time-macros": ["0.1.1"],
}

def _spoke_repo(hub_name, name, version):
    return "{}__{}-{}".format(hub_name, name, version).replace("+", "-")

def _platform(triple):
    return "@rules_rust//rust/platform:" + triple.replace("-musl", "-gnu")

def _select(platform_items, default = []):
    branches = []

    for triple, items in platform_items.items():
        if items:
            branches.append((_platform(triple), sorted(items) if type(items) == "set" else items))

    if not branches:
        return ""

    branches.append(("//conditions:default", default))

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
    return name + "-" + version

def _new_feature_resolutions(possible_deps, possible_dep_fq_crate_by_name, possible_features, platform_triples):
    return struct(
        features_enabled = set(),
        platform_features_enabled = {triple: set() for triple in platform_triples},

        # If set, we will set `target_compatible_with`. If have "*" that means all.
        triples_compatible_with = set(),

        # TODO(zbarsky): Do these also need the platform-specific variants?
        build_deps = set(),
        proc_macro_deps = set(),
        proc_macro_build_deps = set(),
        deps = set(),
        platform_deps = {triple: set() for triple in platform_triples},
        aliases = dict(),
        platform_aliases = {triple: dict() for triple in platform_triples},

        # Following data is immutable, it comes from crates.io + Cargo.lock
        possible_deps = possible_deps,
        possible_dep_fq_crate_by_name = possible_dep_fq_crate_by_name,
        possible_features = possible_features,
    )

def _count(feature_resolutions_by_fq_crate):
    n = 0
    for feature_resolutions in feature_resolutions_by_fq_crate.values():
        n += len(feature_resolutions.features_enabled)
        for triple_features in feature_resolutions.platform_features_enabled.values():
            n += len(triple_features)

        n += len(feature_resolutions.build_deps)
        n += len(feature_resolutions.proc_macro_deps)
        n += len(feature_resolutions.proc_macro_build_deps)
        n += len(feature_resolutions.deps)
        for triple_deps in feature_resolutions.platform_deps.values():
            n += len(triple_deps)

        n += len(feature_resolutions.aliases)
        for triple_aliases in feature_resolutions.platform_aliases.values():
            n += len(triple_aliases)

    print("Got count", n)
    return n

def _resolve_one_round(hub_name, feature_resolutions_by_fq_crate, platform_triples):
    for fq_crate, feature_resolutions in feature_resolutions_by_fq_crate.items():
        features_enabled = feature_resolutions.features_enabled
        platform_features_enabled = feature_resolutions.platform_features_enabled

        deps = feature_resolutions.deps
        platform_deps = feature_resolutions.platform_deps

        aliases = feature_resolutions.aliases
        platform_aliases = feature_resolutions.platform_aliases

        build_deps = feature_resolutions.build_deps
        proc_macro_build_deps = feature_resolutions.proc_macro_build_deps
        proc_macro_deps = feature_resolutions.proc_macro_deps

        possible_dep_fq_crate_by_name = feature_resolutions.possible_dep_fq_crate_by_name
        possible_features = feature_resolutions.possible_features

        # Propagate features across currently enabled dependencies.
        for dep in feature_resolutions.possible_deps:
            if "package" in dep:
                dep_name = dep["package"]
                dep_alias = dep["name"]
            else:
                dep_name = dep["name"]
                dep_alias = dep_name

            dep_fq = possible_dep_fq_crate_by_name.get(dep_name)
            if not dep_fq:
                # print("NOT FOUND", dep)
                continue

            bazel_target = "@{}//:{}".format(hub_name, dep_fq)

            proc_macro = dep_name in _PROC_MACROS and dep_fq.removeprefix(dep_name)[1:] not in _PROC_MACROS_EXCEPTIONS.get(dep_name, [])
            dep_feature_resolutions = feature_resolutions_by_fq_crate[dep_fq]

            kind = dep.get("kind", "normal")
            if kind == "dev":
                # Drop dev deps
                continue

            if dep.get("optional") and dep_alias not in features_enabled:
                for triple, feature_set in platform_features_enabled.items():
                    if dep_alias not in feature_set:
                        continue

                    # TODO(zbarsky): platform-specific build deps?
                    if kind == "build":
                        if proc_macro:
                            proc_macro_build_deps.add(bazel_target)
                        else:
                            build_deps.add(bazel_target)
                    else:
                        if proc_macro:
                            # TODO(zbarsky): should be platform-specific, but this proc_macro stuff should get simplified anyway
                            proc_macro_deps.add(bazel_target)
                        else:
                            platform_deps[triple].add(bazel_target)
                            dep_feature_resolutions.triples_compatible_with.add(triple)

                    if dep_name != dep_alias:
                        platform_aliases[triple][bazel_target] = dep_alias.replace("-", "_")

                    dep_feature_resolutions.platform_features_enabled[triple].update(dep.get("features", []))
                    if dep.get("default_features", True):
                        dep_feature_resolutions.platform_features_enabled[triple].add("default")

                continue

            if kind == "build":
                if proc_macro:
                    proc_macro_build_deps.add(bazel_target)
                else:
                    build_deps.add(bazel_target)

            target = dep.get("target")
            if not target:
                if proc_macro:
                    proc_macro_deps.add(bazel_target)
                else:
                    deps.add(bazel_target)

                if dep_name != dep_alias:
                    aliases[bazel_target] = dep_alias.replace("-", "_")

                dep_feature_resolutions.triples_compatible_with.add("*")
                dep_feature_resolutions.features_enabled.update(dep.get("features", []))
                if dep.get("default_features", True):
                    dep_feature_resolutions.features_enabled.add("default")
            else:
                # TODO(zbarsky): Lots of opportunity to save computations here.
                match = cfg_matches_ast_for_triples(target, platform_triples)
                for triple in platform_triples:
                    if match[triple]:
                        dep_feature_resolutions.triples_compatible_with.add(triple)
                        platform_deps[triple].add(bazel_target)
                        if dep_name != dep_alias:
                            platform_aliases[triple][bazel_target] = dep_alias.replace("-", "_")
                        dep_feature_resolutions.platform_features_enabled[triple].update(dep.get("features", []))
                        if dep.get("default_features", True):
                            dep_feature_resolutions.platform_features_enabled[triple].add("default")

        # Enable any features that are implied by previously-enabled features.
        implied_features = [
            implied_feature.removeprefix("dep:")
            for enabled_feature in features_enabled
            for implied_feature in possible_features.get(enabled_feature, [])
        ]

        features_enabled.update([
            f
            for f in implied_features
            if "/" not in f
        ])

        dep_features = [feature for feature in implied_features if "/" in feature]
        for feature in dep_features:
            dep_name, dep_feature = feature.split("/")

            if dep_name.endswith("?"):
                dep_name = dep_name[:-1]
            else:
                # TODO(zbarsky): Technically this is not an enabled feature, but it's a way to get the dep enabled in the next loop iteration.
                features_enabled.add(dep_name)

            dep_fq = possible_dep_fq_crate_by_name.get(dep_name)
            if not dep_fq:
                # Maybe it's an alias?
                for dep in feature_resolutions.possible_deps:
                    if dep.get("name") == dep_name and "package" in dep:
                        dep_name = dep["package"]
                        break
                dep_fq = possible_dep_fq_crate_by_name.get(dep_name)

            if not dep_fq:
                print("Skipping enabling subfeature", feature, "for", fq_crate, "it's not a dep...")
                continue

            feature_resolutions_by_fq_crate[dep_fq].features_enabled.add(dep_feature)

        for triple, feature_set in platform_features_enabled.items():
            implied_features = [
                implied_feature.removeprefix("dep:")
                for enabled_feature in feature_set
                for implied_feature in possible_features.get(enabled_feature, [])
            ]

            feature_set.update([
                f
                for f in implied_features
                if "/" not in f
            ])

            dep_features = [feature for feature in implied_features if "/" in feature]
            for feature in dep_features:
                dep_name, dep_feature = feature.split("/")

                if dep_name.endswith("?"):
                    dep_name = dep_name[:-1]
                else:
                    # TODO(zbarsky): Technically this is not an enabled feature, but it's a way to get the dep enabled in the next loop iteration.
                    feature_set.add(dep_name)

                dep_fq = possible_dep_fq_crate_by_name.get(dep_name)
                if not dep_fq:
                    # Maybe it's an alias?
                    for dep in feature_resolutions.possible_deps:
                        if dep.get("name") == dep_name and "package" in dep:
                            dep_name = dep["package"]
                            break
                    dep_fq = possible_dep_fq_crate_by_name.get(dep_name)

                if not dep_fq:
                    print("Skipping enabling subfeature", feature, "for", fq_crate, "it's not a dep...")
                    continue

                feature_resolutions_by_fq_crate[dep_fq].platform_features_enabled[triple].add(dep_feature)

def _parse_git_url(url):
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

    return repo_path, sha

def _git_url_to_cargo_toml(url):
    repo_path, sha = _parse_git_url(url)
    return "https://raw.githubusercontent.com/{}/{}/Cargo.toml".format(repo_path, sha)

def _sharded_path(crate):
    crate = crate.lower()

    # crates.io-index sharding rules (ASCII names)
    n = len(crate)
    if n == 0:
        fail("empty crate name")
    if n == 1:
        return "1/" + crate
    if n == 2:
        return "2/" + crate
    if n == 3:
        return "3/%s/%s" % (crate[0], crate)
    return "%s/%s/%s" % (crate[0:2], crate[2:4], crate)

def _generate_hub_and_spokes(
        mctx,
        hub_name,
        toml2json,
        annotations,
        cargo_lock_path,
        platform_triples):
    """Generates repositories for the transitive closure of the Cargo workspace.

    Args:
        mctx (module_ctx): The module context object.
        annotations (dict): Annotation tags to apply.
        hub_name (string): name
        toml2json (wasm module):
        cargo_lock_path (path): Cargo.lock path
        platform_triples (list[string]): Triples to resolve for
    """
    mctx.watch(cargo_lock_path)
    cargo_lock = run_toml2json(mctx, toml2json, cargo_lock_path)

    existing_facts = getattr(mctx, "facts", {}) or {}
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

            # TODO(zbarsky): dedupe fetches when multiple versions?
            url = "https://raw.githubusercontent.com/rust-lang/crates.io-index/master/" + _sharded_path(name)
            token = mctx.download(
                url,
                key + ".jsonl",
                canonical_id = get_default_canonical_id(mctx, urls = [url]),
                block = False,
            )
            download_tokens.append(token)
        elif source.startswith("git+https://github.com/"):
            url = _git_url_to_cargo_toml(source)
            token = mctx.download(
                url,
                "{}_{}.Cargo.toml".format(name, version),
                canonical_id = get_default_canonical_id(mctx, urls = [url]),
                block = False,
            )
            download_tokens.append(token)
        else:
            fail("Unknown source " + source)

    # TODO(zbarsky): Not sure why we need this weird hack to get `/bin/` into the path...
    cargo = mctx.path(Label("@rs_rust_host_tools//:cargo"))
    cargo = cargo.dirname.get_child("bin/cargo")
    result = mctx.execute(
        [cargo, "metadata", "--no-deps", "--format-version=1", "--quiet"],
        working_directory = str(mctx.path(cargo_lock_path).dirname),
    )
    if result.return_code != 0:
        fail(result.stdout + "\n" + result.stderr)
    cargo_metadata = json.decode(result.stdout)

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
        source = package["source"]

        possible_dep_fq_crate_by_name = {}
        for dep in package.get("dependencies", []):
            if " " not in dep:
                # Only one version
                resolved_version = versions_by_name[dep][0]
            else:
                dep, resolved_version = dep.split(" ")
            possible_dep_fq_crate_by_name[dep] = _fq_crate(dep, resolved_version)

        if source == "registry+https://github.com/rust-lang/crates.io-index":
            key = name + "_" + version
            fact = facts.get(key)
            if fact:
                fact = json.decode(fact)
            else:
                metadatas = mctx.read(key + ".jsonl").strip().split("\n")
                for metadata in metadatas:
                    metadata = json.decode(metadata)
                    if metadata["vers"] != version:
                        continue

                    features = metadata["features"]

                    # Crates published with newer Cargo populate this field for `resolver = "2"`.
                    # It can express more nuanced feature dependencies and overrides the keys from legacy features, if present.
                    features.update(metadata.get("features2", {}))

                    dependencies = metadata["deps"]

                    for dep in dependencies:
                        dep.pop("req")
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

                    fact = dict(
                        features = features,
                        dependencies = dependencies,
                    )

                    # Nest a serialized JSON since max path depth is 5.
                    facts[key] = json.encode(fact)

            possible_features = fact["features"]
            possible_deps = fact["dependencies"]
        else:
            cargo_toml_json = run_toml2json(mctx, toml2json, "{}_{}.Cargo.toml".format(name, version))

            if cargo_toml_json.get("package", {}).get("name") != name:
                strip_prefix = None
                if name in cargo_toml_json["workspace"]["members"]:
                    strip_prefix = name
                else:
                    # TODO(zbarsky): more cases to handle here?
                    for dep in cargo_toml_json["workspace"]["dependencies"].values():
                        if type(dep) == "dict" and dep.get("package") == name:
                            strip_prefix = dep["path"]
                            break

                if strip_prefix:
                    package["edition"] = cargo_toml_json["workspace"].get("edition")
                    package["strip_prefix"] = strip_prefix
                    download_path = strip_prefix + ".Cargo.toml"
                    url = _git_url_to_cargo_toml(source).replace("Cargo.toml", strip_prefix + "/Cargo.toml")
                    result = mctx.download(
                        url,
                        download_path,
                        canonical_id = get_default_canonical_id(mctx, urls = [url]),
                    )
                    if not result.success:
                        fail("Could not download")
                    cargo_toml_json = run_toml2json(mctx, toml2json, download_path)

            package["cargo_toml_json"] = cargo_toml_json

            possible_features = cargo_toml_json.get("features", {})

            possible_deps = []
            for dep, spec in cargo_toml_json.get("dependencies", {}).items():
                if type(spec) == "string":
                    possible_deps.append({
                        "name": dep,
                    })
                else:
                    possible_deps.append({
                        "name": dep,
                        "optional": spec.get("optional", False),
                        "default_features": spec.get("default_features", True),
                        "features": spec.get("features", []),
                    })

            for dep, spec in cargo_toml_json.get("build-dependencies", {}).items():
                if type(spec) == "string":
                    possible_deps.append({
                        "name": dep,
                        "kind": "build",
                    })
                else:
                    possible_deps.append({
                        "name": dep,
                        "kind": "build",
                        "optional": spec.get("optional", False),
                        "default_features": spec.get("default_features", True),
                        "features": spec.get("features", []),
                    })

            if not possible_deps:
                print(name, version, package["source"])

        for dep in possible_deps:
            target = dep.get("target")
            if target:
                dep["target"] = cfg_parse(target)

        feature_resolutions_by_fq_crate[_fq_crate(name, version)] = (
            _new_feature_resolutions(possible_deps, possible_dep_fq_crate_by_name, possible_features, platform_triples)
        )

    # Set initial set of features from Cargo.tomls
    for package in cargo_metadata["packages"]:
        for dep in package["dependencies"]:
            if dep["source"] != "registry+https://github.com/rust-lang/crates.io-index":
                continue
            name = dep["name"]
            versions = versions_by_name[name]
            version = select_matching_version(dep["req"], versions)
            if not version:
                fail("Could not solve version for %s %s among %s" % (name, dep["req"], versions))

            features = dep["features"]
            if dep["uses_default_features"]:
                features.append("default")

            feature_resolutions = feature_resolutions_by_fq_crate[_fq_crate(name, version)]
            feature_resolutions.features_enabled.update(features)

            # Assume we could build top-level dep on any platform.
            feature_resolutions.triples_compatible_with.add("*")

    # Do some round of mutual resolution; bail when no more changes
    # Resolution process always enables new crates/features so we can just count total enabled
    # instead of being careful about change tracking.
    initial_count = 0
    for i in range(10):
        mctx.report_progress("Running round {} of dependency/feature resolution".format(i))

        _resolve_one_round(hub_name, feature_resolutions_by_fq_crate, platform_triples)
        count = _count(feature_resolutions_by_fq_crate)
        if count == initial_count:
            break

        initial_count = count

    mctx.report_progress("Initializing spokes")

    for package in packages:
        name = package["name"]
        version = package["version"]
        checksum = package.get("checksum")

        feature_resolutions = feature_resolutions_by_fq_crate[_fq_crate(name, version)]

        triples_compatible_with = feature_resolutions.triples_compatible_with

        if "*" in triples_compatible_with or not triples_compatible_with:
            triples_compatible_with = set(platform_triples)

        # Remove conditional deps that are present on all platforms already.
        for platform_dep_set in feature_resolutions.platform_deps.values():
            platform_dep_set.difference_update(feature_resolutions.deps)

        conditional_deps = _select(feature_resolutions.platform_deps)
        conditional_aliases = _select(feature_resolutions.platform_aliases, default = {})
        conditional_crate_features = _select(feature_resolutions.platform_features_enabled)

        annotation = annotations.get(name)
        if annotation:
            build_script_data = annotation.build_script_data
            build_script_env = annotation.build_script_env
            build_script_toolchains = annotation.build_script_toolchains
            data = annotation.data
            deps = annotation.deps
            crate_features = annotation.crate_features
            rustc_flags = annotation.rustc_flags
        else:
            build_script_data = []
            build_script_env = {}
            build_script_toolchains = []
            data = []
            deps = []
            crate_features = []
            rustc_flags = []

        # TODO(zbarsky): Better way to detect this?
        deps = feature_resolutions.deps | set(deps)
        link_deps = [dep for dep in deps if "openssl-sys" in dep]

        kwargs = dict(
            crate = name,
            version = version,
            checksum = checksum,
            link_deps = sorted(link_deps),
            build_deps = sorted(feature_resolutions.build_deps),
            build_script_data = build_script_data,
            build_script_env = build_script_env,
            build_script_toolchains = build_script_toolchains,
            rustc_flags = rustc_flags,
            proc_macro_deps = sorted(feature_resolutions.proc_macro_deps),
            proc_macro_build_deps = sorted(feature_resolutions.proc_macro_build_deps),
            data = data,
            deps = sorted(deps),
            conditional_deps = " + " + conditional_deps if conditional_deps else "",
            aliases = feature_resolutions.aliases,
            conditional_aliases = " | " + conditional_aliases if conditional_aliases else "",
            crate_features = repr(sorted(feature_resolutions.features_enabled | set(crate_features))),
            conditional_crate_features = " + " + conditional_crate_features if conditional_crate_features else "",
            target_compatible_with = [_platform(triple) for triple in sorted(triples_compatible_with)],
            fallback_edition = package.get("edition"),
        )

        repo_name = _spoke_repo(hub_name, name, version)

        if checksum:
            crate_repository(
                name = repo_name,
                url = "https://crates.io/api/v1/crates/{}/{}/download".format(name, version),
                strip_prefix = "{}-{}".format(name, version),
                **kwargs
            )
        else:
            build_file_content = generate_build_file(struct(**kwargs), package["cargo_toml_json"])

            repo_path, sha = _parse_git_url(package["source"])

            new_git_repository(
                name = repo_name,
                init_submodules = True,
                build_file_content = build_file_content,
                strip_prefix = package.get("strip_prefix"),
                commit = sha,
                remote = "https://github.com/%s.git" % repo_path,
            )

    mctx.report_progress("Initializing hub")

    hub_contents = []
    for name, versions in versions_by_name.items():
        for version in versions:
            hub_contents.append("""
alias(
    name = "{name}-{version}",
    actual = "@{spoke_repo}//:{name}",
    visibility = ["//visibility:public"],
)""".format(
                name = name,
                version = version,
                spoke_repo = _spoke_repo(hub_name, name, version),
            ))

        hub_contents.append("""
alias(
    name = "{name}",
    actual = ":{name}-{version}",
    visibility = ["//visibility:public"],
)""".format(
            name = name,
            # TODO(zbarsky): Select max version?
            version = versions[-1],
        ))

    _hub_repo(
        name = hub_name,
        contents = {
            "BUILD.bazel": "\n".join(hub_contents),
        },
    )

    return facts

def _crate_impl(mctx):
    toml2json = None

    facts = {}
    direct_deps = []
    for mod in mctx.modules:
        if not mod.tags.from_cargo:
            fail("`.from_cargo` is required. Please update {}".format(mod.name))

        for cfg in mod.tags.from_cargo:
            direct_deps.append(cfg.name)

            annotations = {
                annotation.crate: annotation
                for annotation in mod.tags.annotation
                if cfg.name in (annotation.repositories or [cfg.name])
            }

            if not toml2json:
                toml2json = mctx.load_wasm(cfg._wasm2json)

            facts |= _generate_hub_and_spokes(mctx, cfg.name, toml2json, annotations, cfg.cargo_lock, cfg.platform_triples)

    kwargs = dict(
        root_module_direct_deps = direct_deps,
        root_module_direct_dev_deps = [],
        reproducible = True,
    )

    if hasattr(mctx, "facts"):
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
        "platform_triples": attr.string_list(
            mandatory = True,
        ),
    } | {
        "_wasm2json": attr.label(default = "@rules_rs//toml2json:toml2json.wasm"),
    },
)

_relative_label_list = attr.string_list

_annotation = tag_class(
    doc = "A collection of extra attributes and settings for a particular crate.",
    attrs = {
        "crate": attr.string(
            doc = "The name of the crate the annotation is applied to",
            mandatory = True,
        ),
        "repositories": attr.string_list(
            doc = "A list of repository names specified from `crate.from_cargo(name=...)` that this annotation is applied to. Defaults to all repositories.",
            default = [],
        ),
        # "version": attr.string(
        #     doc = "The versions of the crate the annotation is applied to. Defaults to all versions.",
        #     default = "*",
        # ),
    } | {
        # "additive_build_file": attr.label(
        #     doc = "A file containing extra contents to write to the bottom of generated BUILD files.",
        # ),
        # "additive_build_file_content": attr.string(
        #     doc = "Extra contents to write to the bottom of generated BUILD files.",
        # ),
        # "alias_rule": attr.string(
        #     doc = "Alias rule to use instead of `native.alias()`.  Overrides [render_config](#render_config)'s 'default_alias_rule'.",
        # ),
        "build_script_data": _relative_label_list(
            doc = "A list of labels to add to a crate's `cargo_build_script::data` attribute.",
        ),
        # "build_script_data_glob": attr.string_list(
        #     doc = "A list of glob patterns to add to a crate's `cargo_build_script::data` attribute",
        # ),
        # "build_script_data_select": attr.string_list_dict(
        #     doc = "A list of labels to add to a crate's `cargo_build_script::data` attribute. Keys should be the platform triplet. Value should be a list of labels.",
        # ),
        # "build_script_deps": _relative_label_list(
        #     doc = "A list of labels to add to a crate's `cargo_build_script::deps` attribute.",
        # ),
        "build_script_env": attr.string_dict(
            doc = "Additional environment variables to set on a crate's `cargo_build_script::env` attribute.",
        ),
        # "build_script_env_select": attr.string_dict(
        #     doc = "Additional environment variables to set on a crate's `cargo_build_script::env` attribute. Key should be the platform triplet. Value should be a JSON encoded dictionary mapping variable names to values, for example `{\"FOO\": \"bar\"}`.",
        # ),
        # "build_script_link_deps": _relative_label_list(
        #     doc = "A list of labels to add to a crate's `cargo_build_script::link_deps` attribute.",
        # ),
        # "build_script_proc_macro_deps": _relative_label_list(
        #     doc = "A list of labels to add to a crate's `cargo_build_script::proc_macro_deps` attribute.",
        # ),
        # "build_script_rundir": attr.string(
        #     doc = "An override for the build script's rundir attribute.",
        # ),
        # "build_script_rustc_env": attr.string_dict(
        #     doc = "Additional environment variables to set on a crate's `cargo_build_script::env` attribute.",
        # ),
        "build_script_toolchains": attr.label_list(
            doc = "A list of labels to set on a crates's `cargo_build_script::toolchains` attribute.",
        ),
        # "build_script_tools": _relative_label_list(
        # doc = "A list of labels to add to a crate's `cargo_build_script::tools` attribute.",
        # ),
        # "compile_data": _relative_label_list(
        # doc = "A list of labels to add to a crate's `rust_library::compile_data` attribute.",
        # ),
        # "compile_data_glob": attr.string_list(
        # doc = "A list of glob patterns to add to a crate's `rust_library::compile_data` attribute.",
        # ),
        # "compile_data_glob_excludes": attr.string_list(
        # doc = "A list of glob patterns to be excllued from a crate's `rust_library::compile_data` attribute.",
        # ),
        "crate_features": attr.string_list(
            doc = "A list of strings to add to a crate's `rust_library::crate_features` attribute.",
        ),
        "data": _relative_label_list(
            doc = "A list of labels to add to a crate's `rust_library::data` attribute.",
        ),
        # "data_glob": attr.string_list(
        #     doc = "A list of glob patterns to add to a crate's `rust_library::data` attribute.",
        # ),
        "deps": _relative_label_list(
            doc = "A list of labels to add to a crate's `rust_library::deps` attribute.",
        ),
        # "disable_pipelining": attr.bool(
        #     doc = "If True, disables pipelining for library targets for this crate.",
        # ),
        # "extra_aliased_targets": attr.string_dict(
        #     doc = "A list of targets to add to the generated aliases in the root crate_universe repository.",
        # ),
        # "gen_all_binaries": attr.bool(
        #     doc = "If true, generates `rust_binary` targets for all of the crates bins",
        # ),
        # "gen_binaries": attr.string_list(
        #     doc = "As a list, the subset of the crate's bins that should get `rust_binary` targets produced.",
        # ),
        # "gen_build_script": attr.string(
        #     doc = "An authoritative flag to determine whether or not to produce `cargo_build_script` targets for the current crate. Supported values are 'on', 'off', and 'auto'.",
        #     values = _OPT_BOOL_VALUES.keys(),
        #     default = "auto",
        # ),
        # "override_target_bin": attr.label(
        #     doc = "An optional alternate target to use when something depends on this crate to allow the parent repo to provide its own version of this dependency.",
        # ),
        # "override_target_build_script": attr.label(
        #     doc = "An optional alternate target to use when something depends on this crate to allow the parent repo to provide its own version of this dependency.",
        # ),
        # "override_target_lib": attr.label(
        #     doc = "An optional alternate target to use when something depends on this crate to allow the parent repo to provide its own version of this dependency.",
        # ),
        # "override_target_proc_macro": attr.label(
        #     doc = "An optional alternate target to use when something depends on this crate to allow the parent repo to provide its own version of this dependency.",
        # ),
        # "patch_args": attr.string_list(
        #     doc = "The `patch_args` attribute of a Bazel repository rule. See [http_archive.patch_args](https://docs.bazel.build/versions/main/repo/http.html#http_archive-patch_args)",
        # ),
        # "patch_tool": attr.string(
        #     doc = "The `patch_tool` attribute of a Bazel repository rule. See [http_archive.patch_tool](https://docs.bazel.build/versions/main/repo/http.html#http_archive-patch_tool)",
        # ),
        # "patches": attr.label_list(
        #     doc = "The `patches` attribute of a Bazel repository rule. See [http_archive.patches](https://docs.bazel.build/versions/main/repo/http.html#http_archive-patches)",
        # ),
        # "proc_macro_deps": _relative_label_list(
        #     doc = "A list of labels to add to a crate's `rust_library::proc_macro_deps` attribute.",
        # ),
        # "rustc_env": attr.string_dict(
        #     doc = "Additional variables to set on a crate's `rust_library::rustc_env` attribute.",
        # ),
        # "rustc_env_files": _relative_label_list(
        #     doc = "A list of labels to set on a crate's `rust_library::rustc_env_files` attribute.",
        # ),
        "rustc_flags": attr.string_list(
            doc = "A list of strings to set on a crate's `rust_library::rustc_flags` attribute.",
        ),
        # "shallow_since": attr.string(
        #     doc = "An optional timestamp used for crates originating from a git repository instead of a crate registry. This flag optimizes fetching the source code.",
        # ),
    },
)

crate = module_extension(
    implementation = _crate_impl,
    tag_classes = {
        "annotation": _annotation,
        "from_cargo": _from_cargo,
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
