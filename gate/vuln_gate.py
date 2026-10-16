#!/usr/bin/env python3
"""Vulnerability gate with expiring waivers.

Reads the Trivy scan in cosign-vuln format (the same vuln.json that gets attested) and the
waiver file. Fails if a CRITICAL or HIGH finding has no valid waiver.

A waiver names one CVE in one package. It needs a justification, an owner, a creation date
and an expiry date at most 90 days later. It works from its `created` date up to, but not
including, its `expires` date (UTC). A waiver that is missing a field, has a field we do
not know, or breaks a rule makes the whole run fail: the gate fails closed.

Exit codes: 0 passed, 1 blocked by findings, 2 bad input (waiver file, scan file, usage).
Python standard library only, so there is nothing to install or pin on the runner.
"""
import argparse
import datetime
import json
import os
import re
import sys

GATE_SEVERITIES = ("CRITICAL", "HIGH")
MAX_WAIVER_DAYS = 90
WARN_DAYS = 14
MIN_JUSTIFICATION = 20
FIELDS = {"id", "package", "justification", "owner", "created", "expires"}
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


class InputError(Exception):
    """The waiver file or the scan file cannot be trusted."""


def parse_date(value, where, errors):
    if not isinstance(value, str) or not DATE_RE.match(value):
        errors.append(f"{where}: not a date in YYYY-MM-DD form: {value!r}")
        return None
    try:
        return datetime.date.fromisoformat(value)
    except ValueError:
        errors.append(f"{where}: not a real date: {value!r}")
        return None


def load_waivers(path, today):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise InputError(f"cannot read waiver file {path}: {e}")
    if not isinstance(data, dict) or set(data) != {"waivers"} or not isinstance(data["waivers"], list):
        raise InputError(f'{path}: must be an object with exactly one key, "waivers", holding a list')

    errors, waivers, seen = [], [], set()
    for i, w in enumerate(data["waivers"], 1):
        where = f"waiver {i}"
        if not isinstance(w, dict):
            errors.append(f"{where}: not an object")
            continue
        if isinstance(w.get("id"), str) and isinstance(w.get("package"), str):
            where = f"waiver {i} ({w['id']} in {w['package']})"
        missing, extra = FIELDS - set(w), set(w) - FIELDS
        if missing:
            errors.append(f"{where}: missing {', '.join(sorted(missing))}")
        if extra:
            errors.append(f"{where}: unknown field {', '.join(sorted(extra))}")
        if missing or extra:
            continue
        for field in ("id", "package", "owner", "justification"):
            if not isinstance(w[field], str) or not w[field].strip():
                errors.append(f"{where}: {field} is empty")
        if isinstance(w["justification"], str) and 0 < len(w["justification"].strip()) < MIN_JUSTIFICATION:
            errors.append(f"{where}: justification is shorter than {MIN_JUSTIFICATION} characters")
        created = parse_date(w["created"], f"{where}: created", errors)
        expires = parse_date(w["expires"], f"{where}: expires", errors)
        if created and expires:
            if expires <= created:
                errors.append(f"{where}: expires must be after created")
            elif (expires - created).days > MAX_WAIVER_DAYS:
                errors.append(f"{where}: lasts {(expires - created).days} days, the limit is {MAX_WAIVER_DAYS} days")
            if created > today:
                errors.append(f"{where}: created {created} is in the future")
        key = (w["id"], w["package"])
        if key in seen:
            errors.append(f"{where}: duplicate of an earlier waiver")
        seen.add(key)
        if created and expires:
            waivers.append({**w, "created": created, "expires": expires})
    if errors:
        raise InputError("invalid waiver file " + path + ":\n  " + "\n  ".join(errors))
    return waivers


def load_findings(path):
    """Return the unique CRITICAL/HIGH findings of a cosign-vuln report."""
    try:
        with open(path, encoding="utf-8") as f:
            report = json.load(f)
        result = report["scanner"]["result"]
        if not isinstance(result, dict) or "SchemaVersion" not in result:
            raise KeyError("scanner.result.SchemaVersion")
        results = result.get("Results") or []
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise InputError(f"{path} is not a Trivy cosign-vuln report ({e!r})")
    found = {}
    for target in results:
        for v in target.get("Vulnerabilities") or []:
            if v.get("Severity") in GATE_SEVERITIES:
                key = (v["VulnerabilityID"], v["PkgName"], v.get("InstalledVersion", ""))
                found.setdefault(key, v)
    order = {s: n for n, s in enumerate(GATE_SEVERITIES)}
    return sorted(found.values(), key=lambda v: (order[v["Severity"]], v["VulnerabilityID"], v["PkgName"]))


def evaluate(findings, waivers, today):
    by_key = {(w["id"], w["package"]): w for w in waivers}
    blocked, waived, used = [], [], set()
    for v in findings:
        key = (v["VulnerabilityID"], v["PkgName"])
        w = by_key.get(key)
        if w is None:
            blocked.append((v, "no waiver"))
            continue
        used.add(key)
        if today >= w["expires"]:
            blocked.append((v, f"waiver expired on {w['expires']} (owner {w['owner']})"))
        else:
            waived.append((v, w))
    warnings = []
    for w in waivers:
        key = (w["id"], w["package"])
        left = (w["expires"] - today).days
        if key not in used:
            warnings.append(f"waiver {w['id']} in {w['package']} matches no CRITICAL/HIGH finding: remove it")
        elif 0 < left <= WARN_DAYS:
            warnings.append(f"waiver {w['id']} in {w['package']} expires in {left} days, on {w['expires']} (owner {w['owner']})")
    return blocked, waived, warnings


def describe(v):
    fixed = v.get("FixedVersion") or "no fix yet"
    return f"{v['Severity']} {v['VulnerabilityID']} {v['PkgName']} {v.get('InstalledVersion', '')} (fixed in: {fixed})"


def report_text(today, blocked, waived, warnings):
    out = [f"Vulnerability gate ({', '.join(GATE_SEVERITIES)}), as of {today}"]
    out.append(f"BLOCKED ({len(blocked)}):")
    out += [f"  {describe(v)}: {why}" for v, why in blocked] or ["  none"]
    out.append(f"WAIVED ({len(waived)}):")
    out += [f"  {describe(v)}: owner {w['owner']}, expires {w['expires']}: {w['justification']}" for v, w in waived] or ["  none"]
    if warnings:
        out.append("WARNINGS:")
        out += [f"  {w}" for w in warnings]
    out.append("RESULT: " + ("FAILED" if blocked else "PASSED"))
    return "\n".join(out)


def report_markdown(today, blocked, waived, warnings):
    md = [f"## Vulnerability gate: {'FAILED' if blocked else 'passed'}",
          f"Severities {', '.join(GATE_SEVERITIES)}, as of {today}. Blocked: {len(blocked)}. Waived: {len(waived)}.", ""]
    if blocked:
        md += ["### Blocked", "| Finding | Package | Reason |", "|---|---|---|"]
        md += [f"| {v['Severity']} {v['VulnerabilityID']} | {v['PkgName']} {v.get('InstalledVersion', '')} | {why} |" for v, why in blocked]
        md.append("")
    if waived:
        md += ["### Waived", "| Finding | Package | Owner | Expires | Justification |", "|---|---|---|---|---|"]
        md += [f"| {v['Severity']} {v['VulnerabilityID']} | {v['PkgName']} {v.get('InstalledVersion', '')} | {w['owner']} | {w['expires']} | {w['justification']} |" for v, w in waived]
        md.append("")
    if warnings:
        md += ["### Warnings"] + [f"- {w}" for w in warnings] + [""]
    return "\n".join(md) + "\n"


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--vuln", required=True, help="Trivy cosign-vuln report (vuln.json)")
    p.add_argument("--waivers", required=True, help="waiver file (waivers.json)")
    p.add_argument("--summary", help="append a Markdown report to this file (GITHUB_STEP_SUMMARY)")
    p.add_argument("--today", help="pretend today is this date (YYYY-MM-DD); local tests and demos only")
    args = p.parse_args()

    try:
        if args.today and os.environ.get("GITHUB_ACTIONS") == "true":
            raise InputError("--today is for local tests and demos only; it is refused in GitHub Actions")
        errors = []
        today = parse_date(args.today, "--today", errors) if args.today else datetime.datetime.now(datetime.timezone.utc).date()
        if errors:
            raise InputError(errors[0])
        waivers = load_waivers(args.waivers, today)
        findings = load_findings(args.vuln)
    except InputError as e:
        print(f"Vulnerability gate: BAD INPUT: {e}", file=sys.stderr)
        return 2

    blocked, waived, warnings = evaluate(findings, waivers, today)
    print(report_text(today, blocked, waived, warnings))
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as f:
            f.write(report_markdown(today, blocked, waived, warnings))
    if blocked and os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::error::Vulnerability gate blocked {len(blocked)} finding(s); see the job summary")
    return 1 if blocked else 0


if __name__ == "__main__":
    sys.exit(main())
