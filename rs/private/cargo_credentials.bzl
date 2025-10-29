load("@aspect_bazel_lib//lib:repo_utils.bzl", "repo_utils")
load(":toml2json.bzl", "run_toml2json")

def load_cargo_credentials(mctx, cargo_config):
    home_directory = repo_utils.get_home_directory(mctx)
    if not home_directory:
        fail("""
ERROR: Cannot determine home directory in order to load home `.cargo/credentials.toml` file.
""")

    credentials_path = "{}/{}".format(home_directory, ".cargo/credentials.toml")
    credentials = run_toml2json(mctx, credentials_path)["registries"]
    registry_map = run_toml2json(mctx, cargo_config)["registries"]

    result = {}
    for name, data in registry_map.items():
        index = data["index"]
        if name in credentials:
            result[index] = credentials[name]["token"]

    return result

def registry_auth_headers(cargo_credentials, source):
    token = cargo_credentials.get(source)
    if token:
        return {"Authorization": token}

    return {}