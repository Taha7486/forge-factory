#!/usr/bin/env python3
"""Checks npm lockfiles (lockfileVersion 2 or 3) before they are used for a build.

Why: upstream Juice Shop commits no lockfile, so Forge commits its own. A lockfile is only
worth something if every package in it comes from the npm registry and carries an integrity
hash, so `npm ci` can detect a swapped tarball. Standard library only; run with python3 -I.

Rules, for every package entry except the root and workspace links:
  - "resolved" must be an https://registry.npmjs.org/ URL (no git, http, file or other host);
  - "integrity" must exist and use sha512 (sha1 only is refused: it is the only hash some very
    old packages have, and a collision-weak hash is not worth trusting).
Bundled dependencies (inBundle) have no URL of their own and are skipped, but counted.

Exit codes: 0 all packages pass, 1 at least one package breaks a rule, 2 unreadable input.
"""
import json
import sys

REGISTRY = "https://registry.npmjs.org/"


def check(path):
    try:
        with open(path, encoding="utf-8") as f:
            lock = json.load(f)
    except (OSError, ValueError) as e:
        print(f"{path}: cannot read: {e}", file=sys.stderr)
        return 2, []
    if not isinstance(lock, dict) or lock.get("lockfileVersion") not in (2, 3):
        print(f"{path}: lockfileVersion must be 2 or 3, got {lock.get('lockfileVersion') if isinstance(lock, dict) else lock!r}", file=sys.stderr)
        return 2, []
    pkgs = lock.get("packages")
    if not isinstance(pkgs, dict) or len(pkgs) < 2:
        print(f"{path}: no \"packages\" section with entries", file=sys.stderr)
        return 2, []
    problems = []
    checked = bundled = 0
    for key, p in pkgs.items():
        if key == "":
            continue
        if not isinstance(p, dict):
            problems.append((key, "entry is not an object"))
            continue
        if p.get("link"):
            continue
        if p.get("inBundle"):
            bundled += 1
            continue
        checked += 1
        url = p.get("resolved")
        if not isinstance(url, str) or not url.startswith(REGISTRY):
            problems.append((key, f"resolved is not {REGISTRY}...: {url!r}"))
        integ = p.get("integrity")
        if not isinstance(integ, str) or not integ.startswith("sha512-"):
            problems.append((key, f"integrity is not sha512: {integ!r}"))
    print(f"{path}: {checked} packages checked, {bundled} bundled skipped, {len(problems)} problems")
    return (1 if problems else 0), problems


def main(argv):
    if not argv:
        print("usage: check-locks.py LOCKFILE...", file=sys.stderr)
        return 2
    worst = 0
    for path in argv:
        rc, problems = check(path)
        for key, why in problems[:20]:
            print(f"  {key}: {why}")
        if len(problems) > 20:
            print(f"  ... and {len(problems) - 20} more")
        worst = max(worst, rc)
    return worst


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
