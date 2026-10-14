#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Creates the secrets that the Artifactory Helm release expects to find
# already present in the target namespace. Run this ONCE, before the first
# Argo CD sync.
#
# These values are deliberately NOT in git. For a fully declarative setup,
# render them into External Secrets Operator or Sealed Secrets instead - see
# examples/externalsecret-artifactory.yaml and the README.
#
# Secrets created:
#   artifactory-cluster-keys   master-key, join-key      (REQUIRED)
#   artifactory-postgresql     postgres-password, password (REQUIRED)
#   artifactory-admin-creds    bootstrap.creds           (--with-admin)
#
# The script is idempotent: an existing secret is left untouched. That matters
# - rotating master-key after the first start makes every encrypted value in
# the database (and therefore the instance) unrecoverable.
#
# Usage:
#   ./scripts/create-secrets.sh [-n NAMESPACE] [--with-admin] [--dry-run]
# ---------------------------------------------------------------------------
set -euo pipefail

NAMESPACE="artifactory"
WITH_ADMIN="false"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    --with-admin)   WITH_ADMIN="true"; shift ;;
    --dry-run)      DRY_RUN="true"; shift ;;
    -h|--help)      sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v oc >/dev/null || { echo "oc not found in PATH" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster (oc login ...)" >&2; exit 1; }

OC_ARGS=(--namespace "$NAMESPACE")
if [[ "$DRY_RUN" == "true" ]]; then
  OC_ARGS+=(--dry-run=client -o yaml)
else
  if ! oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "==> creating namespace $NAMESPACE (Argo CD will adopt it)"
    oc create namespace "$NAMESPACE"
  fi
fi

secret_exists() {
  [[ "$DRY_RUN" == "true" ]] && return 1
  oc get secret "$1" --namespace "$NAMESPACE" >/dev/null 2>&1
}

# --- cluster keys ----------------------------------------------------------
if secret_exists artifactory-cluster-keys; then
  echo "==> artifactory-cluster-keys already exists - leaving it alone"
else
  echo "==> creating artifactory-cluster-keys"
  oc create secret generic artifactory-cluster-keys \
    "${OC_ARGS[@]}" \
    --from-literal=master-key="$(openssl rand -hex 32)" \
    --from-literal=join-key="$(openssl rand -hex 32)"
fi

# --- bundled PostgreSQL credentials ---------------------------------------
# Secret name must stay in sync with the Helm release name: the Artifactory
# containers read <release>-postgresql / key `password`.
if secret_exists artifactory-postgresql; then
  echo "==> artifactory-postgresql already exists - leaving it alone"
else
  echo "==> creating artifactory-postgresql"
  oc create secret generic artifactory-postgresql \
    "${OC_ARGS[@]}" \
    --from-literal=postgres-password="$(openssl rand -hex 24)" \
    --from-literal=password="$(openssl rand -hex 24)"
fi

# --- optional bootstrap admin password ------------------------------------
if [[ "$WITH_ADMIN" == "true" ]]; then
  if secret_exists artifactory-admin-creds; then
    echo "==> artifactory-admin-creds already exists - leaving it alone"
  else
    ADMIN_PASSWORD="${ARTIFACTORY_ADMIN_PASSWORD:-$(openssl rand -base64 18 | tr -d '/+=')}"
    echo "==> creating artifactory-admin-creds"
    # The data key must hold the full bootstrap.creds line.
    oc create secret generic artifactory-admin-creds \
      "${OC_ARGS[@]}" \
      --from-literal=bootstrap.creds="admin@127.0.0.1=${ADMIN_PASSWORD}"
    if [[ "$DRY_RUN" != "true" ]]; then
      echo
      echo "    initial admin password: ${ADMIN_PASSWORD}"
      echo "    (store it in your password manager, then change it in the UI)"
      echo
      echo "    Now uncomment artifactory.admin in helm/values-openshift.yaml:"
      echo "      admin:"
      echo "        secret: artifactory-admin-creds"
      echo "        dataKey: bootstrap.creds"
    fi
  fi
fi

if [[ "$DRY_RUN" != "true" ]]; then
  echo
  echo "Done. Secrets in $NAMESPACE:"
  oc get secrets --namespace "$NAMESPACE" \
    artifactory-cluster-keys artifactory-postgresql 2>/dev/null || true
fi
