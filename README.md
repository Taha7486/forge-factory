# forge-factory

The image factory of Forge: a GitHub Actions workflow that builds a container image and pushes it to a private Amazon ECR repository. The cluster side (EKS, ECR, IAM) is defined in the `forge-infra` repository.

## Current state

Build and push only. Not yet run against a real AWS account.

- The image is a thin layer on top of a pinned upstream podinfo release (`FROM` by tag and digest). A build argument records the git commit in an image label, so every commit produces its own image.
- The image is tagged with the git commit SHA and pushed to `forge/podinfo` in ECR. ECR tags are immutable, so a commit that already has an image is skipped, never rebuilt.
- GitHub Actions authenticates to AWS through OIDC and assumes a role. No AWS key is stored anywhere. The role is trusted for this repository's `main` branch only, so pull requests and other branches cannot push.

Planned, not built: vulnerability scan, SBOM, keyless signing and attestations.

## Layout

- `Dockerfile`: the thin image.
- `.github/workflows/build-push.yml`: the workflow. It runs on pushes to `main` that change the Dockerfile or the workflow, and on manual dispatch.

## Workflow steps

1. Check out the repository.
2. Assume the AWS role through OIDC.
3. Log in to ECR.
4. Look for an image tagged with the commit SHA. If one exists, report its digest and stop.
5. Build the image and push it.
6. Write the image digest to the job summary.

Third-party actions are pinned to commit SHAs.

## Setup

The workflow reads the role from a repository variable named `AWS_ROLE_ARN` (Settings, Secrets and variables, Actions, Variables). Until the variable exists, the job is skipped.
