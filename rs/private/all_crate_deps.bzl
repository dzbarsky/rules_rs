load(":select_utils.bzl", "compute_select")

def _filter_by_prefix(deps, prefix):
    return [dep for dep in deps if dep.startswith(prefix)]

def _kind_dep_spec(dep_data, kind):
    return (
        dep_data.get(kind, []),
        dep_data.get(kind + "_by_platform", {}),
    )

def merge_structured_dep_specs(specs, platforms, filter_prefix):
    merged_by_platform = {}
    merged_deps = set()

    for platform in platforms:
        merged_by_platform[platform] = set()

    for shared_items, per_platform_items in specs:
        for dep in shared_items:
            if not filter_prefix or dep.startswith(filter_prefix):
                merged_deps.add(dep)

        for platform, deps in per_platform_items.items():
            filtered = _filter_by_prefix(deps, filter_prefix) if filter_prefix else deps
            if not filtered:
                continue

            existing = merged_by_platform.get(platform)
            if existing == None:
                merged_by_platform[platform] = set(filtered)
                continue

            existing.update(filtered)

    deps, per_platform = compute_select(merged_deps, merged_by_platform)
    return sorted(deps), per_platform

def all_crate_deps(
        dep_data,
        platforms,
        normal = False,
        normal_dev = False,
        build = False,
        filter_prefix = None):
    specs = []

    if normal_dev:
        specs.append(_kind_dep_spec(dep_data, "dev_deps"))

    if build:
        specs.append(_kind_dep_spec(dep_data, "build_deps"))

    if normal or not specs:
        specs.append(_kind_dep_spec(dep_data, "deps"))

    deps, per_platform = merge_structured_dep_specs(
        specs,
        platforms,
        filter_prefix,
    )
    if not per_platform:
        return deps

    branches = {platform: deps for platform, deps in sorted(per_platform.items())}
    branches["//conditions:default"] = []
    return deps + select(branches)
