def _count(feature_resolutions_by_fq_crate):
    n = 0
    for feature_resolutions in feature_resolutions_by_fq_crate.values():
        for features in feature_resolutions.features_enabled.values():
            n += len(features)

        for build_deps in feature_resolutions.build_deps.values():
            n += len(build_deps)

        for deps in feature_resolutions.deps.values():
            n += len(deps)

        # No need to count aliases, they only get set when deps are set.
    return n

def _resolve_one_round(packages, dirty_package_indices, debug):
    new_dirty_package_indices = set()

    for index in dirty_package_indices:
        package = packages[index]
        package_changed = False

        feature_resolutions = package["feature_resolutions"]
        features_enabled = feature_resolutions.features_enabled

        deps = feature_resolutions.deps

        if _propagate_feature_enablement(
            package_changed,
            new_dirty_package_indices,
            package,
            features_enabled,
            feature_resolutions,
            debug,
        ):
            package_changed = True

        # Propagate features across currently enabled dependencies.
        for dep in feature_resolutions.possible_deps:
            bazel_target = dep.get("bazel_target")
            if not bazel_target:
                continue

            kind = dep.get("kind", "normal")

            dep_feature_resolutions = dep["feature_resolutions"]

            has_alias = "package" in dep
            dep_name = dep["name"]
            prefixed_dep_alias = "dep:" + dep_name
            optional = dep.get("optional", False)

            to_remove = None
            match = dep["target"]

            for triple in match:
                if optional:
                    features_for_triple = features_enabled[triple]
                    if dep_name not in features_for_triple and prefixed_dep_alias not in features_for_triple:
                        continue

                triple_deps = deps[triple] if kind == "normal" else feature_resolutions.build_deps[triple]
                if package_changed or bazel_target not in triple_deps:
                    package_changed = True
                    triple_deps.add(bazel_target)

                if has_alias:
                    feature_resolutions.aliases[bazel_target] = dep_name.replace("-", "_")

                triple_features = dep_feature_resolutions.features_enabled[triple]

                dep_features = dep.get("features")
                if dep_features:
                    prev_length = len(triple_features)
                    triple_features.update(dep_features)
                    if prev_length != len(triple_features):
                        new_dirty_package_indices.add(dep_feature_resolutions.package_index)
                if not to_remove:
                    to_remove = set()
                to_remove.add(triple)

            if to_remove:
                if len(to_remove) == len(match):
                    dep["bazel_target"] = None
                else:
                    match.difference_update(to_remove)

        if package_changed:
            new_dirty_package_indices.add(index)

    return new_dirty_package_indices

def _propagate_feature_enablement(
        package_changed,
        dirty_package_indices,
        package,
        features_enabled,
        feature_resolutions,
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
                    if feature not in feature_set:
                        package_changed = True
                        feature_set.add(feature)
                    continue

                dep_name = feature[:idx]
                dep_feature = feature[idx + 1:]

                dep_optional = False
                if dep_name[-1] == "?":
                    dep_name = dep_name[:-1]

                found = False
                for dep in feature_resolutions.possible_deps:
                    if dep["name"] == dep_name:
                        found = True
                        dep_optional = dep.get("optional", False)
                        dep_feature_resolutions = dep["feature_resolutions"]
                        triple_features = dep_feature_resolutions.features_enabled[triple]
                        if dep_feature not in triple_features:
                            triple_features.add(dep_feature)
                            dirty_package_indices.add(dep_feature_resolutions.package_index)
                        break

                # Only optional deps need to be explicitly enabled when a subfeature is toggled.
                if dep_optional and dep_name not in feature_set:
                    package_changed = True
                    feature_set.add(dep_name)

                if not found and debug:
                    print("Skipping enabling subfeature", feature, "for", package["name"], "@", package["version"], "it's not a dep...")

    return package_changed

_MAX_ROUNDS = 50

def resolve(mctx, packages, feature_resolutions_by_fq_crate, debug):
    # Do some rounds of mutual resolution; bail when no more changes
    dirty_package_indices = range(len(packages))
    for i in range(_MAX_ROUNDS):
        mctx.report_progress("Running round %s of dependency/feature resolution" % i)

        dirty_package_indices = _resolve_one_round(packages, dirty_package_indices, debug)
        if not dirty_package_indices:
            if debug:
                count = _count(feature_resolutions_by_fq_crate)
                print("Got count", count, "in", i + 1, "rounds")
            break
        dirty_package_indices = sorted(dirty_package_indices)

        if i == _MAX_ROUNDS:
            fail("Resolution did not converge! This is likely a bug in rules_rs, please report it to github.com/dzbarsky/rules_rs")
