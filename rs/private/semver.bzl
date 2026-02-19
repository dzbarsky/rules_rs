def _is_numeric_identifier(s):
    if not s:
        return False
    for ch in s.elems():
        if ch < "0" or ch > "9":
            return False
    return True

def _parse_version_pattern(v):
    """
    Parse a Cargo-semver-like version pattern.

    Supports:
      - full/partial versions: 1.2.3, 1.2, 1
      - prerelease/build metadata: 1.2.3-alpha+001
      - wildcard components in trailing position: *, 1.*, 1.2.*, 1.x, 1.2.x

    Returns:
      {
        "version": (major, minor, patch, prerelease),
        "specified": <count of explicit numeric components>,
        "wildcard_pos": <index of wildcard component or None>,
      }
    or None when parsing fails.
    """
    v = v.strip()
    if not v:
        return None

    # Strip build metadata first (e.g., +001)
    v_no_build = v.split("+", 1)[0]

    # Split out prerelease (e.g., -alpha.1)
    parts = v_no_build.split("-", 1)
    core = parts[0].strip()
    pre = parts[1] if len(parts) > 1 else ""

    if not core:
        return None

    comps = core.split(".")
    if len(comps) > 3:
        return None

    nums = [0, 0, 0]
    specified = len(comps)
    wildcard_pos = None

    for i, comp in enumerate(comps):
        comp = comp.strip()
        if not comp:
            return None
        if comp in ("*", "x", "X"):
            wildcard_pos = i
            specified = i
            # Cargo supports wildcard only in the trailing position.
            if pre or i != len(comps) - 1:
                return None
            break
        if not _is_numeric_identifier(comp):
            return None
        nums[i] = int(comp)

    return {
        "version": (nums[0], nums[1], nums[2], pre),
        "specified": specified,
        "wildcard_pos": wildcard_pos,
    }

def parse_full_version(v):
    parsed = _parse_version_pattern(v)
    if not parsed:
        fail("Invalid semver version: %s" % v)
    return parsed["version"]

def _parse_version(v):
    return parse_full_version(v)[:3]

def _cmp_core(a, b):
    for i in range(3):
        if a[i] != b[i]:
            return -1 if a[i] < b[i] else 1
    return 0

def _cmp(a, b):
    # First compare major/minor/patch.
    core_cmp = _cmp_core(a, b)
    if core_cmp != 0:
        return core_cmp

    # Then compare prerelease according to semver precedence.
    a_pre = a[3]
    b_pre = b[3]
    if a_pre == b_pre:
        return 0
    if not a_pre:
        return 1
    if not b_pre:
        return -1

    a_ids = a_pre.split(".")
    b_ids = b_pre.split(".")
    shared = len(a_ids) if len(a_ids) < len(b_ids) else len(b_ids)

    for i in range(shared):
        a_id = a_ids[i]
        b_id = b_ids[i]
        if a_id == b_id:
            continue

        a_num = _is_numeric_identifier(a_id)
        b_num = _is_numeric_identifier(b_id)
        if a_num and b_num:
            a_int = int(a_id)
            b_int = int(b_id)
            if a_int != b_int:
                return -1 if a_int < b_int else 1
            continue

        if a_num != b_num:
            return -1 if a_num else 1

        return -1 if a_id < b_id else 1

    if len(a_ids) == len(b_ids):
        return 0
    return -1 if len(a_ids) < len(b_ids) else 1

def _core_to_version(core):
    return (core[0], core[1], core[2], "")

def _cargo_default_upper_bound(parsed):
    # Implements semver caret upper bound:
    # increment the leftmost NON-ZERO component of the *specified* version,
    # zeroing the rest; if all zero, bump patch.
    # Examples:
    #   ^1.2.3 -> <2.0.0
    #   ^1.2   -> <2.0.0
    #   ^0.2.3 -> <0.3.0
    #   ^0.0.3 -> <0.0.4
    major, minor, patch = parsed["version"][:3]
    specified = parsed["specified"]
    if major != 0:
        return (major + 1, 0, 0)
    if minor != 0:
        return (0, minor + 1, 0)
    if patch != 0:
        return (0, 0, patch + 1)
    if specified <= 1:
        return (1, 0, 0)
    if specified == 2:
        return (0, 1, 0)
    return (0, 0, 1)

def _tilde_upper_bound(parsed):
    major, minor = parsed["version"][:2]
    if parsed["specified"] <= 1:
        return (major + 1, 0, 0)
    return (major, minor + 1, 0)

def _next_partial_upper_bound(parsed):
    major, minor = parsed["version"][:2]
    if parsed["specified"] <= 1:
        return (major + 1, 0, 0)
    if parsed["specified"] == 2:
        return (major, minor + 1, 0)
    return (major, minor, parsed["version"][2] + 1)

def _wildcard_upper_bound(parsed):
    wildcard_pos = parsed["wildcard_pos"]
    major, minor = parsed["version"][:2]
    if wildcard_pos == 0:
        return None
    if wildcard_pos == 1:
        return (major + 1, 0, 0)
    if wildcard_pos == 2:
        return (major, minor + 1, 0)
    return None

def _split_req_operator(req):
    for op in (">=", "<=", ">", "<", "=", "^", "~"):
        if req.startswith(op):
            return op, req[len(op):].strip()
    return "", req

def _satisfies_comparator(op, rhs_tuple, ver_tuple):
    c = _cmp(ver_tuple, rhs_tuple)
    if op == "<":  return c < 0
    if op == "<=": return c <= 0
    if op == ">":  return c > 0
    if op == ">=": return c >= 0
    if op == "=": return c == 0
    return False

def _normalize_req_to_comparators(req):
    """
    Turn a single requirement string into a list of (op, tuple) comparators.
    Supports Cargo-like requirement syntax for a single clause:
      - comparators: <, <=, >, >=, =
      - caret/bare: ^X.Y.Z, X.Y, X
      - tilde: ~X.Y.Z, ~X.Y, ~X
      - wildcards: *, X.*, X.Y.*, and x aliases
    Returns [] if it can't parse (treated as not matching).
    """
    req = req.strip()
    if not req:
        return []

    op, version_str = _split_req_operator(req)
    parsed = _parse_version_pattern(version_str)
    if not parsed:
        return []

    version = parsed["version"]

    if parsed["wildcard_pos"] != None:
        if op not in ("", "="):
            return []
        lo = (">=", _core_to_version(version[:3]))
        hi_core = _wildcard_upper_bound(parsed)
        if hi_core == None:
            return [lo]
        return [lo, ("<", _core_to_version(hi_core))]

    if op == "":
        op = "^"

    if op == "^":
        lo = (">=", version)
        hi = ("<", _core_to_version(_cargo_default_upper_bound(parsed)))
        return [lo, hi]

    if op == "~":
        lo = (">=", version)
        hi = ("<", _core_to_version(_tilde_upper_bound(parsed)))
        return [lo, hi]

    if op == "=":
        # Cargo treats `=1` as >=1.0.0,<2.0.0 and `=1.2` as >=1.2.0,<1.3.0.
        if parsed["specified"] < 3 and not version[3]:
            lo = (">=", _core_to_version(version[:3]))
            hi = ("<", _core_to_version(_next_partial_upper_bound(parsed)))
            return [lo, hi]
        return [("=", version)]

    # Cargo comparator behavior with partial versions:
    #  - <=1.2 => <1.3.0
    #  - >1.2  => >=1.3.0
    if op == "<=" and parsed["specified"] < 3 and not version[3]:
        return [("<", _core_to_version(_next_partial_upper_bound(parsed)))]
    if op == ">" and parsed["specified"] < 3 and not version[3]:
        return [(">=", _core_to_version(_next_partial_upper_bound(parsed)))]

    return [(op, version)]

def _parse_requirement(req):
    clauses = [p.strip() for p in req.split(",") if p.strip()]
    if not clauses:
        return None

    comparators = []
    for clause in clauses:
        clause_comparators = _normalize_req_to_comparators(clause)
        if not clause_comparators:
            return None
        comparators.extend(clause_comparators)
    return comparators

def _prerelease_allowed(version, comparators):
    # Cargo/semver: prereleases only match if at least one comparator with
    # the same major/minor/patch also has a prerelease.
    if not version[3]:
        return True
    core = version[:3]
    for _, rhs in comparators:
        if rhs[3] and rhs[:3] == core:
            return True
    return False

def select_matching_version(req, versions):
    """
    Supports:
      - caret or bare default: "^X.Y.Z", "X.Y", "0", etc. (Cargo semantics)
      - tilde requirements: "~X.Y.Z", "~X.Y", "~X"
      - wildcard requirements: "*", "X.*", "X.Y.*", and x aliases
      - simple comparators: "<X.Y.Z", "<=X.Y.Z", ">X.Y.Z", ">=X.Y.Z", "=X.Y.Z"
      - comma-AND ranges: ">=0.15.0, <0.17.0"
    Returns highest matching version string, or None.
    """
    comparators = _parse_requirement(req)
    if not comparators:
        return None

    matches = []
    for v in versions:
        parsed = _parse_version_pattern(v)
        if not parsed or parsed["wildcard_pos"] != None:
            continue

        vt = parsed["version"]

        if not _prerelease_allowed(vt, comparators):
            continue

        ok = True
        for op, rhs in comparators:
            if not _satisfies_comparator(op, rhs, vt):
                ok = False
                break
        if ok:
            matches.append((vt, v))

    if not matches:
        return None

    # Pick the highest version tuple.
    best = matches[0]
    for cand in matches[1:]:
        if _cmp(cand[0], best[0]) > 0:
            best = cand
    return best[1]
