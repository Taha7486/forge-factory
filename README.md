# forge-factory

The image factory of Forge: a GitHub Actions workflow that builds a container image and pushes it to a private Amazon ECR repository. The cluster side (EKS, ECR, IAM) is defined in the `forge-infra` repository.

## Current state

Build and push only. Not yet run against a real AWS account.

- The image is a thin layer on top of a pinned upstream podinfo release (`FROM` by tag and digest). A build argument records the git commit in an image label, so every commit produces its own image.
- The image is tagged with the git commit SHA and pushed to `forge/podinfo` in ECR. ECR tags are immutable, so a commit that already has an image is skipped, never rebuilt.
- GitHub Actions authenticates to AWS through OIDC and assumes a role. No AWS key is stored anywhere. The role is trusted for this repository's `main` branch only, so pull requests and other branches cannot push.

A second workflow, `sign-attest.yml`, signs an image that is already in ECR and attaches a CycloneDX SBOM and a vulnerability scan as signed attestations (keyless, through GitHub's OIDC token). Between the scan and the signing it runs a vulnerability gate (`gate/`, below): CRITICAL and HIGH findings block the image unless an unexpired waiver covers them. The workflow is written but has never run: it needs the AWS account and a pushed image first. The gate itself is tested locally (30 tests, and a run on a real Trivy report).

Planned, not built: scan and SBOM inside the build workflow (the signing workflow does them today), admission checks of the signatures on the cluster (Kyverno policies live in the `forge-gitops` repository).

## Juice Shop (adversarial workload)

OWASP Juice Shop is rebuilt here from source, never mirrored, so the image that gets signed is one this pipeline made. Everything is in `juice-shop/`:

- `source.env`: the upstream repository, the pinned COMMIT (`f189f521`, tag v20.3.0; a tag can be moved, a commit cannot) and the two base images by digest. `build.sh` fetches exactly that commit and stops if the checkout differs.
- `Dockerfile`: upstream's own build steps made explicit, with pinned bases, `npm ci --ignore-scripts` from committed lockfiles, `sqlite3` compiled from source (the only install script that runs; no prebuilt binary is downloaded), the Angular and TypeScript builds as plain commands, and the same runtime layout as upstream (distroless, uid 65532, port 3000).
- `locks/`: the two lockfiles, and an `.npmrc` that only `update-locks.sh` uses. Upstream commits no lockfile (its `.npmrc` says `package-lock=false`), so every upstream build resolves dependency versions at build time. `update-locks.sh` generates ours inside the pinned node image (no package is installed, no script runs); review `git diff juice-shop/locks` in the pull request. `check-locks.py` refuses any entry that does not resolve to `registry.npmjs.org` with a sha512 integrity hash; `tests/run_tests.sh` tests it, and `tests/build_sh_tests.sh` tests `build.sh` with stand-ins for git and docker.
- `build.sh IMAGE [FACTORY_SHA]`: the one script CI and a laptop both use. It does not push.

Tested locally on 2026-10-17 with the same `build.sh` (classic Docker builder, 4 cores, spinning disk: about 18 minutes once the base images are cached, mostly disk I/O): the image is 555 MB uncompressed and holds none of the build-only material (no TypeScript, Cypress, `.git`, Dockerfile or `.npmrc`). It ran with no network, all capabilities dropped and `no-new-privileges`, answered 200 on the main page, the frontend bundle, `/ftp` and the REST API, read 46 products from SQLite (so the `sqlite3` binding, compiled from source, works) and used about 120 MB. Trivy 0.74.0 on it and on upstream's published image gave the same result: 11 CRITICAL, 27 HIGH, 49 MEDIUM, 11 LOW, and the same 35 distinct CRITICAL/HIGH (CVE, package) pairs (the waiver scale); the 586 npm package names are identical and 14 differ by a patch version, because upstream resolved its dependencies at its build time and our lockfiles five days later. Not tested: the workflows themselves (they need GitHub Actions and AWS), the push to ECR, signing, and the gate on this image.

Two things that surprised the first attempts: `npm prune --omit=dev` hung for 24 minutes in the build container (no CPU, no sockets), which is why the production dependencies get their own stage; and upstream's `.dockerignore` drops `.npmrc` from the build context, so install scripts are switched off with `NPM_CONFIG_IGNORE_SCRIPTS` in the Dockerfile instead (the node image's npm 11.19 also blocks install scripts that are not on its `allow-scripts` list, and wants the `sqlite3` approval in a project `.npmrc`).

`.github/workflows/build-juice-shop.yml` runs the lockfile checks, builds with `build.sh` and pushes `forge/juice-shop:<commit sha>` (immutable tags, skipped if the tag exists). It does not sign. `sign-attest.yml` takes an input `repository` (forge/podinfo or forge/juice-shop). Its vulnerability gate will refuse the Juice Shop image until `gate/waivers.json` covers the CRITICAL and HIGH findings: that is intended (the waiver demo), and the waivers are a separate step.

## Layout

- `Dockerfile`: the thin podinfo image.
- `juice-shop/`: the Juice Shop build (above).
- `.github/workflows/build-juice-shop.yml`: builds and pushes `forge/juice-shop`, on pushes to `main` that change `juice-shop/` and on manual dispatch.
- `.github/workflows/build-push.yml`: the build workflow. It runs on pushes to `main` that change the Dockerfile or the workflow, and on manual dispatch.
- `.github/workflows/sign-attest.yml`: the signing workflow, for forge/podinfo or forge/juice-shop (input `repository`). Manual dispatch only, and only from `main`: the cluster's admission policies accept exactly this file name on that branch as the signer, so do not rename it.
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
