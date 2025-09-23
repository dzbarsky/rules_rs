def _parse_version(v):
    # Drop prerelease/build if present (e.g., 1.2.3-alpha+001)
    v = v.split("-", 1)[0].split("+", 1)[0]
    parts = v.split(".")
    # Pad to 3 components
    nums = []
    for i in range(3):
        if i < len(parts) and parts[i] != "":
            # Allow leading zeros; treat non-numeric as 0
            #try:
            nums.append(int(parts[i]))
            #except:
            #    nums.append(0)
        else:
            nums.append(0)
    # major, minor, patch
    return tuple(nums)

def _cmp(a, b):
    for i in range(3):
        if a[i] != b[i]:
            return -1 if a[i] < b[i] else 1
    return 0

def _cargo_default_upper_bound(base):
    # Implements semver caret upper bound:
    # increment the leftmost NON-ZERO component of the *specified* version,
    # zeroing the rest; if all zero, bump patch.
    # Examples:
    #   ^1.2.3 -> <2.0.0
    #   ^1.2   -> <2.0.0
    #   ^0.2.3 -> <0.3.0
    #   ^0.0.3 -> <0.0.4
    major, minor, patch = base
    if major != 0:
        return (major + 1, 0, 0)
    if minor != 0:
        return (0, minor + 1, 0)
    if patch != 0:
        return (0, 0, patch + 1)
    return (1, 0, 0)

def _range_for_caret(req_ver_tuple):
    low = req_ver_tuple
    high = _cargo_default_upper_bound(req_ver_tuple)
    return (low, high)

def _satisfies_caret(req_tuple, ver_tuple):
    low, high = _range_for_caret(req_tuple)
    return _cmp(ver_tuple, low) >= 0 and _cmp(ver_tuple, high) < 0

def _satisfies_caret_or_bare(req_tuple, ver_tuple):
    lo = req_tuple
    hi = _cargo_default_upper_bound(req_tuple)
    return _cmp(ver_tuple, lo) >= 0 and _cmp(ver_tuple, hi) < 0

def _parse_comparator_req(req):
    for op in (">=", ">", "=", "<=", "<"):
        if req.startswith(op):
            return op, _parse_version(req[len(op):])

    return None

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
    Supports:
      - comparator forms: <, <=, >, >=, =
      - caret/bare: ^X.Y.Z, X.Y, X
    Returns [] if it can't parse (treated as not matching).
    """
    req = req.strip()
    cmp_req = _parse_comparator_req(req)
    if cmp_req:
        op, rhs = cmp_req
        return [(op, rhs)]

    # caret or bare (Cargo semantics)
    base = _parse_version(req.removeprefix("^"))
    lo = (">=", base)
    hi = ("<", _cargo_default_upper_bound(base))
    return [lo, hi]


def _satisfies_all_clauses(req, ver_tuple):
    """
    Handle comma-separated AND-clauses like:
      '>=0.15.0, <0.17.0'
    Each clause can be a comparator or caret/bare; all must pass.
    """
    clauses = [p.strip() for p in req.split(",") if p.strip()]
    if not clauses:
        return False

    for clause in clauses:
        comps = _normalize_req_to_comparators(clause)
        if not comps:
            return False
        ok = True
        for op, rhs in comps:
            if not _satisfies_comparator(op, rhs, ver_tuple):
                ok = False
                break
        if not ok:
            return False
    return True

def select_matching_version(req, versions):
    """
    Supports:
      - caret or bare default: "^X.Y.Z", "X.Y", "0", etc. (Cargo semantics)
      - simple comparators: "<X.Y.Z", "<=X.Y.Z", ">X.Y.Z", ">=X.Y.Z", "=X.Y.Z"
      - comma-AND ranges: ">=0.15.0, <0.17.0"
    Returns highest matching version string, or None.
    """
    matches = []

    # If there's a comma, treat it as an ANDed set of clauses.
    if "," in req:
        for v in versions:
            vt = _parse_version(v)
            if _satisfies_all_clauses(req, vt):
                matches.append((vt, v))
    else:
        # 1) Single comparator?
        cmp_req = _parse_comparator_req(req.strip())
        if cmp_req:
            op, rhs = cmp_req
            for v in versions:
                vt = _parse_version(v)
                if _satisfies_comparator(op, rhs, vt):
                    matches.append((vt, v))
        else:
            # 2) Single caret or bare (treated the same per Cargo)
            base = _parse_version(req.strip().removeprefix("^"))
            lo = base
            hi = _cargo_default_upper_bound(base)
            for v in versions:
                vt = _parse_version(v)
                if _cmp(vt, lo) >= 0 and _cmp(vt, hi) < 0:
                    matches.append((vt, v))

    if not matches:
        return None

    # Pick the highest version tuple.
    best = matches[0]
    for cand in matches[1:]:
        if _cmp(cand[0], best[0]) > 0:
            best = cand
    return best[1]