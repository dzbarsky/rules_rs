def _filter_by_prefix(deps, prefix):
    return [dep for dep in deps if dep.startswith(prefix)]

def all_crate_deps(
        dep_data,
        normal = False,
        normal_dev = False,
        build = False,
        filter_prefix = None):
    to_return = []

    deps = dep_data["deps"]
    build_deps = dep_data["build_deps"]
    dev_deps = dep_data["dev_deps"]

    if filter_prefix:
        deps = _filter_by_prefix(deps, filter_prefix)
        build_deps = _filter_by_prefix(build_deps, filter_prefix)
        dev_deps = _filter_by_prefix(dev_deps, filter_prefix)

    if normal_dev:
        to_return += dev_deps

    if build:
        to_return += build_deps

    if normal or not to_return:
        to_return += deps

    return to_return
