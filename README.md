# JFrog Artifactory on OpenShift, deployed by OpenShift GitOps

A complete, reviewable Argo CD deployment of JFrog Artifactory (chart
`jfrog/artifactory` **107.161.26**, Artifactory **7.161.26**) for OpenShift.

Everything is declarative: two Argo CD `Application` CRDs, an `AppProject`,
the OpenShift-specific platform resources (SCC, ServiceAccount, Route,
NetworkPolicy) and one values file. Secrets are the only thing that is not in
git, by design.

---

## Layout

```
gitops/
  bootstrap/                      # applied once by hand
    appproject.yaml               #   AppProject "artifactory" (what this repo may touch)
    root-application.yaml         #   app-of-apps -> gitops/applications/
    kustomization.yaml
  applications/                   # managed by the root Application
    artifactory-platform.yaml     #   Application, sync-wave -1  -> manifests/platform
    artifactory.yaml              #   Application, sync-wave  0  -> Helm release
manifests/platform/               # OpenShift plumbing (kustomize)
  namespace.yaml  serviceaccount.yaml
  scc.yaml  rbac.yaml             #   custom SCC + "use" RoleBinding
  route.yaml                      #   external access (replaces the chart's NGINX)
  networkpolicy.yaml
helm/
  values-openshift.yaml           # the only file you normally edit
examples/                         # external DB, S3 filestore, ESO secrets, Docker routes, RBAC
scripts/
  create-secrets.sh               # one-time secret bootstrap
  render.sh                       # render locally exactly what Argo CD will apply
```

## Prerequisites

| | |
|---|---|
| OpenShift | 4.12+ |
| OpenShift GitOps | 1.9+ (multi-source `Application` support) |
| Storage | a default `StorageClass` with `ReadWriteOnce`, 150Gi free (100Gi Artifactory + 50Gi PostgreSQL) |
| Cluster capacity | ~4.2 CPU / ~13.5Gi of **requests** at the `xsmall` profile; the Artifactory pod alone needs ~2.2 CPU / 6.3Gi on a single node |
| Egress | `charts.jfrog.io` (chart) and `releases-docker.jfrog.io` (images) |
| License | `jfrog/artifactory-pro` needs a JFrog licence. For the free edition set `image.repository: jfrog/artifactory-oss` |

## Install

### 1. Push this to git and point the manifests at it

Argo CD reads the manifests from git, not from your laptop, so this directory
has to live in a repository the cluster can reach. Replace the placeholder URL
in the four `Application`/`AppProject` files (macOS `sed`; drop the `''` on
Linux):

```bash
grep -rl 'CHANGE-ME' . | xargs sed -i '' \
  's#https://github.com/CHANGE-ME/artifactory-openshift-gitops.git#<YOUR_GIT_URL>#'

git init && git add -A && git commit -m "Artifactory on OpenShift via GitOps"
git remote add origin <YOUR_GIT_URL> && git push -u origin main
```

If the repository is private, add the credentials to Argo CD first
(`oc -n openshift-gitops ...` or **Settings → Repositories** in the UI).

### 2. Create the secrets

Nothing sensitive belongs in this repository, so the cluster keys and database
credentials are created once, out of band:

```bash
oc login ...
./scripts/create-secrets.sh --with-admin
```

This creates, in namespace `artifactory`:

| Secret | Keys | Purpose |
|---|---|---|
| `artifactory-cluster-keys` | `master-key`, `join-key` | **Never rotate `master-key` after the first start** — it encrypts everything in the database |
| `artifactory-postgresql` | `postgres-password`, `password` | bundled PostgreSQL credentials |
| `artifactory-admin-creds` | `bootstrap.creds` | optional initial `admin` password (prints once) |

The script is idempotent and never overwrites an existing secret. If you used
`--with-admin`, uncomment the `artifactory.admin` block in
`helm/values-openshift.yaml` and commit.

For a fully declarative setup use External Secrets Operator or Sealed Secrets
instead — see `examples/externalsecret-artifactory.yaml`. Either way the
secrets must exist **before** the Helm release syncs; the pods will sit in
`CreateContainerConfigError` until they do.

### 3. Bootstrap Argo CD

```bash
oc apply -k gitops/bootstrap
```

That is the only imperative step. It creates the `AppProject` and the
app-of-apps; the app-of-apps then creates `artifactory-platform` (wave -1) and
`artifactory` (wave 0) from git.

### 4. Watch it come up

```bash
oc -n openshift-gitops get applications
oc -n artifactory get pods -w
oc -n artifactory get route artifactory -o jsonpath='{.spec.host}{"\n"}'
```

First start takes **5–10 minutes** (database migration plus a startup probe
that allows up to 7.5 minutes), during which Argo CD reports `Progressing`.
Then open `https://<route-host>/ui/` and log in as `admin`.

Finally, set **Administration → General → Custom Base URL** to the Route URL
so generated links, Docker and remote-repo redirects are correct.

---

## How it works, and why

### Argo CD `Application` CRDs

`artifactory.yaml` uses **two sources**: the upstream chart straight from
`charts.jfrog.io`, pinned to `107.161.26`, and this git repo as `$values`.
Values files are merged in order, last wins:

```yaml
valueFiles:
  - sizing/artifactory-xsmall.yaml      # shipped inside the chart: CPU/memory
  - $values/helm/values-openshift.yaml  # this repo: OpenShift specifics
```

So resource tuning stays upstream (swap `xsmall` for `small`, `medium`,
`large`, `xlarge`, `2xlarge`) and only platform decisions live here.

Sync waves give the ordering that matters: namespace, ServiceAccount, SCC and
RoleBinding exist before any pod is scheduled. Inside the platform
Application, waves order the resources again (`-10` namespace → `-9` SA/SCC →
`-8` RBAC → `-7` Route/NetworkPolicy).

### The SecurityContextConstraints

This is the part that makes or breaks Artifactory on OpenShift. The JFrog
images run as fixed non-root UIDs and the chart writes them into the pod
`securityContext`:

| Workload | UID |
|---|---|
| `artifactory` (StatefulSet) | 1030 |
| `artifactory-frontend` | 1031 |
| `artifactory-jfbus` | 1127 |
| `artifactory-jfmelt` | 1128 |
| optional add-ons (rtfs, apptrust, …) | 1038, 1120, 1125, 1129, 1132 |

OpenShift's default `restricted-v2` SCC only allows UIDs from the namespace's
allocated range (usually 1000000000+), so every one of those pods is rejected:

```
unable to validate against any security context constraint:
  spec.containers[0].securityContext.runAsUser: Invalid value: 1030
```

`manifests/platform/scc.yaml` is a clone of `restricted-v2` that permits UIDs
and GIDs **1030–1140 and nothing else**: no privileged containers, no host
network/PID/IPC, no host paths, all capabilities dropped, seccomp
`RuntimeDefault`. It has no `users`, `groups` or `priority`, so it is never
selected automatically — it is granted only to the `artifactory`
ServiceAccount through a namespaced `Role`/`RoleBinding` with the `use` verb.
`anyuid`/`privileged` are never involved.

Because the chart creates *standalone Deployments* for some services (which
would otherwise use the namespace's `default` ServiceAccount),
`helm/values-openshift.yaml` pins `frontend`, `jfbus` and `jfmelt` to the same
ServiceAccount. One SCC binding then covers every Artifactory pod.

The bundled PostgreSQL is handled the opposite way: it is a Bitnami-derived
chart, so `global.compatibility.openshift.adaptSecurityContext: force` strips
its hard-coded UID/GID and it runs unmodified under `restricted-v2`.

### Routes instead of the bundled NGINX

`nginx.enabled: false` and `ingress.enabled: false`. The OpenShift Router
terminates TLS (`edge`, HTTP redirected) and proxies to the JFrog Router
container on service port `http-router` (8082), which fronts every
microservice (`/ui`, `/artifactory`, `/access`, …). The Route carries a 600s
HAProxy timeout, because the 30s default breaks large artifact transfers.

Docker registry access: see `examples/route-docker-subdomain.yaml`. The
repository-path method needs no extra objects; the subdomain method needs a
wildcard Route and a router that allows wildcards.

### Why the secrets are pre-created

If `postgresql.auth.existingSecret` were left empty, the subchart would
generate a random password on **every** `helm template` — and Argo CD renders
on every sync. Each sync would rewrite the secret while the database kept the
original password, and Artifactory would start failing authentication. Same
reasoning for `master-key`: it must be stable and it must never be in git.

With this setup the only chart-rendered Secret is the unified secret holding
`system.yaml` and `binarystore.xml` — fully deterministic, so Argo CD reports
`Synced` and `selfHeal` never fights the application.

---

## Day-2 operations

**Change anything** — edit `helm/values-openshift.yaml`, commit, push. Argo CD
syncs automatically (`automated.prune`, `selfHeal`).

**Preview a change before committing:**

```bash
./scripts/render.sh            # writes .render/{platform,artifactory}.yaml
```

It reads the chart version and sizing profile out of the Application, so what
you see is what Argo CD applies.

**Upgrade Artifactory** — bump `targetRevision` in
`gitops/applications/artifactory.yaml`. Read the chart CHANGELOG first;
Artifactory upgrades run database migrations and are not reversible by a
rollback of the manifest alone. Back up the database and the PVC first.

**Resize storage** — the StatefulSet's `volumeClaimTemplates` are immutable,
which is why the Application ignores diffs on that field. Expand the PVC
directly (requires a `StorageClass` with `allowVolumeExpansion: true`), then
update the value for the record:

```bash
oc -n artifactory patch pvc artifactory-volume-artifactory-0 \
  -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'
```

**Production hardening** — move the database out (`examples/values-external-database.yaml`)
and the filestore to object storage (`examples/values-objectstore-s3.yaml`).
Those two changes are also what make `replicaCount > 1` possible.

**Add a license** — create the secret, then uncomment `artifactory.license`:

```bash
oc -n artifactory create secret generic artifactory-license \
  --from-file=artifactory.lic=./artifactory.lic
```

**Uninstall** — `oc -n openshift-gitops delete application artifactory-bootstrap`
(the finalizer cascades). PVCs created from `volumeClaimTemplates` are *not*
Argo CD-managed and survive on purpose; delete them explicitly.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `unable to validate against any security context constraint … runAsUser: Invalid value: 1030` | The platform Application has not synced, or a new service runs as a UID outside 1030–1140. Check `oc -n artifactory get rolebinding artifactory-use-scc` and that the pod's SA is `artifactory`. |
| `securitycontextconstraints … is forbidden: User system:serviceaccount:…argocd-application-controller cannot create` | Custom Argo CD instance without SCC rights — apply `examples/argocd-scc-permissions.yaml`. |
| Pods in `CreateContainerConfigError`, "secret not found" | `scripts/create-secrets.sh` was not run, or it ran in the wrong namespace. |
| PostgreSQL `password authentication failed` | The `artifactory-postgresql` secret was recreated after the database was initialised. Restore the original password, or wipe the PostgreSQL PVC and re-init. |
| PVC `Pending` | No default `StorageClass`, or no RWO capacity. Set `storageClassName` in `helm/values-openshift.yaml`. |
| Application stuck `Progressing` for >15 min | Normal is 5–10. Check `oc -n artifactory logs sts/artifactory -c artifactory` — usually the database or the `master-key` (a changed key makes Artifactory refuse to decrypt). |
| `Values file sizing/artifactory-xsmall.yaml … not allowed / does not exist` | Very old Argo CD. Copy that file from the chart into `helm/` and reference it as `$values/helm/<file>`. |
| 502 / truncated uploads through the Route | Raise `haproxy.router.openshift.io/timeout` in `manifests/platform/route.yaml`. |

## Security notes

- No privileged or root containers; the custom SCC is narrower than `anyuid`
  and is bound to one ServiceAccount in one namespace.
- All capabilities dropped, `allowPrivilegeEscalation: false`, seccomp
  `RuntimeDefault` on every container.
- Namespace defaults to deny-all ingress; only the OpenShift Router (8082) and
  intra-namespace traffic are allowed.
- No secret material in git. Rotate the admin password after first login;
  never rotate `master-key`.
- Chart and images are version-pinned; pin by digest (`artifactory.image.digest`)
  if your policy requires immutable references.
