#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Renders locally exactly what Argo CD will apply, so changes can be reviewed
# (and diffed) before they are committed. Needs helm + oc on PATH; no cluster.
#
#   ./scripts/render.sh            # write to ./.render/
#   ./scripts/render.sh --stdout   # dump everything to stdout
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/.."

APP="gitops/applications/artifactory.yaml"
OUT_DIR=".render"
TO_STDOUT="false"
[[ "${1:-}" == "--stdout" ]] && TO_STDOUT="true"

# Keep chart version + sizing profile in lockstep with the Application.
CHART_VERSION="$(awk '/chart: artifactory/{found=1} found && /targetRevision:/{print $2; exit}' "$APP")"
SIZING_FILE="$(grep -oE '^[[:space:]]*- sizing/artifactory-[a-z0-9]+\.yaml' "$APP" | head -1 | awk '{print $2}')"
CHART_CACHE=".charts"

echo "==> chart jfrog/artifactory ${CHART_VERSION}, sizing ${SIZING_FILE}" >&2

if [[ ! -d "${CHART_CACHE}/artifactory" ]]; then
  mkdir -p "$CHART_CACHE"
  # --repo avoids touching the caller's `helm repo` configuration.
  helm pull artifactory \
    --repo https://charts.jfrog.io \
    --version "$CHART_VERSION" \
    --untar --untardir "$CHART_CACHE"
fi

render_helm() {
  helm template artifactory "${CHART_CACHE}/artifactory" \
    --namespace artifactory \
    --values "${CHART_CACHE}/artifactory/${SIZING_FILE}" \
    --values helm/values-openshift.yaml
}

if [[ "$TO_STDOUT" == "true" ]]; then
  oc kustomize manifests/platform
  render_helm
else
  mkdir -p "$OUT_DIR"
  oc kustomize manifests/platform > "${OUT_DIR}/platform.yaml"
  render_helm > "${OUT_DIR}/artifactory.yaml"
  echo "==> wrote ${OUT_DIR}/platform.yaml and ${OUT_DIR}/artifactory.yaml" >&2
fi
