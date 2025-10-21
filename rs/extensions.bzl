load("@bazel_tools//tools/build_defs/repo:git_worker.bzl", "git_repo")
load("//rs/private:cargo_credentials.bzl", "load_cargo_credentials", "registry_auth_headers")
load("//rs/private:cfg_parser.bzl", "cfg_matches_expr_for_cfg_attrs", "triple_to_cfg_attrs")
load("//rs/private:crate_git_repository.bzl", "crate_git_repository")
load("//rs/private:crate_repository.bzl", "crate_repository")
load("//rs/private:resolver.bzl", "resolve")
load("//rs/private:semver.bzl", "select_matching_version")
load("//rs/private:toml2json.bzl", "run_toml2json")

_DEFAULT_CRATE_ANNOTATION = struct(
    additive_build_file = None,
    additive_build_file_content = "",
    gen_build_script = "auto",
    build_script_data = [],
    build_script_data_select = {},
    build_script_env = {},
    build_script_env_select = {},
    build_script_toolchains = [],
    data = [],
    deps = [],
    crate_features = [],
    rustc_flags = [],
    patch_args = [],
    patch_tool = None,
    patches = [],
    workspace_cargo_toml = "Cargo.toml",
)

def _spoke_repo(hub_name, name, version):
    s = "%s__%s-%s" % (hub_name, name, version)
    if "+" in s:
        s = s.replace("+", "-")
    return s

def _platform(triple):
    return "@rules_rust//rust/platform:" + triple.replace("-musl", "-gnu")

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

    remote = base.removeprefix("git+")

    return remote, sha

def _parse_github_url(url):
    remote, sha = _parse_git_url(url)
    repo_path = remote.removeprefix("https://github.com/").removesuffix(".git")
    return repo_path, sha

def _github_source_to_raw_content_base_url(url):
    return "https://raw.githubusercontent.com/%s/%s/" % _parse_github_url(url)

def _sharded_path(crate):
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

def _date(ctx, label):
    return
    result = ctx.execute(["gdate", '+"%Y-%m-%d %H:%M:%S.%3N"'])
    print(label, result.stdout)

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

def _spec_to_dep_dict(dep, spec, workspace_cargo_toml_json, is_build = False):
    if spec == {"workspace": True}:
        dep_key = "build-dependencies" if is_build else "dependencies"
        return _spec_to_dep_dict_inner(
            dep,
            workspace_cargo_toml_json["workspace"][dep_key][dep],
            is_build,
        )
    return _spec_to_dep_dict_inner(dep, spec, is_build)

def _generate_hub_and_spokes(
        mctx,
        wasm_blob,
        hub_name,
        annotations,
        cargo_lock_path,
        platform_triples,
        cargo_credentials,
        cargo_config,
        debug,
        dry_run = False):
    """Generates repositories for the transitive closure of the Cargo workspace.

    Args:
        mctx (module_ctx): The module context object.
        wasm_blob (string): The loaded wasm module, if any. If unset, the native binary is used.
        hub_name (string): name
        annotations (dict): Annotation tags to apply.
        cargo_lock_path (path): Cargo.lock path
        platform_triples (list[string]): Triples to resolve for
        cargo_credentials (dict): Mapping of registry to auth token.
        cargo_config (label): .cargo/config.toml file
        debug (bool): Enable debug logging
        dry_run (bool): Run all computations but do not create repos. Useful for benchmarking.
    """
    _date(mctx, "start")

    # TODO(zbarsky): We should run `cargo metadata` while the deps are downloading, but for now just kick it off early to avoid
    # https://github.com/bazelbuild/bazel/issues/26995
    mctx.report_progress("Reading workspace metadata")
    cargo = mctx.path(Label("@rs_rust_host_tools//:bin/cargo"))
    result = mctx.execute(
        [cargo, "metadata", "--no-deps", "--format-version=1", "--quiet"],
        working_directory = str(mctx.path(cargo_lock_path).dirname),
    )
    if result.return_code != 0:
        fail(result.stdout + "\n" + result.stderr)
    cargo_metadata = json.decode(result.stdout)

    _date(mctx, "parsed cargo metadata")

    mctx.watch(cargo_lock_path)
    cargo_lock = run_toml2json(mctx, wasm_blob, cargo_lock_path)
    _date(mctx, "parsed cargo.lock")

    existing_facts = getattr(mctx, "facts", {}) or {}
    facts = {}

    # Ignore workspace members
    workspace_members = [p for p in cargo_lock["package"] if "source" not in p]
    packages = [p for p in cargo_lock["package"] if p.get("source")]

    sparse_registry_configs = {}
    for package in packages:
        source = package["source"]
        if source == "registry+https://github.com/rust-lang/crates.io-index":
            source = "sparse+https://index.crates.io/"
            package["source"] = source
        elif not source.startswith("sparse+"):
            continue

        if source in sparse_registry_configs:
            continue

        registry = source.removeprefix("sparse+")

        sparse_registry_configs[source] = mctx.download(
            registry + "config.json",
            source.replace("/", "_") + "config.json",
            headers = registry_auth_headers(cargo_credentials, source),
            block = False,
        )

    versions_by_name = dict()
    for package in packages:
        name = package["name"]
        version = package["version"]

        _add_to_dict(versions_by_name, name, version)

        source = package["source"]

        if source.startswith("sparse+"):
            key = name + "_" + version
            fact = existing_facts.get(key)
            if fact:
                facts[key] = fact
                continue

            # TODO(zbarsky): dedupe fetches when multiple versions?
            url = source.removeprefix("sparse+") + _sharded_path(name.lower())
            package["download_token"] = mctx.download(
                url,
                key + ".jsonl",
                headers = registry_auth_headers(cargo_credentials, source),
                block = False,
            )
        elif source.startswith("git+"):
            key = source + "_" + name
            fact = existing_facts.get(key)
            if fact:
                facts[key] = fact
                continue

            if source.startswith("git+https://github.com/"):
                annotation = annotations.get(name, _DEFAULT_CRATE_ANNOTATION)
                url = _github_source_to_raw_content_base_url(source) + annotation.workspace_cargo_toml
                package["download_token"] = mctx.download(
                    url,
                    "%s_%s.Cargo.toml" % (name, version),
                    allow_fail = True,
                    block = False,
                )
            else:
                # TODO(zbarsky): Ideally other forges could use the single-file fastpath...
                remote, commit = _parse_git_url(source)
                directory = mctx.path(source.replace("/", "_"))
                clone_config = struct(
                    delete = lambda _: 0,
                    execute = mctx.execute,
                    os = mctx.os,
                    name = hub_name,
                    path = mctx.path,
                    report_progress = mctx.report_progress,
                    attr = struct(
                        shallow_since = "",
                        commit = commit,
                        remote = remote,
                        init_submodules = True,
                        recursive_init_submodules = True,
                        verbose = debug,
                    ),
                )
                git_repo(clone_config, directory)
        else:
            fail("Unknown source " + source)

    _date(mctx, "kicked off downloads")

    # TODO(zbarsky): we should kick off downloads across all hubs in parallel instead of blocking other hubs on resolving this one.

    platform_cfg_attrs = [triple_to_cfg_attrs(triple, [], []) for triple in platform_triples]

    mctx.report_progress("Computing dependencies and features")

    feature_resolutions_by_fq_crate = dict()

    # TODO(zbarsky): Would be nice to resolve for _ALL_PLATFORMS instead of per-triple, but it's complicated.
    cfg_match_cache = {None: platform_triples}

    for package_index in range(len(packages)):
        package = packages[package_index]
        name = package["name"]
        version = package["version"]
        source = package["source"]

        if source.startswith("sparse+"):
            key = name + "_" + version
            fact = facts.get(key)
            if fact:
                fact = json.decode(fact)
            else:
                package["download_token"].wait()
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
            fact = facts.get(key)
            if fact:
                fact = json.decode(fact)
            else:
                if source.startswith("git+https://github.com/"):
                    package["download_token"].wait()

                    # This download may have failed! We check below.
                    cargo_toml_json_path = "%s_%s.Cargo.toml" % (name, version)
                else:
                    # Non-github forges do a shallow clone into a child directory.
                    annotation = annotations.get(name, _DEFAULT_CRATE_ANNOTATION)
                    cargo_toml_json_path = source.replace("/", "_") + "/" + annotation.workspace_cargo_toml

                if not mctx.path(cargo_toml_json_path).exists:
                    fail("""

ERROR: Could not download Cargo.toml for {name}@{version} from git repository, perhaps the repo root is not the Cargo workspace root?
Please indicate the path to the workspace Cargo.toml (or the crate itself, if not part of a workspace) in MODULE.bazel, like so:

crate.annotation(
     crate = "{name}",
     workspace_cargo_toml = "path/to/Cargo.toml",
)

""".format(name = name, version = version))

                cargo_toml_json = run_toml2json(mctx, wasm_blob, cargo_toml_json_path)
                workspace_cargo_toml_json = cargo_toml_json

                if False and annotations.get(name, _DEFAULT_CRATE_ANNOTATION).workspace_cargo_toml != "Cargo.toml" and "workspace" not in cargo_toml_json:
                    fail("""

ERROR: `crate.annotation` for {name} has a `workspace_cargo_toml` pointing to a Cargo.toml without a `workspace` section. Please correct it in your MODULE.bazel!

""".format(name = name))

                strip_prefix = None
                if cargo_toml_json.get("package", {}).get("name") != name:
                    workspace = cargo_toml_json["workspace"]
                    if name in workspace["members"]:
                        strip_prefix = name
                    else:
                        # TODO(zbarsky): more cases to handle here?
                        for dep in workspace["dependencies"].values():
                            if type(dep) == "dict" and dep.get("package") == name:
                                strip_prefix = dep["path"]
                                break

                    if strip_prefix:
                        package["strip_prefix"] = strip_prefix
                        if source.startswith("git+https://github.com/"):
                            annotation = annotations.get(name, _DEFAULT_CRATE_ANNOTATION)
                            url = _github_source_to_raw_content_base_url(source) + annotation.workspace_cargo_toml
                            url = url.replace("Cargo.toml", strip_prefix + "/Cargo.toml")

                            child_cargo_toml_json_path = strip_prefix + ".Cargo.toml"
                            mctx.download(url, child_cargo_toml_json_path)
                        else:
                            child_cargo_toml_json_path = cargo_toml_json_path.replace("Cargo.toml", strip_prefix + "/Cargo.toml")

                        cargo_toml_json = run_toml2json(mctx, wasm_blob, child_cargo_toml_json_path)

                dependencies = [
                    _spec_to_dep_dict(dep, spec, workspace_cargo_toml_json)
                    for dep, spec in cargo_toml_json.get("dependencies", {}).items()
                ] + [
                    _spec_to_dep_dict(dep, spec, workspace_cargo_toml_json, is_build = True)
                    for dep, spec in cargo_toml_json.get("build-dependencies", {}).items()
                ]

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

    workspace_deps = set()

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
            workspace_deps.add(name)

            features = dep["features"]
            if dep["uses_default_features"]:
                features.append("default")

            dep_fq = fq_deps[name]
            dep["bazel_target"] = "@%s//:%s" % (hub_name, dep_fq)
            feature_resolutions = feature_resolutions_by_fq_crate[dep_fq]

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

    for source, token in sparse_registry_configs.items():
        token.wait()
        dl = json.decode(mctx.read(source.replace("/", "_") + "config.json"))["dl"]

        if not (
            "{crate}" in dl or
            "{version}" in dl or
            "{sha256-checksum}" in dl or
            "{prefix}" in dl or
            "{lowerprefix}" in dl
        ):
            dl += "/{crate}/{version}/download"

        sparse_registry_configs[source] = dl

    mctx.report_progress("Initializing spokes")

    use_home_cargo_credentials = bool(cargo_credentials)

    for package in packages:
        crate_name = package["name"]
        version = package["version"]
        source = package["source"]

        feature_resolutions = feature_resolutions_by_fq_crate[_fq_crate(crate_name, version)]

        annotation = annotations.get(crate_name, _DEFAULT_CRATE_ANNOTATION)

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
            crate_features = annotation.crate_features,
            crate_features_select = _select(feature_resolutions.features_enabled),
            use_wasm = wasm_blob != None,
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
                "prefix": _sharded_path(crate_name),
                "lowerprefix": _sharded_path(crate_name.lower()),
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
            remote, commit = _parse_git_url(source)

            strip_prefix = package.get("strip_prefix")
            workspace_cargo_toml = annotation.workspace_cargo_toml
            if workspace_cargo_toml != "Cargo.toml":
                strip_prefix = workspace_cargo_toml.removesuffix("Cargo.toml") + (strip_prefix or "")

            if dry_run:
                continue

            crate_git_repository(
                name = repo_name,
                init_submodules = True,
                strip_prefix = strip_prefix,
                commit = commit,
                remote = remote,
                verbose = debug,
                workspace_cargo_toml = annotation.workspace_cargo_toml,
                **kwargs
            )

    _date(mctx, "created repos")

    mctx.report_progress("Initializing hub")

    hub_contents = []
    for name, versions in versions_by_name.items():
        for version in versions:
            hub_contents.append("""
alias(
    name = "{name}-{version}",
    actual = "@{spoke_repo}//:{name}",
)""".format(
                name = name,
                version = version,
                spoke_repo = _spoke_repo(hub_name, name, version),
            ))

        hub_contents.append("""
alias(
    name = "{name}",
    actual = ":{name}-{version}",
)""".format(
            name = name,
            # TODO(zbarsky): Select max version?
            version = versions[-1],
        ))

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
)""" % ",\n        ".join(['":%s"' % dep for dep in sorted(workspace_deps)]),
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
        package_name = None):

    dep_data = DEP_DATA.get(package_name or native.package_name())
    if not dep_data:
        return []

    return _all_crate_deps(
        dep_data,
        normal = normal,
        proc_macro = proc_macro,
        build = build,
        build_proc_macro = build_proc_macro,
    )

RESOLVED_PLATFORMS = select({{
    {target_compatible_with},
    "//conditions:default": ["@platforms//:incompatible"],
}})
""".format(
            target_compatible_with = ",\n        ".join(['"%s": []' % _platform(triple) for triple in platform_triples]),
        )

    _date(mctx, "done")

    # TODO(zbarsky): Is this correct for non-main repos? Will anyone care?
    repo_root = str(mctx.path(Label("@@//:all"))).removesuffix("all")

    workspace_dep_stanzas = []
    for package in cargo_metadata["packages"]:
        aliases = {}
        deps = []
        build_deps = []

        for dep in package["dependencies"]:
            bazel_target = dep.get("bazel_target")
            if not bazel_target:
                bazel_target = "//" + dep["path"].removeprefix(repo_root)
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
            bazel_package = repr(package["manifest_path"].removeprefix(repo_root).removesuffix("/Cargo.toml")),
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
    toml2json = None

    facts = {}
    direct_deps = []
    for mod in mctx.modules:
        if not mod.tags.from_cargo:
            fail("`.from_cargo` is required. Please update %s" % mod.name)

        for cfg in mod.tags.from_cargo:
            direct_deps.append(cfg.name)

            annotations = {
                annotation.crate: annotation
                for annotation in mod.tags.annotation
                if cfg.name in (annotation.repositories or [cfg.name])
            }

            wasm_blob = None
            if cfg.use_wasm:
                if toml2json == None:
                    toml2json = mctx.load_wasm(Label("@rules_rs//toml2json:toml2json.wasm"))
                wasm_blob = toml2json

            if cfg.use_home_cargo_credentials:
                if not cfg.cargo_config:
                    fail("Must provide cargo_config when using cargo credentials")

                cargo_credentials = load_cargo_credentials(mctx, wasm_blob, cfg.cargo_config)
            else:
                cargo_credentials = {}

            if cfg.debug:
                for _ in range(25):
                    _generate_hub_and_spokes(mctx, wasm_blob, cfg.name, annotations, cfg.cargo_lock, cfg.platform_triples, cargo_credentials, cfg.cargo_config, cfg.debug, dry_run = True)

            facts |= _generate_hub_and_spokes(mctx, wasm_blob, cfg.name, annotations, cfg.cargo_lock, cfg.platform_triples, cargo_credentials, cfg.cargo_config, cfg.debug)

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
        "cargo_config": attr.label(),
        "use_home_cargo_credentials": attr.bool(),
        "platform_triples": attr.string_list(
            mandatory = True,
        ),
        "debug": attr.bool(),
        "use_wasm": attr.bool(),
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
        # "gen_binaries": attr.string_list(
        #     doc = "As a list, the subset of the crate's bins that should get `rust_binary` targets produced.",
        # ),
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
    rctx.file("WORKSPACE.bazel", 'workspace(name = "%s")' % rctx.name)

_hub_repo = repository_rule(
    implementation = _hub_repo_impl,
    attrs = {
        "contents": attr.string_dict(
            doc = "A mapping of file names to text they should contain.",
            mandatory = True,
        ),
    },
)
