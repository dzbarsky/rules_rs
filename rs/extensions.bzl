load("@bazel_tools//tools/build_defs/repo:cache.bzl", "get_default_canonical_id")
load("@bazel_tools//tools/build_defs/repo:git.bzl", "new_git_repository")
load("//rs/private:cfg_parser.bzl", "cfg_matches_expr_for_cfg_attrs", "triple_to_cfg_attrs")
load(
    "//rs/private:crate_repository.bzl",
    "crate_repository",
    "generate_build_file",
    "prune_cargo_toml_json",
    "run_toml2json",
)

_DEFAULT_CRATE_ANNOTATION = struct(
    gen_build_script = "auto",
    build_script_data = [],
    build_script_env = {},
    build_script_toolchains = [],
    data = [],
    deps = [],
    crate_features = [],
    rustc_flags = [],
)

def _spoke_repo(hub_name, name, version):
    s = "%s__%s-%s" % (hub_name, name, version)
    if "+" in s:
        s = s.replace("+", "-")
    return s

def _platform(triple):
    return "@rules_rust//rust/platform:" + triple.replace("-musl", "-gnu")

def _select(platform_items, default = []):
    branches = []

    for triple, items in platform_items.items():
        if items:
            branches.append((_platform(triple), repr(sorted(items) if type(items) == "set" else items)))

    if not branches:
        return ""

    branches.append(("//conditions:default", repr(default)))

    return """select({
        %s
    })""" % (
        ",\n        ".join(['"%s": %s' % branch for branch in branches])
    )

def _add_to_dict(d, k, v):
    existing = d.get(k, [])
    if not existing:
        d[k] = existing
    existing.extend(v)

def _fq_crate(name, version):
    return name + "-" + version

_ALL_PLATFORMS = "*"

def _new_feature_resolutions(possible_deps, possible_dep_fq_crate_by_name, possible_features, platform_triples):
    triples = platform_triples + [_ALL_PLATFORMS]
    features_enabled = {triple: set() for triple in triples}
    deps = {triple: set() for triple in triples}

    return struct(
        features_enabled = features_enabled,
        # Fast-path for access
        features_enabled_for_all_platforms = features_enabled[_ALL_PLATFORMS],

        # If set, we will set `target_compatible_with`. If have "*" that means all.
        triples_compatible_with = set(),

        # TODO(zbarsky): Do these also need the platform-specific variants?
        build_deps = set(),

        deps = deps,
        # Fast-path for access
        deps_all_platforms = deps[_ALL_PLATFORMS],

        aliases = {triple: dict() for triple in triples},

        # Following data is immutable, it comes from crates.io + Cargo.lock
        possible_deps = possible_deps,
        possible_dep_fq_crate_by_name = possible_dep_fq_crate_by_name,
        possible_features = possible_features,
    )

def _count(feature_resolutions_by_fq_crate):
    n = 0
    for feature_resolutions in feature_resolutions_by_fq_crate.values():
        for features in feature_resolutions.features_enabled.values():
            n += len(features)

        n += len(feature_resolutions.build_deps)
        for deps in feature_resolutions.deps.values():
            n += len(deps)

        # No need to count aliases, they only get set when deps are set.
    return n

def _resolve_one_round(hub_name, feature_resolutions_by_fq_crate, platform_triples, debug):
    changed = False

    for fq_crate, feature_resolutions in feature_resolutions_by_fq_crate.items():
        features_enabled = feature_resolutions.features_enabled
        features_enabled_for_all_platforms = feature_resolutions.features_enabled_for_all_platforms

        deps = feature_resolutions.deps
        deps_all_platforms = feature_resolutions.deps_all_platforms

        possible_dep_fq_crate_by_name = feature_resolutions.possible_dep_fq_crate_by_name

        if _propagate_feature_enablement(
            changed,
            fq_crate,
            features_enabled,
            feature_resolutions,
            feature_resolutions_by_fq_crate,
            possible_dep_fq_crate_by_name,
            debug,
        ):
            changed = True

        # Propagate features across currently enabled dependencies.
        for dep in feature_resolutions.possible_deps:
            bazel_target = dep.get("bazel_target")

            kind = dep.get("kind", "normal")
            if kind == "normal" and bazel_target and bazel_target in deps_all_platforms:
                # Bail early if feature is maximally enabled.
                continue

            if kind == "build":
                if not bazel_target:
                    # print("Build dep not found %s" % dep)
                    continue
                build_deps = feature_resolutions.build_deps
                if changed or bazel_target not in build_deps:
                    changed = True
                    build_deps.add(bazel_target)
                continue

            if "package" in dep:
                dep_name = dep["package"]
                dep_alias = dep["name"]
            else:
                dep_name = dep["name"]
                dep_alias = dep_name

            if dep_name == "rustc-std-workspace-alloc":
                # Internal rustc placeholder crate.
                continue

            if bazel_target:
                dep_fq = possible_dep_fq_crate_by_name[dep_name]
                dep_feature_resolutions = feature_resolutions_by_fq_crate[dep_fq]

            disabled_on_all_platforms = dep.get("optional", False) and dep_alias not in features_enabled_for_all_platforms

            for triple in dep["target"]:
                if disabled_on_all_platforms and (triple == _ALL_PLATFORMS or dep_alias not in features_enabled[triple]):
                    continue

                if not bazel_target:
                    fail("Matched %s but it wasn't part of the lockfile! This is unsupported!" % dep)

                triple_deps = deps[triple]
                if changed or bazel_target not in triple_deps:
                    changed = True
                    triple_deps.add(bazel_target)

                if dep_name != dep_alias:
                    feature_resolutions.aliases[triple][bazel_target] = dep_alias.replace("-", "_")

                dep_feature_resolutions.triples_compatible_with.add(triple)
                triple_features = dep_feature_resolutions.features_enabled[triple]

                prev_length = 0 if changed else len(triple_features)
                triple_features.update(dep.get("features", []))
                if dep.get("default_features", True):
                    triple_features.add("default")
                if not changed and prev_length != len(triple_features):
                    changed = True

    return changed

def _propagate_feature_enablement(
        changed,
        fq_crate,
        features_enabled,
        feature_resolutions,
        feature_resolutions_by_fq_crate,
        possible_dep_fq_crate_by_name,
        debug):
    possible_features = feature_resolutions.possible_features

    for triple, feature_set in features_enabled.items():
        if not feature_set:
            continue

        # Enable any features that are implied by previously-enabled features.
        for enabled_feature in list(feature_set):
            enables = possible_features.get(enabled_feature)
            if not enables:
                continue

            for feature in enables:
                idx = feature.find("/")
                if idx == -1:
                    feature = feature.removeprefix("dep:")
                    if changed or feature not in feature_set:
                        changed = True
                        feature_set.add(feature)
                    continue

                dep_name = feature[:idx]
                dep_feature = feature[idx + 1:]

                if dep_name[-1] == "?":
                    dep_name = dep_name[:-1]
                else:
                    # TODO(zbarsky): Technically this is not an enabled feature, but it's a way to get the dep enabled in the next loop iteration.
                    if changed or dep_name not in feature_set:
                        changed = True
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
                    if debug:
                        print("Skipping enabling subfeature", feature, "for", fq_crate, "it's not a dep...")
                    continue

                triple_features = feature_resolutions_by_fq_crate[dep_fq].features_enabled[triple]
                if changed or dep_feature not in triple_features:
                    changed = True
                    triple_features.add(dep_feature)

    return changed

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
    return "https://raw.githubusercontent.com/%s/%s/Cargo.toml" % _parse_git_url(url)

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

def _date(ctx, label):
    return
    result = ctx.execute(["gdate", '+"%Y-%m-%d %H:%M:%S.%3N"'])
    print(label, result.stdout)

def _generate_hub_and_spokes(
        mctx,
        hub_name,
        annotations,
        cargo_lock_path,
        platform_triples,
        debug,
        dry_run = False):
    """Generates repositories for the transitive closure of the Cargo workspace.

    Args:
        mctx (module_ctx): The module context object.
        annotations (dict): Annotation tags to apply.
        hub_name (string): name
        cargo_lock_path (path): Cargo.lock path
        platform_triples (list[string]): Triples to resolve for
    """
    _date(mctx, "start")
    mctx.watch(cargo_lock_path)
    cargo_lock = run_toml2json(mctx, cargo_lock_path)
    _date(mctx, "parsed")

    existing_facts = getattr(mctx, "facts", {}) or {}
    facts = {}

    # Ignore workspace members
    workspace_members = [p for p in cargo_lock["package"] if "source" not in p]
    packages = [p for p in cargo_lock["package"] if p.get("source")]

    download_tokens = []

    versions_by_name = dict()
    for package in packages:
        name = package["name"]
        version = package["version"]

        _add_to_dict(versions_by_name, name, [version])

        source = package["source"]

        if source == "registry+https://github.com/rust-lang/crates.io-index":
            key = name + "_" + version
            fact = existing_facts.get(key)
            if fact:
                facts[key] = fact
                continue

            # TODO(zbarsky): dedupe fetches when multiple versions?
            # TODO(zbarsky): Support custom registries
            url = "https://index.crates.io/" + _sharded_path(name)
            token = mctx.download(
                url,
                key + ".jsonl",
                canonical_id = get_default_canonical_id(mctx, urls = [url]),
                block = False,
            )
            download_tokens.append(token)
        elif source.startswith("git+https://github.com/"):
            # TODO(zbarsky): Support other forges
            key = source + "_" + name
            fact = existing_facts.get(key)
            if fact:
                facts[key] = fact
                continue

            url = _git_url_to_cargo_toml(source)
            token = mctx.download(
                url,
                "%s_%s.Cargo.toml" % (name, version),
                canonical_id = get_default_canonical_id(mctx, urls = [url]),
                block = False,
            )
            download_tokens.append(token)
        else:
            fail("Unknown source " + source)

    _date(mctx, "kicked off downloads")

    cargo = mctx.path(Label("@rs_rust_host_tools//:bin/cargo"))
    result = mctx.execute(
        [cargo, "metadata", "--no-deps", "--format-version=1", "--quiet"],
        working_directory = str(mctx.path(cargo_lock_path).dirname),
    )
    if result.return_code != 0:
        fail(result.stdout + "\n" + result.stderr)
    cargo_metadata = json.decode(result.stdout)

    _date(mctx, "parsed cargo metadata")

    # TODO(zbarsky): we should run downloads across all hubs in parallel instead of blocking here.
    mctx.report_progress("Downloading metadata")
    for token in download_tokens:
        result = token.wait()
        if not result.success:
            fail("Could not download")

    platform_cfg_attrs = [triple_to_cfg_attrs(triple, [], []) for triple in platform_triples]

    _date(mctx, "got tokens")

    mctx.report_progress("Computing dependencies and features")

    feature_resolutions_by_fq_crate = dict()

    match_all = [_ALL_PLATFORMS]
    cfg_match_cache = { None: match_all }

    for package in packages:
        name = package["name"]
        version = package["version"]
        source = package["source"]

        possible_dep_fq_crate_by_name = _compute_package_fq_deps(package, versions_by_name)

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
        else:
            key = source + "_" + name
            fact = facts.get(key)
            if fact:
                fact = json.decode(fact)
            else:
                strip_prefix = None
                cargo_toml_json = run_toml2json(mctx, "%s_%s.Cargo.toml" % (name, version))

                if cargo_toml_json.get("package", {}).get("name") != name:
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
                        cargo_toml_json = run_toml2json(mctx, download_path)

                dependencies = []
                for dep, spec in cargo_toml_json.get("dependencies", {}).items():
                    if type(spec) == "string":
                        dependencies.append({
                            "name": dep,
                        })
                    else:
                        dependencies.append({
                            "name": dep,
                            "optional": spec.get("optional", False),
                            "default_features": spec.get("default_features", True),
                            "features": spec.get("features", []),
                        })

                for dep, spec in cargo_toml_json.get("build-dependencies", {}).items():
                    if type(spec) == "string":
                        dependencies.append({
                            "name": dep,
                            "kind": "build",
                        })
                    else:
                        dependencies.append({
                            "name": dep,
                            "kind": "build",
                            "optional": spec.get("optional", False),
                            "default_features": spec.get("default_features", True),
                            "features": spec.get("features", []),
                        })

                if not dependencies and debug:
                    print(name, version, package["source"])

                fact = dict(
                    features = cargo_toml_json.get("features", {}),
                    cargo_toml_json = prune_cargo_toml_json(cargo_toml_json),
                    dependencies = dependencies,
                    strip_prefix = strip_prefix,
                )

                # Nest a serialized JSON since max path depth is 5.
                facts[key] = json.encode(fact)

            package["strip_prefix"] = fact["strip_prefix"]
            package["cargo_toml_json"] = fact["cargo_toml_json"]

        possible_features = fact["features"]
        possible_deps = [dep for dep in fact["dependencies"] if dep.get("kind") != "dev"]

        for dep in possible_deps:
            dep_name = dep.get("package")
            if not dep_name:
                dep_name = dep["name"]

            target = dep.get("target")
            match = cfg_match_cache.get(target)
            if not match:
                match = cfg_matches_expr_for_cfg_attrs(target, platform_cfg_attrs)
                if len(match) == len(platform_cfg_attrs):
                    match = match_all
                cfg_match_cache[target] = match
            dep["target"] = match

            dep_fq = possible_dep_fq_crate_by_name.get(dep_name)
            if not dep_fq:
                # print("NOT FOUND", dep)
                continue

            dep["bazel_target"] = "@%s//:%s" % (hub_name, dep_fq)


        feature_resolutions_by_fq_crate[_fq_crate(name, version)] = (
            _new_feature_resolutions(possible_deps, possible_dep_fq_crate_by_name, possible_features, platform_triples)
        )

    _date(mctx, "set up resolutions")

    workspace_fq_deps = _compute_workspace_fq_deps(workspace_members, versions_by_name)

    workspace_deps = set()

    # Set initial set of features from Cargo.tomls
    for package in cargo_metadata["packages"]:
        fq_deps = workspace_fq_deps[package["name"]]

        for dep in package["dependencies"]:
            if dep["source"] != "registry+https://github.com/rust-lang/crates.io-index":
                continue
            name = dep["name"]
            workspace_deps.add(name)

            features = dep["features"]
            if dep["uses_default_features"]:
                features.append("default")

            # Assume we could build top-level dep on any platform.
            feature_resolutions = feature_resolutions_by_fq_crate[fq_deps[name]]
            feature_resolutions.features_enabled_for_all_platforms.update(features)
            feature_resolutions.triples_compatible_with.add(_ALL_PLATFORMS)

    # Set initial set of features from annotations
    for crate, annotation in annotations.items():
        if annotation.crate_features:
            for version in versions_by_name[crate]:
                feature_resolutions_by_fq_crate[_fq_crate(crate, version)].features_enabled_for_all_platforms.update(annotation.crate_features)

    _date(mctx, "set up initial deps!")

    # Do some rounds of mutual resolution; bail when no more changes
    for i in range(20):
        mctx.report_progress("Running round %s of dependency/feature resolution" % i)

        if not _resolve_one_round(hub_name, feature_resolutions_by_fq_crate, platform_triples, debug):
            if debug:
                count = _count(feature_resolutions_by_fq_crate)
                print("Got count", count, "in", i, "rounds")
            break

    mctx.report_progress("Initializing spokes")

    for package in packages:
        name = package["name"]
        version = package["version"]
        checksum = package.get("checksum")

        feature_resolutions = feature_resolutions_by_fq_crate[_fq_crate(name, version)]

        triples_compatible_with = feature_resolutions.triples_compatible_with

        if "*" in triples_compatible_with or not triples_compatible_with:
            triples_compatible_with = set(platform_triples)

        all_platform_deps = feature_resolutions.deps.pop(_ALL_PLATFORMS)
        all_aliases = feature_resolutions.aliases.pop(_ALL_PLATFORMS)
        features_enabled = feature_resolutions.features_enabled.pop(_ALL_PLATFORMS)

        # Remove conditional deps that are present on all platforms already.
        for deps in feature_resolutions.deps.values():
            deps.difference_update(all_platform_deps)

        conditional_deps = _select(feature_resolutions.deps)
        conditional_aliases = _select(feature_resolutions.aliases, default = {})
        conditional_crate_features = _select(feature_resolutions.features_enabled)

        annotation = annotations.get(name)
        if not annotation:
            annotation = _DEFAULT_CRATE_ANNOTATION

        kwargs = dict(
            crate = name,
            version = version,
            checksum = checksum,
            gen_build_script = annotation.gen_build_script,
            build_deps = sorted(feature_resolutions.build_deps),
            build_script_data = annotation.build_script_data,
            build_script_env = annotation.build_script_env,
            build_script_toolchains = annotation.build_script_toolchains,
            rustc_flags = annotation.rustc_flags,
            data = annotation.data,
            deps = sorted(all_platform_deps | set(annotation.deps)),
            conditional_deps = " + " + conditional_deps if conditional_deps else "",
            aliases = all_aliases,
            conditional_aliases = " | " + conditional_aliases if conditional_aliases else "",
            crate_features = repr(sorted(features_enabled | set(annotation.crate_features))),
            conditional_crate_features = " + " + conditional_crate_features if conditional_crate_features else "",
            target_compatible_with = [_platform(triple) for triple in sorted(triples_compatible_with)],
            fallback_edition = package.get("edition"),
        )

        repo_name = _spoke_repo(hub_name, name, version)

        if checksum:
            if dry_run:
                continue

            name_version = (name, version)

            crate_repository(
                name = repo_name,
                url = "https://crates.io/api/v1/crates/%s/%s/download" % name_version,
                strip_prefix = "%s-%s" % name_version,
                **kwargs
            )
        else:
            build_file_content = generate_build_file(struct(**kwargs), package["cargo_toml_json"])

            repo_path, sha = _parse_git_url(package["source"])

            if dry_run:
                continue

            new_git_repository(
                name = repo_name,
                init_submodules = True,
                build_file_content = build_file_content,
                strip_prefix = package.get("strip_prefix"),
                commit = sha,
                remote = "https://github.com/%s.git" % repo_path,
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

    _date(mctx, "done")

    if dry_run:
        return

    _hub_repo(
        name = hub_name,
        contents = {
            "BUILD.bazel": "\n".join(hub_contents),
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

            if cfg.debug:
                for _ in range(150):
                    _generate_hub_and_spokes(mctx, cfg.name, annotations, cfg.cargo_lock, cfg.platform_triples, cfg.debug, dry_run = True)

            facts |= _generate_hub_and_spokes(mctx, cfg.name, annotations, cfg.cargo_lock, cfg.platform_triples, cfg.debug)

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
