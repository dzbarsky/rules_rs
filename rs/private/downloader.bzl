load("@bazel_tools//tools/build_defs/repo:git_worker.bzl", "git_repo")
load(":cargo_credentials.bzl", "registry_auth_headers")
load(":default_annotation.bzl", "DEFAULT_CRATE_ANNOTATION")
load(":toml2json.bzl", "run_toml2json")

CRATES_IO_REGISTRY = "sparse+https://index.crates.io/"

def parse_git_url(url):
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
    remote, sha = parse_git_url(url)
    repo_path = remote.removeprefix("https://github.com/").removesuffix(".git")
    return repo_path, sha

def _github_source_to_raw_content_base_url(url):
    return "https://raw.githubusercontent.com/%s/%s/" % _parse_github_url(url)

def sharded_path(crate):
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

def new_downloader_state():
    return struct(
        in_flight_sparse_registry_configs_by_source = {},
        in_flight_registry_fetches_by_crate = {},
        in_flight_git_crate_fetches_by_url = {},
        pending_git_clones_by_source = {},
    )

def start_github_downloads(
        mctx,
        state,
        annotations,
        packages):
    existing_facts = getattr(mctx, "facts", {}) or {}

    for package in packages:
        source = package.get("source", "")
        if not source.startswith("git+https://github.com/"):
            continue

        name = package["name"]

        key = source + "_" + name
        if key in existing_facts:
            continue

        annotation = annotations.get(name, DEFAULT_CRATE_ANNOTATION)
        url = _github_source_to_raw_content_base_url(source) + annotation.workspace_cargo_toml
        in_flight_fetch = state.in_flight_git_crate_fetches_by_url.get(url)
        if in_flight_fetch:
            in_flight_fetch.packages.append(package)
        else:
            in_flight_fetch = struct(
                download_token = mctx.download(
                    url,
                    url.replace("/", "_"),
                    allow_fail = True,
                    block = False,
                ),
                packages = [package],
            )
            state.in_flight_git_crate_fetches_by_url[url] = in_flight_fetch

        package["download_token"] = in_flight_fetch

def start_crate_registry_downloads(
        mctx,
        state,
        wasm_blob,
        annotations,
        packages,
        cargo_credentials,
        debug):
    existing_facts = getattr(mctx, "facts", {}) or {}

    for package in packages:
        source = package.get("source")
        if not source:
            continue


        if source == "registry+https://github.com/rust-lang/crates.io-index":
            source = CRATES_IO_REGISTRY
            package["source"] = source
            # We hardcode the response for crates.io to avoid a fetch in
            # the common case when not using a custom registry.
            # TODO(zbarsky): This could be solved more cleanly by using a repository rule
            # to do these fetches, thus making them lazy.
        elif source.startswith("sparse+") and source not in state.in_flight_sparse_registry_configs_by_source:
            registry = source.removeprefix("sparse+")

            state.in_flight_sparse_registry_configs_by_source[source] = mctx.download(
                registry + "config.json",
                source.replace("/", "_") + "config.json",
                headers = registry_auth_headers(cargo_credentials, source),
                block = False,
            )

    for package in packages:
        source = package.get("source")
        if not source:
            continue

        name = package["name"]
        version = package["version"]

        if source.startswith("sparse+"):
            key = name + "_" + version
            if key in existing_facts:
                continue

            in_flight_fetch = state.in_flight_registry_fetches_by_crate.get(name)
            if not in_flight_fetch:
                url = source.removeprefix("sparse+") + sharded_path(name.lower())
                in_flight_fetch = mctx.download(
                    url,
                    name + ".jsonl",
                    headers = registry_auth_headers(cargo_credentials, source),
                    block = False,
                )
                state.in_flight_registry_fetches_by_crate[name] = in_flight_fetch

            package["download_token"] = in_flight_fetch
        elif source.startswith("git+"):
            # TODO(zbarsky): Ideally other forges could use the single-file fastpath...
            if source.startswith("git+https://github.com/"):
                # Github already handled above
                continue

            key = source + "_" + name
            if key in existing_facts:
                continue

            clone_state = state.pending_git_clones_by_source.get(source)
            if clone_state:
                clone_state.packages.append(package)
                continue

            remote, commit = parse_git_url(source)
            state.pending_git_clones_by_source[source] = struct(
                clone_config = struct(
                    delete = lambda _: 0,
                    execute = mctx.execute,
                    os = mctx.os,
                    name = name,
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
                ),
                packages = [package],
            )
        else:
            fail("Unknown source " + source)

def _ensure_cargo_toml_exists(cargo_toml_path, fetch_state):
    if not cargo_toml_path.exists:
        fail("""

ERROR: Could not download root Cargo.toml for {name} from git repository, perhaps the repo root is not the Cargo workspace root?
Please indicate the path to the workspace Cargo.toml (or the crate itself, if not part of a workspace) in MODULE.bazel, like so:

crate.annotation(
     crate = "{name}",
     workspace_cargo_toml = "path/to/Cargo.toml",
)

""".format(name = fetch_state.packages[0]["name"]))
        # TODO(zbarsky): ^^ this currently needs to be configured for all packages, should we make it nicer?

def _compute_strip_prefix(annotation, cargo_toml_json, name):
    strip_prefix = annotation.strip_prefix

    workspace = cargo_toml_json["workspace"]

    if not strip_prefix and name in workspace["members"]:
        strip_prefix = name

    if not strip_prefix:
        # Handle `uv-python = { path = "crates/uv-python" }` when `members` includes wildcard.
        dep = workspace["dependencies"].get(name)
        if type(dep) == "dict":
            strip_prefix = dep["path"]

    if not strip_prefix:
        # Handle `wirefilter = { path = "engine", package = "wirefilter-engine" }` when crate is aliased internally.
        for dep in workspace["dependencies"].values():
            if type(dep) == "dict" and dep.get("package") == name:
                strip_prefix = dep["path"]
                break

    # TODO(zbarsky): any more cases to handle here?
    return strip_prefix

def download_metadata_for_git_crates(
        mctx,
        state,
        wasm_blob,
        annotations):
    for url, fetch_state in state.in_flight_git_crate_fetches_by_url.items():
        cargo_toml_path = url.replace("/", "_")
        _ensure_cargo_toml_exists(mctx.path(cargo_toml_path), fetch_state)

        cargo_toml_json = run_toml2json(mctx, wasm_blob, cargo_toml_path)

        for package in fetch_state.packages:
            name = package["name"]

            if cargo_toml_json.get("package", {}).get("name") != name:
                annotation = annotations.get(name, DEFAULT_CRATE_ANNOTATION)
                strip_prefix = _compute_strip_prefix(annotation, cargo_toml_json, name)

                if not strip_prefix:
                    fail("Could not compute strip_prefix and could not find crate")

                package["strip_prefix"] = strip_prefix
                child_url = url.replace("Cargo.toml", strip_prefix + "/Cargo.toml")

                child_cargo_toml_path = child_url.replace("/", "_")
                package["member_crate_cargo_toml_info"] = struct(
                    token = mctx.download(child_url, child_cargo_toml_path, block = False),
                    path = child_cargo_toml_path,
                )

                package["workspace_cargo_toml_json"] = cargo_toml_json
            else:
                package["cargo_toml_json"] = cargo_toml_json

    for source, clone_state in state.pending_git_clones_by_source.items():
        clone_dir = mctx.path(source.replace("/", "_"))
        git_repo(clone_state.clone_config, clone_dir)

        # TODO(zbarsky): multiple crates?
        annotation = annotations.get(clone_state.packages[0]["name"], DEFAULT_CRATE_ANNOTATION)
        cargo_toml_path = clone_dir.get_child(annotation.workspace_cargo_toml)
        _ensure_cargo_toml_exists(cargo_toml_path, clone_state)
        cargo_toml_json = run_toml2json(mctx, wasm_blob, cargo_toml_path)

        for package in clone_state.packages:
            name = package["name"]

            if cargo_toml_json.get("package", {}).get("name") != name:
                annotation = annotations.get(name, DEFAULT_CRATE_ANNOTATION)
                strip_prefix = _compute_strip_prefix(annotation, cargo_toml_json, name)

                if not strip_prefix:
                    fail("Could not compute strip_prefix and could not find crate")

                package["strip_prefix"] = strip_prefix
                package["workspace_cargo_toml_json"] = cargo_toml_json
                child_cargo_toml_path = str(cargo_toml_path).replace("Cargo.toml", strip_prefix + "/Cargo.toml")
                package["cargo_toml_json"] = run_toml2json(mctx, wasm_blob, child_cargo_toml_path)
            else:
                package["cargo_toml_json"] = cargo_toml_json

def download_sparse_registry_configs(mctx, state):
    # Hardcoded one to avoid the fetch...
    sparse_registry_configs = {
        CRATES_IO_REGISTRY: "https://static.crates.io/crates/{crate}/{version}/download",
    }

    for source, token in state.in_flight_sparse_registry_configs_by_source.items():
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

    return sparse_registry_configs
