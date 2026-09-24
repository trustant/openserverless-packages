#!/bin/bash
# Publish the built .deb to the openserverless S3 bucket and record it in the
# GitHub release notes for this version.
set -euo pipefail
cd "$(dirname $0)"

echo "=== PUBLISH ==="

# S3 credentials come from the environment (CI secrets); refuse to run without
# a complete set rather than failing halfway through the upload.
missing=()
for v in S3_ENDPOINT S3_REGION S3_KEY S3_SECRET; do
    if [ -z "${!v:-}" ]; then missing+=("$v"); fi
done
if [ "${#missing[@]}" -ne 0 ]; then
    echo "Missing required environment variable(s): ${missing[*]}" >&2
    exit 1
fi

BUCKET="openserverless"
PUBLIC_URL="https://openserverless.nuvolaris.download"
DISTDIR="$(cd .. && pwd)/dist"

# package.sh wrote the version alongside the .deb.
VERSION_FILE="${DISTDIR}/version.txt"
if [ ! -f "${VERSION_FILE}" ]; then
    echo "Missing ${VERSION_FILE}: run ./package.sh first" >&2
    exit 1
fi
VERSION="$(cat "${VERSION_FILE}")"
ARCH="$(dpkg --print-architecture)"
DEBNAME="openserverless_${VERSION}_${ARCH}.deb"
DEB="${DISTDIR}/${DEBNAME}"

if [ ! -f "${DEB}" ]; then
    echo "Missing ${DEB}" >&2
    ls -l "${DISTDIR}" >&2
    exit 1
fi

echo "Publishing ${DEBNAME} (version ${VERSION}, arch ${ARCH})"

export AWS_ACCESS_KEY_ID="${S3_KEY}"
export AWS_SECRET_ACCESS_KEY="${S3_SECRET}"
export AWS_DEFAULT_REGION="${S3_REGION}"

aws --endpoint-url "${S3_ENDPOINT}" \
    s3 cp "${DEB}" "s3://${BUCKET}/${DEBNAME}" \
    --acl public-read \
    --content-type application/vnd.debian.binary-package

DEB_URL="${PUBLIC_URL}/${DEBNAME}"
echo "Uploaded: ${DEB_URL}"

# --- release notes -------------------------------------------------------
# Each architecture is built by a separate job publishing to the SAME release
# tag, so the notes must be updated additively: read what is already there,
# drop only our own architecture's line (in case of a re-run), and re-append.
# Without GH_TOKEN (local runs) the upload is done and we stop here.
if [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "No GH_TOKEN/GITHUB_TOKEN set; skipping release notes update."
    exit 0
fi

TAG="v${VERSION}"
LINE="- [\`${DEBNAME}\`](${DEB_URL}) (${ARCH})"

if ! gh release view "${TAG}" >/dev/null 2>&1; then
    gh release create "${TAG}" \
        --title "openserverless ${VERSION}" \
        --notes "## Downloads"
fi

# Retry: two arch jobs can read-modify-write the notes concurrently, and the
# loser of a race would otherwise silently drop the other's link.
for attempt in 1 2 3 4 5; do
    NOTES="$(gh release view "${TAG}" --json body -q .body)"
    case "${NOTES}" in
        *"## Downloads"*) ;;
        *) NOTES="${NOTES}${NOTES:+$'\n\n'}## Downloads" ;;
    esac

    # Keep every line from the other builds; replace only ours.
    NEW_NOTES="$(printf '%s\n' "${NOTES}" | grep -vF "(${ARCH})" || true)"
    NEW_NOTES="${NEW_NOTES}"$'\n'"${LINE}"

    if gh release edit "${TAG}" --notes "${NEW_NOTES}"; then
        # Confirm our line survived; if a concurrent job overwrote it, retry.
        CHECK="$(gh release view "${TAG}" --json body -q .body)"
        if printf '%s\n' "${CHECK}" | grep -qF "${DEB_URL}"; then
            echo "Release ${TAG} notes updated."
            exit 0
        fi
    fi
    echo "Release notes update raced (attempt ${attempt}); retrying..." >&2
    sleep $(( attempt * 3 ))
done

echo "Failed to update release notes for ${TAG}" >&2
exit 1
