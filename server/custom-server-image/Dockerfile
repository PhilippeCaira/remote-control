# ============================================================================
# Custom rustdesk-server-s6 image with our branded admin UI.
#
# Layers our fork of lejianwen/rustdesk-api-web (branch
# remote-control-fork, which carries the "password-in-webclient-URL"
# patch for zero-click managed-fleet connect) on top of the official
# lejianwen/rustdesk-server-s6 image. No Go rebuild — we only replace
# the static Vue SPA under /app/resources/admin/.
#
# Pinning:
#   - LEJIANWEN_IMAGE_TAG: image tag of lejianwen/rustdesk-server-s6 to
#     base from. Update deliberately to pick up upstream fixes. When
#     that's bumped, also update FORK_REF if the fork has rebased.
#   - FORK_REF: branch or tag/sha of PhilippeCaira/rustdesk-api-web. The
#     remote-control-fork branch tracks upstream/master + our patch; if
#     upstream adds breaking changes we rebase the fork and bump here.
# ============================================================================

ARG LEJIANWEN_IMAGE_TAG=latest
ARG FORK_REPO=https://github.com/PhilippeCaira/rustdesk-api-web.git
ARG FORK_REF=remote-control-fork

# ─── Stage 1: build the Vue SPA with our patch ─────────────────────────────
FROM node:20-alpine AS admin-ui-builder
ARG FORK_REPO
ARG FORK_REF

RUN apk add --no-cache git

WORKDIR /build
RUN git clone --depth=1 --branch "${FORK_REF}" "${FORK_REPO}" . \
 && git log -1 --oneline > /build/.fork-ref
RUN npm ci --silent
RUN npm run build

# ─── Stage 2: copy our dist over the upstream admin folder ────────────────
FROM lejianwen/rustdesk-server-s6:${LEJIANWEN_IMAGE_TAG}

COPY --from=admin-ui-builder /build/dist /app/resources/admin
COPY --from=admin-ui-builder /build/.fork-ref /app/resources/admin/.fork-ref

# Everything else (hbbs, hbbr, rustdesk-api, s6) inherited unchanged.
