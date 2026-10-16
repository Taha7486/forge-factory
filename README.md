# forge-factory

The image factory of Forge: a GitHub Actions workflow that builds a container image and pushes it to a private Amazon ECR repository. The cluster side (EKS, ECR, IAM) is defined in the `forge-infra` repository.

## Current state

Build and push only. Not yet run against a real AWS account.

- The image is a thin layer on top of a pinned upstream podinfo release (`FROM` by tag and digest). A build argument records the git commit in an image label, so every commit produces its own image.
- The image is tagged with the git commit SHA and pushed to `forge/podinfo` in ECR. ECR tags are immutable, so a commit that already has an image is skipped, never rebuilt.
- GitHub Actions authenticates to AWS through OIDC and assumes a role. No AWS key is stored anywhere. The role is trusted for this repository's `main` branch only, so pull requests and other branches cannot push.

A second workflow, `sign-attest.yml`, signs an image that is already in ECR and attaches a CycloneDX SBOM and a vulnerability scan as signed attestations (keyless, through GitHub's OIDC token). Between the scan and the signing it runs a vulnerability gate (`gate/`, below): CRITICAL and HIGH findings block the image unless an unexpired waiver covers them. The workflow is written but has never run: it needs the AWS account and a pushed image first. The gate itself is tested locally (30 tests, and a run on a real Trivy report).

Planned, not built: scan and SBOM inside the build workflow (the signing workflow does them today), admission checks of the signatures on the cluster (Kyverno policies live in the `forge-gitops` repository).

## Layout

- `Dockerfile`: the thin image.
- `.github/workflows/build-push.yml`: the build workflow. It runs on pushes to `main` that change the Dockerfile or the workflow, and on manual dispatch.
- `.github/workflows/sign-attest.yml`: the signing workflow. Manual dispatch only, and only from `main`: the cluster's admission policies accept exactly this file name on that branch as the signer, so do not rename it.
- `gate/`: the vulnerability gate. `vuln_gate.py` is the gate (Python standard library only), `waivers.json` the waiver list (empty), `tests/` the fixtures and `run_tests.sh`.
- `signing-config/rekor-v1-only.json`: pins signing to one transparency log (Rekor v1), as decided in the R1 spike.

## Workflow steps

1. Check out the repository.
2. Assume the AWS role through OIDC.
3. Log in to ECR.
4. Look for an image tagged with the commit SHA. If one exists, report its digest and stop.
5. Build the image and push it.
6. Write the image digest to the job summary.

Third-party actions are pinned to commit SHAs.

## Signing workflow steps

1. Check out the repository and install cosign v3.1.3, Syft v1.51.1 and Trivy v0.74.0 (the last two checked against pinned SHA-256 sums).
2. Assume the AWS role through OIDC and log in to ECR.
3. Find the digest of the image tagged with the chosen tag (default: this commit's SHA). Stop with an error if there is none.
4. Make the SBOM (Syft) and the vulnerability scan (Trivy, cosign format), both on the digest.
5. Run the vulnerability gate on the scan. If it fails, the job stops here: the image is not signed and not attested, so the cluster's admission policies refuse it too.
6. Sign the digest, then attach the SBOM and the scan as signed attestations. Inputs `sign` and `sbom` can switch the signature or the SBOM off for tests.
7. Write the digest, the component count and the vulnerability counts to the job summary.

## Vulnerability gate and waivers

`gate/vuln_gate.py` reads the same `vuln.json` that gets attested, so the attestation shows every finding, waived or not. It fails the job on any CRITICAL or HIGH finding (fixed or not) that has no valid waiver. Waivers live in `gate/waivers.json`:

```json
{
  "waivers": [
    {
      "id": "CVE-2026-12345",
      "package": "zlib",
      "justification": "Why this is acceptable here, at least 20 characters.",
      "owner": "taha",
      "created": "2026-10-16",
      "expires": "2026-11-16"
    }
  ]
}
```

Rules:
- A waiver covers one CVE in one package. All six fields are required, and an unknown field is an error.
- It works from `created` up to, but not including, `expires` (UTC), and `expires` is at most 90 days after `created`. A waiver cannot be created in the future.
- The gate fails closed: a bad waiver file, a duplicate waiver or a scan file that is not a Trivy report stops the run (exit 2). Blocked findings exit 1.
- Warnings, not failures: a waiver that matches no finding (remove it), and a waiver that expires within 14 days. Both appear in the job summary, which also lists every waived finding with its owner and justification.
- There is no date override in the workflow. `--today YYYY-MM-DD` exists for local tests and demos, and the script refuses it when `GITHUB_ACTIONS=true`.

Spec demo 4 (the waiver lifecycle), locally, with a Trivy report in the cosign-vuln format (`trivy image --format cosign-vuln --output vuln.json IMAGE`): run `python3 gate/vuln_gate.py --vuln vuln.json --waivers gate/waivers.json` (blocked), add a waiver (passes), then repeat with `--today` set to the expiry date (blocked again, "waiver expired").

Tests: `gate/tests/run_tests.sh` (30 cases, made-up `CVE-2099-*` ids, the date pinned). Checked 2026-10-16 by breaking the script on purpose: four of five deliberate breaks were caught, the fifth changed nothing.

Not enforced by this repo: that waivers change only through a pull request. The `protect-main` ruleset blocks deleting `main` and force pushes, but still allows a direct push, which could add a waiver. Requiring a pull request is a repository setting.

## Setup

The workflow reads the role from a repository variable named `AWS_ROLE_ARN` (Settings, Secrets and variables, Actions, Variables). Until the variable exists, the job is skipped.
