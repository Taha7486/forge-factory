# forge-factory

The image factory of Forge: a GitHub Actions workflow that builds a container image and pushes it to a private Amazon ECR repository. The cluster side (EKS, ECR, IAM) is defined in the `forge-infra` repository.

## Current state

Build and push only. Not yet run against a real AWS account.

- The image is a thin layer on top of a pinned upstream podinfo release (`FROM` by tag and digest). A build argument records the git commit in an image label, so every commit produces its own image.
- The image is tagged with the git commit SHA and pushed to `forge/podinfo` in ECR. ECR tags are immutable, so a commit that already has an image is skipped, never rebuilt.
- GitHub Actions authenticates to AWS through OIDC and assumes a role. No AWS key is stored anywhere. The role is trusted for this repository's `main` branch only, so pull requests and other branches cannot push.

A second workflow, `sign-attest.yml`, signs an image that is already in ECR and attaches a CycloneDX SBOM and a vulnerability scan as signed attestations (keyless, through GitHub's OIDC token). It is written but has never run: it needs the AWS account and a pushed image first.

Planned, not built: scan and SBOM inside the build workflow, admission checks of the signatures on the cluster (Kyverno policies live in the `forge-gitops` repository).

## Layout

- `Dockerfile`: the thin image.
- `.github/workflows/build-push.yml`: the build workflow. It runs on pushes to `main` that change the Dockerfile or the workflow, and on manual dispatch.
- `.github/workflows/sign-attest.yml`: the signing workflow. Manual dispatch only, and only from `main`: the cluster's admission policies accept exactly this file name on that branch as the signer, so do not rename it.
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
5. Sign the digest, then attach the SBOM and the scan as signed attestations. Inputs `sign` and `sbom` can switch the signature or the SBOM off for tests.
6. Write the digest, the component count and the vulnerability counts to the job summary.

## Setup

The workflow reads the role from a repository variable named `AWS_ROLE_ARN` (Settings, Secrets and variables, Actions, Variables). Until the variable exists, the job is skipped.
