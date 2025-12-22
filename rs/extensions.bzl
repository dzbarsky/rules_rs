load("@aspect_tools_telemetry_report//:defs.bzl", "TELEMETRY")  # buildifier: disable=load
load("@bazel_lib//lib:repo_utils.bzl", "repo_utils")
load("//rs/private:cargo_credentials.bzl", "load_cargo_credentials")
load("//rs/private:cfg_parser.bzl", "cfg_matches_expr_for_cfg_attrs", "triple_to_cfg_attrs")
load("//rs/private:crate_git_repository.bzl", "crate_git_repository")
load("//rs/private:crate_repository.bzl", "crate_repository")
load("//rs/private:default_annotation.bzl", "DEFAULT_CRATE_ANNOTATION")
load("//rs/private:downloader.bzl", "download_metadata_for_git_crates", "download_sparse_registry_configs", "new_downloader_state", "parse_git_url", "sharded_path", "start_crate_registry_downloads", "start_github_downloads")
load("//rs/private:git_repository.bzl", "git_repository")
load("//rs/private:resolver.bzl", "resolve")
load("//rs/private:semver.bzl", "select_matching_version")
load("//rs/private:toml2json.bzl", "run_toml2json")

def _spoke_repo(hub_name, name, version):
    s = "%s__%s-%s" % (hub_name, name, version)
    if "+" in s:
        s = s.replace("+", "-")
    return s

def _external_repo_for_git_source(remote, commit):
    return remote.replace("/", "_").replace(":", "_").replace("@", "_") + "_" + commit

def _platform(triple):
    return "@rules_rust//rust/platform:" + triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc")

def _select(items):
    return {k: sorted(v) for k, v in items.items()}

def _add_to_dict(d, k, v):
    existing = d.get(k, [])
    if not existing:
        d[k] = existing
    existing.append(v)

def _fq_crate(name, version):
    return name + "-" + version

def _new_feature_resolutions(package_index, possible_deps, possible_features, platform_triples):
    return struct(
        features_enabled = {triple: set() for triple in platform_triples},
        build_deps = {triple: set() for triple in platform_triples},
        deps = {triple: set() for triple in platform_triples},
        aliases = {},
        package_index = package_index,

        # Following data is immutable, it comes from crates.io + Cargo.lock
        possible_deps = possible_deps,
        possible_features = possible_features,
    )

def _date(ctx, label):
    return
    result = ctx.execute(["gdate", '+"%Y-%m-%d %H:%M:%S.%3N"'])
    print(label, result.stdout)

def _normalize_path(path):
    return path.replace("\\", "/")

def _spec_to_dep_dict_inner(dep, spec, is_build = False):
    if type(spec) == "string":
        dep = {"name": dep}
    else:
        dep = {
            "name": dep,
            "optional": spec.get("optional", False),
            "default_features": spec.get("default_features", spec.get("default-features", True)),
            "features": spec.get("features", []),
        }

    if is_build:
        dep["kind"] = "build"

    return dep

def _spec_to_dep_dict(dep, spec, annotation, workspace_cargo_toml_json, is_build = False):
    if type(spec) == "dict" and spec.get("workspace") == True:
        workspace = workspace_cargo_toml_json.get("workspace")
        if not workspace and annotation.workspace_cargo_toml != "Cargo.toml":
            fail("""

ERROR: `crate.annotation` for `{name}` has a `workspace_cargo_toml` pointing to a Cargo.toml without a `workspace` section. Please correct it in your MODULE.bazel!
Make sure you point to the `Cargo.toml` of the workspace, not of `{name}`!”

""".format(name = annotation.crate))

        inherited = _spec_to_dep_dict_inner(
            dep,
            workspace["dependencies"][dep],
            is_build,
        )

        extra_features = spec.get("features")
        if extra_features:
            inherited["features"] = sorted(set(extra_features + inherited.get("features", [])))

        if spec.get("optional"):
            inherited["optional"] = True

        return inherited
    return _spec_to_dep_dict_inner(dep, spec, is_build)

def _generate_hub_and_spokes(
        mctx,
        hub_name,
        annotations,
        cargo_path,
        cargo_lock_path,
        all_packages,
        sparse_registry_configs,
        platform_triples,
        cargo_credentials,
        cargo_config,
        debug,
        dry_run = False):
    """Generates repositories for the transitive closure of the Cargo workspace.

    Args:
        mctx (module_ctx): The module context object.
        hub_name (string): name
        annotations (dict): Annotation tags to apply.
        cargo_path (path): Path to hermetic `cargo` binary.
        cargo_lock_path (path): Cargo.lock path
        all_packages: list[package]: from cargo lock parsing
        sparse_registry_configs: dict[source, sparse registry config]
        platform_triples (list[string]): Triples to resolve for
        cargo_credentials (dict): Mapping of registry to auth token.
        cargo_config (label): .cargo/config.toml file
        debug (bool): Enable debug logging
        dry_run (bool): Run all computations but do not create repos. Useful for benchmarking.
    """
    _date(mctx, "start")

    mctx.report_progress("Reading workspace metadata")
    result = mctx.execute(
        [cargo_path, "metadata", "--no-deps", "--format-version=1", "--quiet"],
        working_directory = str(mctx.path(cargo_lock_path).dirname),
    )
    if result.return_code != 0:
        fail(result.stdout + "\n" + result.stderr)
    cargo_metadata = json.decode(result.stdout)

    _date(mctx, "parsed cargo metadata")

    existing_facts = getattr(mctx, "facts", {}) or {}
    facts = {}

    # Ignore workspace members
    workspace_members = [p for p in all_packages if "source" not in p]
    packages = [p for p in all_packages if p.get("source")]

    platform_cfg_attrs = [triple_to_cfg_attrs(triple, [], []) for triple in platform_triples]

    mctx.report_progress("Computing dependencies and features")

    feature_resolutions_by_fq_crate = dict()

    # TODO(zbarsky): Would be nice to resolve for _ALL_PLATFORMS instead of per-triple, but it's complicated.
    cfg_match_cache = {None: platform_triples}

    versions_by_name = dict()
    for package_index in range(len(packages)):
        package = packages[package_index]
        name = package["name"]
        version = package["version"]
        source = package["source"]

        _add_to_dict(versions_by_name, name, version)

        if source.startswith("sparse+"):
            key = name + "_" + version
            fact = existing_facts.get(key)
            if fact:
                facts[key] = fact
                fact = json.decode(fact)
            else:
                package["download_token"].wait()

                # TODO(zbarsky): Should we also dedupe this parsing?
                metadatas = mctx.read(name + ".jsonl").strip().split("\n")
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
        else:
            key = source + "_" + name
            fact = existing_facts.get(key)
            if fact:
                facts[key] = fact
                fact = json.decode(fact)
            else:
                annotation = annotations.get(name, DEFAULT_CRATE_ANNOTATION)
                info = package.get("member_crate_cargo_toml_info")
                if info:
                    # TODO(zbarsky): These tokens got enqueues last, so this can bottleneck
                    # We can try a bit harder to interleave things if we care.
                    info.token.wait()
                    workspace_cargo_toml_json = package["workspace_cargo_toml_json"]
                    cargo_toml_json = run_toml2json(mctx, info.path)
                else:
                    cargo_toml_json = package["cargo_toml_json"]
                    workspace_cargo_toml_json = package.get("workspace_cargo_toml_json")
                strip_prefix = package.get("strip_prefix", "")

                dependencies = [
                    _spec_to_dep_dict(dep, spec, annotation, workspace_cargo_toml_json)
                    for dep, spec in cargo_toml_json.get("dependencies", {}).items()
                ] + [
                    _spec_to_dep_dict(dep, spec, annotation, workspace_cargo_toml_json, is_build = True)
                    for dep, spec in cargo_toml_json.get("build-dependencies", {}).items()
                ]

                for target, value in cargo_toml_json.get("target", {}).items():
                    for dep, spec in value.get("dependencies", {}).items():
                        converted = _spec_to_dep_dict(dep, spec, annotation, workspace_cargo_toml_json)
                        converted["target"] = target
                        dependencies.append(converted)

                if not dependencies and debug:
                    print(name, version, package["source"])

                fact = dict(
                    features = cargo_toml_json.get("features", {}),
                    dependencies = dependencies,
                    strip_prefix = strip_prefix,
                )

                # Nest a serialized JSON since max path depth is 5.
                facts[key] = json.encode(fact)

            package["strip_prefix"] = fact["strip_prefix"]

        possible_features = fact["features"]
        possible_deps = [
            dep
            for dep in fact["dependencies"]
            if dep.get("kind") != "dev" and
               dep.get("package") not in [
                   # Internal rustc placeholder crates.
                   "rustc-std-workspace-alloc",
                   "rustc-std-workspace-core",
                   "rustc-std-workspace-std",
               ]
        ]

        for dep in possible_deps:
            if dep.get("default_features", True):
                _add_to_dict(dep, "features", "default")

        feature_resolutions = _new_feature_resolutions(package_index, possible_deps, possible_features, platform_triples)
        package["feature_resolutions"] = feature_resolutions
        feature_resolutions_by_fq_crate[_fq_crate(name, version)] = feature_resolutions

    for package in packages:
        deps_by_name = {}
        for maybe_fq_dep in package.get("dependencies", []):
            idx = maybe_fq_dep.find(" ")
            if idx != -1:
                dep = maybe_fq_dep[:idx]
                resolved_version = maybe_fq_dep[idx + 1:]
                _add_to_dict(deps_by_name, dep, resolved_version)

        for dep in package["feature_resolutions"].possible_deps:
            dep_package = dep.get("package")
            if not dep_package:
                dep_package = dep["name"]

            versions = versions_by_name.get(dep_package)
            if not versions:
                continue
            if len(versions) == 1:
                resolved_version = versions[0]
            else:
                versions = deps_by_name.get(dep_package)
                if not versions:
                    continue
                if len(versions) == 1:
                    # TODO(zbarsky): validate?
                    resolved_version = versions[0]
                else:
                    resolved_version = select_matching_version(dep["req"], versions)
                    if not resolved_version:
                        print(name, dep_package, versions, dep["req"])
                        continue

            dep_fq = _fq_crate(dep_package, resolved_version)
            dep["bazel_target"] = "@%s//:%s" % (hub_name, dep_fq)
            dep["feature_resolutions"] = feature_resolutions_by_fq_crate[dep_fq]

            target = dep.get("target")
            match = cfg_match_cache.get(target)
            if not match:
                match = cfg_matches_expr_for_cfg_attrs(target, platform_cfg_attrs)

                # TODO(zbarsky): Figure out how to do this optimization safely.
                #if len(match) == len(platform_cfg_attrs):
                #    match = match_all
                cfg_match_cache[target] = match
            dep["target"] = set(match)

    _date(mctx, "set up resolutions")

    workspace_fq_deps = _compute_workspace_fq_deps(workspace_members, versions_by_name)

    workspace_dep_versions_by_name = {}

    # Only files in the current Bazel workspace can/should be watched, so check where our manifests are located.
    watch_manifests = cargo_lock_path.repo_name == ""

    # Set initial set of features from Cargo.tomls
    for package in cargo_metadata["packages"]:
        if watch_manifests:
            mctx.watch(package["manifest_path"])

        fq_deps = workspace_fq_deps[package["name"]]

        for dep in package["dependencies"]:
            if not dep["source"]:
                continue

            name = dep["name"]

            features = dep["features"]
            if dep["uses_default_features"]:
                features.append("default")

            dep_fq = fq_deps[name]
            dep["bazel_target"] = "@%s//:%s" % (hub_name, dep_fq)
            feature_resolutions = feature_resolutions_by_fq_crate[dep_fq]

            versions = workspace_dep_versions_by_name.get(name)
            if not versions:
                versions = set()
                workspace_dep_versions_by_name[name] = versions
            versions.add(dep_fq)

            target = dep.get("target")
            match = cfg_match_cache.get(target)
            if not match:
                match = cfg_matches_expr_for_cfg_attrs(target, platform_cfg_attrs)

                # TODO(zbarsky): Figure out how to do this optimization safely.
                #if len(match) == len(platform_cfg_attrs):
                #    match = match_all
                cfg_match_cache[target] = match

            for triple in match:
                feature_resolutions.features_enabled[triple].update(features)

    # Set initial set of features from annotations
    for crate, annotation in annotations.items():
        if annotation.crate_features:
            for version in versions_by_name.get(crate, []):
                features_enabled = feature_resolutions_by_fq_crate[_fq_crate(crate, version)].features_enabled
                for triple in platform_triples:
                    features_enabled[triple].update(annotation.crate_features)

    _date(mctx, "set up initial deps!")

    resolve(mctx, packages, feature_resolutions_by_fq_crate, debug)

    # Validate that we aren't trying to enable any `dep:foo` features that were not even in the lockfile.
    for package in packages:
        feature_resolutions = package["feature_resolutions"]
        features_enabled = feature_resolutions.features_enabled

        for dep in feature_resolutions.possible_deps:
            if "bazel_target" in dep:
                continue

            prefixed_dep_alias = "dep:" + dep["name"]

            for triple in platform_triples:
                if prefixed_dep_alias in features_enabled[triple]:
                    fail("Crate %s has enabled %s but it was not in the lockfile..." % (package["name"], prefixed_dep_alias))

    mctx.report_progress("Initializing spokes")

    use_home_cargo_credentials = bool(cargo_credentials)

    for package in packages:
        crate_name = package["name"]
        version = package["version"]
        source = package["source"]

        feature_resolutions = feature_resolutions_by_fq_crate[_fq_crate(crate_name, version)]

        annotation = annotations.get(crate_name, DEFAULT_CRATE_ANNOTATION)

        kwargs = dict(
            hub_name = hub_name,
            additive_build_file = annotation.additive_build_file,
            additive_build_file_content = annotation.additive_build_file_content,
            gen_build_script = annotation.gen_build_script,
            build_script_deps = [],
            build_script_deps_select = _select(feature_resolutions.build_deps),
            build_script_data = annotation.build_script_data,
            build_script_data_select = annotation.build_script_data_select,
            build_script_env = annotation.build_script_env,
            build_script_toolchains = annotation.build_script_toolchains,
            build_script_env_select = annotation.build_script_env_select,
            rustc_flags = annotation.rustc_flags,
            data = annotation.data,
            deps = annotation.deps,
            deps_select = _select(feature_resolutions.deps),
            aliases = feature_resolutions.aliases,
            gen_binaries = annotation.gen_binaries,
            crate_features = annotation.crate_features,
            crate_features_select = _select(feature_resolutions.features_enabled),
            patch_args = annotation.patch_args,
            patch_tool = annotation.patch_tool,
            patches = annotation.patches,
        )

        repo_name = _spoke_repo(hub_name, crate_name, version)

        if source.startswith("sparse+"):
            checksum = package["checksum"]
            url = sparse_registry_configs[source].format(**{
                "crate": crate_name,
                "version": version,
                "prefix": sharded_path(crate_name),
                "lowerprefix": sharded_path(crate_name.lower()),
                "sha256-checksum": checksum,
            })

            if dry_run:
                continue

            crate_repository(
                name = repo_name,
                url = url,
                strip_prefix = "%s-%s" % (crate_name, version),
                checksum = checksum,
                # The repository will need to recompute these, but this lets us avoid serializing them.
                use_home_cargo_credentials = use_home_cargo_credentials,
                cargo_config = cargo_config,
                source = source,
                **kwargs
            )
        else:
            remote, commit = parse_git_url(source)

            strip_prefix = package.get("strip_prefix")
            workspace_cargo_toml = annotation.workspace_cargo_toml
            if workspace_cargo_toml != "Cargo.toml":
                strip_prefix = workspace_cargo_toml.removesuffix("Cargo.toml") + (strip_prefix or "")

            if dry_run:
                continue

            crate_git_repository(
                name = repo_name,
                strip_prefix = strip_prefix,
                git_repo_label = "@" + _external_repo_for_git_source(remote, commit),
                workspace_cargo_toml = annotation.workspace_cargo_toml,
                **kwargs
            )

    _date(mctx, "created repos")

    mctx.report_progress("Initializing hub")

    hub_contents = []
    for name, versions in versions_by_name.items():
        binaries = annotations.get(name, DEFAULT_CRATE_ANNOTATION).gen_binaries

        for version in versions:
            spoke_repo = _spoke_repo(hub_name, name, version)

            hub_contents.append("""
alias(
    name = "{name}-{version}",
    actual = "@{spoke_repo}//:{name}",
)""".format(name = name, version = version, spoke_repo = spoke_repo))

            for binary in binaries:
                hub_contents.append("""
alias(
    name = "{name}-{version}__{binary}",
    actual = "@{spoke_repo}//:{binary}__bin",
)""".format(name = name, version = version, binary = binary, spoke_repo = spoke_repo))

        workspace_versions = workspace_dep_versions_by_name.get(name)
        if workspace_versions:
            fq = sorted(workspace_versions)[-1]

            hub_contents.append("""
alias(
    name = "{name}",
    actual = ":{fq}",
)""".format(name = name, fq = fq))

            for binary in binaries:
                hub_contents.append("""
alias(
    name = "{name}__{binary}",
    actual = ":{fq}__{binary}",
)""".format(name = name, fq = fq, binary = binary))

    hub_contents.append(
        """
package(
    default_visibility = ["//visibility:public"],
)

filegroup(
    name = "_workspace_deps",
    srcs = [
       %s 
    ],
)""" % ",\n        ".join(['":%s"' % dep for dep in sorted(workspace_dep_versions_by_name.keys())]),
    )

    defs_bzl_contents = \
        """load(":data.bzl", "DEP_DATA")
load("@rules_rs//rs/private:all_crate_deps.bzl", _all_crate_deps = "all_crate_deps")

def aliases(package_name = None):
    dep_data = DEP_DATA.get(package_name or native.package_name())
    if not dep_data:
        return {{}}

    return dep_data["aliases"]

def all_crate_deps(
        normal = False,
        #normal_dev = False,
        proc_macro = False,
        #proc_macro_dev = False,
        build = False,
        build_proc_macro = False,
        package_name = None,
        cargo_only = False):

    dep_data = DEP_DATA.get(package_name or native.package_name())
    if not dep_data:
        return []

    return _all_crate_deps(
        dep_data,
        normal = normal,
        proc_macro = proc_macro,
        build = build,
        build_proc_macro = build_proc_macro,
        filter_prefix = {this_repo} if cargo_only else None,
    )

RESOLVED_PLATFORMS = select({{
    {target_compatible_with},
    "//conditions:default": ["@platforms//:incompatible"],
}})
""".format(
            target_compatible_with = ",\n    ".join(['"%s": []' % _platform(triple) for triple in platform_triples]),
            this_repo = repr("@" + hub_name + "//:"),
        )

    _date(mctx, "done")

    repo_root = _normalize_path(cargo_metadata["workspace_root"])

    workspace_dep_stanzas = []
    for package in cargo_metadata["packages"]:
        aliases = {}
        deps = []
        build_deps = []

        for dep in package["dependencies"]:
            bazel_target = dep.get("bazel_target")
            if not bazel_target:
                bazel_target = "//" + _normalize_path(dep["path"]).removeprefix(repo_root)

                # TODO(zbarsky): check if we actually need this?
                aliases[bazel_target] = dep["name"]

            if dep["kind"] == "build":
                build_deps.append(bazel_target)
            else:
                deps.append(bazel_target)

        workspace_dep_stanzas.append("""
    {bazel_package}: {{
        "aliases": {{
            {aliases}
        }},
        "deps": [
            {deps}
        ],
        "build_deps": [
            {build_deps}
        ],
    }},""".format(
            bazel_package = repr(_normalize_path(package["manifest_path"]).removeprefix(repo_root).removesuffix("/Cargo.toml")),
            aliases = ",\n            ".join(['"%s": "%s"' % kv for kv in sorted(aliases.items())]),
            deps = ",\n            ".join(['"%s"' % d for d in sorted(deps)]),
            build_deps = ",\n            ".join(['"%s"' % d for d in sorted(build_deps)]),
        ))

    data_bzl_contents = "DEP_DATA = {" + "\n".join(workspace_dep_stanzas) + "\n}"

    if dry_run:
        return

    _hub_repo(
        name = hub_name,
        contents = {
            "BUILD.bazel": "\n".join(hub_contents),
            "defs.bzl": defs_bzl_contents,
            "data.bzl": data_bzl_contents,
        },
    )

    return facts

def _compute_package_fq_deps(package, versions_by_name, strict = True):
    possible_dep_fq_crate_by_name = {}

    for maybe_fq_dep in package.get("dependencies", []):
        idx = maybe_fq_dep.find(" ")
        if idx == -1:
            # Only one version
            versions = versions_by_name.get(maybe_fq_dep)
            if not versions:
                if strict:
                    fail("Malformed lockfile?")
                continue
            dep = maybe_fq_dep
            resolved_version = versions[0]
        else:
            dep = maybe_fq_dep[:idx]
            resolved_version = maybe_fq_dep[idx + 1:]

        possible_dep_fq_crate_by_name[dep] = _fq_crate(dep, resolved_version)

    return possible_dep_fq_crate_by_name

def _compute_workspace_fq_deps(workspace_members, versions_by_name):
    workspace_fq_deps = {}

    for workspace_member in workspace_members:
        fq_deps = _compute_package_fq_deps(workspace_member, versions_by_name, strict = False)
        workspace_fq_deps[workspace_member["name"]] = fq_deps

    return workspace_fq_deps

def _crate_impl(mctx):
    # TODO(zbarsky): Kick off `cargo` fetch early to mitigate https://github.com/bazelbuild/bazel/issues/26995
    cargo_path = mctx.path(Label("@rs_rust_host_tools//:bin/cargo"))

    # And toml2json
    toml2json = mctx.path(Label("@toml2json_%s//file:downloaded" % repo_utils.platform(mctx)))

    downloader_state = new_downloader_state()

    packages_by_hub_name = {}

    for mod in mctx.modules:
        if not mod.tags.from_cargo:
            fail("`.from_cargo` is required. Please update %s" % mod.name)

        for cfg in mod.tags.from_cargo:
            annotations = {
                annotation.crate: annotation
                for annotation in mod.tags.annotation
                if cfg.name in (annotation.repositories or [cfg.name])
            }

            mctx.watch(cfg.cargo_lock)
            cargo_lock = run_toml2json(mctx, cfg.cargo_lock)
            parsed_packages = cargo_lock["package"]
            packages_by_hub_name[cfg.name] = parsed_packages

            # Process git downloads first because they may require a followup download if the repo is a workspace,
            # so we want to enqueue them early so they don't get delayed by 1-shot registry downloads.
            start_github_downloads(mctx, downloader_state, annotations, parsed_packages)

    for mod in mctx.modules:
        for cfg in mod.tags.from_cargo:
            annotations = {
                annotation.crate: annotation
                for annotation in mod.tags.annotation
                if cfg.name in (annotation.repositories or [cfg.name])
            }

            if cfg.use_home_cargo_credentials:
                if not cfg.cargo_config:
                    fail("Must provide cargo_config when using cargo credentials")

                cargo_credentials = load_cargo_credentials(mctx, cfg.cargo_config)
            else:
                cargo_credentials = {}

            start_crate_registry_downloads(mctx, downloader_state, annotations, packages_by_hub_name[cfg.name], cargo_credentials, cfg.debug)

    for fetch_state in downloader_state.in_flight_git_crate_fetches_by_url.values():
        fetch_state.download_token.wait()

    download_metadata_for_git_crates(mctx, downloader_state, annotations)

    # TODO(zbarsky): Unfortunate that we block on the download for crates.io even though it's well-known.
    # Should we hardcode it?
    sparse_registry_configs = download_sparse_registry_configs(mctx, downloader_state)

    facts = {}
    direct_deps = []
    direct_dev_deps = []

    for mod in mctx.modules:
        for cfg in mod.tags.from_cargo:
            if mctx.is_dev_dependency(cfg):
                direct_dev_deps.append(cfg.name)
            else:
                direct_deps.append(cfg.name)

            hub_packages = packages_by_hub_name[cfg.name]

            annotations = {
                annotation.crate: annotation
                for annotation in mod.tags.annotation
                if cfg.name in (annotation.repositories or [cfg.name])
            }

            if cfg.debug:
                for _ in range(25):
                    _generate_hub_and_spokes(mctx, cfg.name, annotations, cargo_path, cfg.cargo_lock, hub_packages, sparse_registry_configs, cfg.platform_triples, cargo_credentials, cfg.cargo_config, cfg.debug, dry_run = True)

            facts |= _generate_hub_and_spokes(mctx, cfg.name, annotations, cargo_path, cfg.cargo_lock, hub_packages, sparse_registry_configs, cfg.platform_triples, cargo_credentials, cfg.cargo_config, cfg.debug)

    # Lay down the git repos we will need; per-crate git_repository can clone from these.
    git_sources = set()
    for mod in mctx.modules:
        for cfg in mod.tags.from_cargo:
            for package in packages_by_hub_name[cfg.name]:
                source = package.get("source", "")
                if source.startswith("git+"):
                    git_sources.add(source)

    for git_source in git_sources:
        remote, commit = parse_git_url(git_source)

        git_repository(
            name = _external_repo_for_git_source(remote, commit),
            commit = commit,
            remote = remote,
        )

    kwargs = dict(
        root_module_direct_deps = direct_deps,
        root_module_direct_dev_deps = direct_dev_deps,
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
        "cargo_toml": attr.label(
            doc = "The workspace-level Cargo.toml. There can be multiple crates in the workspace.",
        ),
        "cargo_lock": attr.label(),
        "cargo_config": attr.label(),
        "use_home_cargo_credentials": attr.bool(
            doc = "If set, the ruleset will load `~/cargo/credentials.toml` and attach those credentials to registry requests.",
        ),
        "platform_triples": attr.string_list(
            mandatory = True,
            doc = "The set of triples to resolve for. They must correspond to the union of any exec/target platforms that will participate in your build.",
        ),
        "debug": attr.bool(),
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
        "additive_build_file": attr.label(
            doc = "A file containing extra contents to write to the bottom of generated BUILD files.",
        ),
        "additive_build_file_content": attr.string(
            doc = "Extra contents to write to the bottom of generated BUILD files.",
        ),
        # "alias_rule": attr.string(
        #     doc = "Alias rule to use instead of `native.alias()`.  Overrides [render_config](#render_config)'s 'default_alias_rule'.",
        # ),
        "build_script_data": _relative_label_list(
            doc = "A list of labels to add to a crate's `cargo_build_script::data` attribute.",
        ),
        # "build_script_data_glob": attr.string_list(
        #     doc = "A list of glob patterns to add to a crate's `cargo_build_script::data` attribute",
        # ),
        "build_script_data_select": attr.string_list_dict(
            doc = "A list of labels to add to a crate's `cargo_build_script::data` attribute. Keys should be the platform triplet. Value should be a list of labels.",
        ),
        # "build_script_deps": _relative_label_list(
        #     doc = "A list of labels to add to a crate's `cargo_build_script::deps` attribute.",
        # ),
        "build_script_env": attr.string_dict(
            doc = "Additional environment variables to set on a crate's `cargo_build_script::env` attribute.",
        ),
        "build_script_env_select": attr.string_dict(
            doc = "Additional environment variables to set on a crate's `cargo_build_script::env` attribute. Key should be the platform triplet. Value should be a JSON encoded dictionary mapping variable names to values, for example `{\"FOO\": \"bar\"}`.",
        ),
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
        "gen_binaries": attr.string_list(
            doc = "As a list, the subset of the crate's bins that should get `rust_binary` targets produced.",
        ),
        "gen_build_script": attr.string(
            doc = "An authoritative flag to determine whether or not to produce `cargo_build_script` targets for the current crate. Supported values are 'on', 'off', and 'auto'.",
            values = ["auto", "on", "off"],
            default = "auto",
        ),
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
        "patch_args": attr.string_list(
            doc = "The `patch_args` attribute of a Bazel repository rule. See [http_archive.patch_args](https://docs.bazel.build/versions/main/repo/http.html#http_archive-patch_args)",
        ),
        "patch_tool": attr.string(
            doc = "The `patch_tool` attribute of a Bazel repository rule. See [http_archive.patch_tool](https://docs.bazel.build/versions/main/repo/http.html#http_archive-patch_tool)",
        ),
        "patches": attr.label_list(
            doc = "The `patches` attribute of a Bazel repository rule. See [http_archive.patches](https://docs.bazel.build/versions/main/repo/http.html#http_archive-patches)",
        ),
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
        "strip_prefix": attr.string(),
        "workspace_cargo_toml": attr.string(
            doc = "For crates from git, the ruleset assumes the (workspace) Cargo.toml is in the repo root. This attribute overrides the assumption.",
            default = "Cargo.toml",
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

def _hub_repo_impl(rctx):
    for path, contents in rctx.attr.contents.items():
        rctx.file(path, contents)
    rctx.file("REPO.bazel", "")

_hub_repo = repository_rule(
    implementation = _hub_repo_impl,
    attrs = {
        "contents": attr.string_dict(
            doc = "A mapping of file names to text they should contain.",
            mandatory = True,
        ),
    },
)
