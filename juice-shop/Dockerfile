# OWASP Juice Shop, rebuilt by Forge from the pinned upstream source. It follows upstream's own
# Dockerfile (same build steps, same runtime layout) with these differences, all on purpose:
#   - both base images are pinned by digest (upstream leaves them floating);
#   - dependencies come from lockfiles committed in this repo (upstream commits none), installed
#     with install scripts switched off (NPM_CONFIG_IGNORE_SCRIPTS), so no dependency runs one by itself;
#   - the one native module (sqlite3) is compiled from source, explicitly, against the node
#     headers of the base image: no prebuilt binary is downloaded;
#   - the Angular and TypeScript builds are explicit commands instead of upstream's postinstall hook,
#     and the production dependencies get their own stage instead of `npm prune`;
#   - no `npm run sbom` step: the signing workflow makes the SBOM with Syft.
# Build it with build.sh, which prepares the source directory (this file is copied into it).
ARG NODE_IMAGE
ARG RUNTIME_IMAGE

# Stage 1: build with the full dependency tree (TypeScript and Angular are dev dependencies).
FROM ${NODE_IMAGE} AS builder
# NPM_CONFIG_IGNORE_SCRIPTS: upstream's .dockerignore drops .npmrc from the build context, so the
# setting is made here. (npm 11.19 also blocks install scripts that are not on its allow-scripts
# list; this makes the rule explicit instead of relying on that default.)
ENV NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_IGNORE_SCRIPTS=true \
    NODE_OPTIONS=--max-old-space-size=4096
WORKDIR /juice-shop
COPY . /juice-shop

# The overlay (the two lockfiles) was copied in by build.sh.
RUN npm ci
RUN cd frontend && npm ci

# Frontend: upstream's `npm run build` also runs `npm run sbom`, which is not needed here.
RUN cd frontend && ./node_modules/.bin/ng build --configuration production
# Server: upstream tolerates tsc errors as long as it emits; so do we, but app.js must exist.
RUN (npm run --silent build:server || true) && test -f build/app.js

# Drop the build-only trees. (Upstream runs `npm prune`; it hung for 24 minutes in a test build here,
# so the production dependencies are installed fresh in the next stage instead.)
RUN rm -rf node_modules frontend/node_modules frontend/.angular frontend/src/assets
RUN mkdir logs \
 && chown -R 65532 logs \
 && chgrp -R 0 ftp/ frontend/dist/ logs/ data/ i18n/ \
 && chmod -R g=u ftp/ frontend/dist/ logs/ data/ i18n/ \
 && (rm -f ftp/legal.md; rm -f i18n/*.json)

# Stage 2: production dependencies only, from the same lockfile.
FROM ${NODE_IMAGE} AS deps
ENV NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_IGNORE_SCRIPTS=true
WORKDIR /juice-shop
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
# The only install script that runs: sqlite3, built from source (no prebuilt binary download).
# npm 11.19 wants the approval in .npmrc (not on the command line); prebuild-install and node-gyp
# read build-from-source and the node headers directory from the environment.
RUN echo 'allow-scripts[]=sqlite3@5.1.7' > .npmrc \
 && npm_config_build_from_source=true npm_config_nodedir=/usr/local npm rebuild sqlite3 --ignore-scripts=false \
 && rm .npmrc
# Fail here, not at runtime, if the native binding was not built.
RUN test -f node_modules/sqlite3/build/Release/node_sqlite3.node

# Stage 3: runtime, distroless, same layout as upstream.
FROM ${RUNTIME_IMAGE}
ARG UPSTREAM_COMMIT
ARG UPSTREAM_TAG
ARG FACTORY_SHA=unknown
LABEL org.opencontainers.image.title="OWASP Juice Shop (rebuilt by Forge)" \
      org.opencontainers.image.description="Deliberately vulnerable web application, rebuilt from source by the Forge pipeline" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.url="https://owasp-juice.shop" \
      org.opencontainers.image.source="https://github.com/juice-shop/juice-shop" \
      org.opencontainers.image.version="${UPSTREAM_TAG}" \
      org.opencontainers.image.revision="${FACTORY_SHA}" \
      dev.forge.upstream.commit="${UPSTREAM_COMMIT}"
WORKDIR /juice-shop
COPY --from=builder --chown=65532:0 /juice-shop .
COPY --from=deps --chown=65532:0 /juice-shop/node_modules ./node_modules
USER 65532
EXPOSE 3000
CMD ["/juice-shop/build/app.js"]
