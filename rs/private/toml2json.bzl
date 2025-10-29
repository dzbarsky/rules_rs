load("@aspect_bazel_lib//lib:repo_utils.bzl", "repo_utils")

def run_toml2json(ctx, toml_file):
    toml2json = "@toml2json_%s//file:downloaded" % repo_utils.platform(ctx)

    result = ctx.execute([Label(toml2json), toml_file])
    if result.return_code != 0:
        fail(result.stdout + result.stderr)

    return json.decode(result.stdout)