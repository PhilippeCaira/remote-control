# custom-server-image

Thin layer over `lejianwen/rustdesk-server-s6` that overrides the admin
UI's Vue SPA with our fork of `lejianwen/rustdesk-api-web`. The fork
lives on branch
[`remote-control-fork`](https://github.com/PhilippeCaira/rustdesk-api-web/tree/remote-control-fork),
which tracks `upstream/master` + our single patch in
`src/utils/webclient.js` (embed the address-book row's `password` into
the `/webclient2/#/<id>?password=<pw>` URL so clicking "Web Client" no
longer prompts).

## Build locally

```bash
docker build -t ghcr.io/philippecaira/rustdesk-server-fleet:dev \
  server/custom-server-image/
```

Pin a specific base-image tag or fork ref with build args:

```bash
docker build \
  --build-arg LEJIANWEN_IMAGE_TAG=sha-abc123 \
  --build-arg FORK_REF=<sha> \
  -t ghcr.io/philippecaira/rustdesk-server-fleet:custom .
```

## Published image

`.github/workflows/build-admin-image.yml` rebuilds weekly (and on any
push that touches `server/custom-server-image/**`), tagging
`ghcr.io/philippecaira/rustdesk-server-fleet:latest` plus the commit
SHA. `server/docker-compose.yml` pulls from there.

## Upstream sync

Keep `master` of the fork in sync with `lejianwen/rustdesk-api-web`:

```bash
cd /path/to/rustdesk-api-web
git fetch upstream
git checkout master
git merge --ff-only upstream/master
git push origin master

# Rebase our patch on top of the new master
git checkout remote-control-fork
git rebase master
git push origin remote-control-fork --force-with-lease
```

Then bump `LEJIANWEN_IMAGE_TAG` in `docker-compose.yml` if the base
image also moved, and re-run the `build-admin-image` workflow (or wait
for the weekly schedule).
