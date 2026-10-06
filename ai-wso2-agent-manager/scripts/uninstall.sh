#!/usr/bin/env bash
# Copyright 2026 The OpenChoreo Authors
# SPDX-License-Identifier: Apache-2.0
#
# Removes everything this module installs on top of OpenChoreo, in the reverse
# order of the README installation steps:
#
#   1. Agents, their projects, Agent Manager's deployment pipelines, and the
#      environments added for Agent Manager, through the Agent Manager API
#      while Agent Manager is still running
#   2. The default environment's Thunder and API Platform Gateway
#   3. The Agent Manager Helm releases and namespace, Agent Sandbox, and the
#      Gateway Operator
#   4. Shared configuration: the tracing collector and the OpenBao entries
#   5. The Agent Manager identities in OpenChoreo's Thunder
#
# Every step skips what is already gone, and a failed removal is reported and
# skipped, so the script can be re-run. OpenChoreo itself, its Thunder,
# OpenBao, and the observability modules are kept, as are OpenChoreo projects,
# environments, and pipelines that Agent Manager did not create.
#
# Run it from a checkout of this module, with the README's Configuration
# Variables exported. See the README's Uninstallation section for the inputs.

set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSUME_YES=false
[ "${1:-}" = "--yes" ] && ASSUME_YES=true

: "${AMP_RAW:?Export the README Configuration Variables first (AMP_RAW is not set)}"
: "${AMP_API_URL:?Export the README Configuration Variables first (AMP_API_URL is not set)}"
: "${THUNDER_PUBLIC_URL:?Export the README Configuration Variables first (THUNDER_PUBLIC_URL is not set)}"
AMP_NS="${AMP_NS:-wso2-amp}"
DATA_PLANE_NS="${DATA_PLANE_NS:-openchoreo-data-plane}"
WORKFLOW_NS="${WORKFLOW_NS:-openchoreo-workflow-plane}"
OBSERVABILITY_NS="${OBSERVABILITY_NS:-openchoreo-observability-plane}"
DEFAULT_NS="${DEFAULT_NS:-default}"
ORG_NAME="${ORG_NAME:-default}"
SCRIPT_BASE_URL="${AMP_RAW}/deployments/scripts"
# Shared components other modules may use. Set to true to keep them. Without
# it, they are still kept while resources of their types remain.
KEEP_AGENT_SANDBOX="${KEEP_AGENT_SANDBOX:-false}"
KEEP_GATEWAY_OPERATOR="${KEEP_GATEWAY_OPERATOR:-false}"
# The tracing module's own collector ConfigMap, restored in step 4.
TRACING_COLLECTOR_CONFIGMAP="${TRACING_COLLECTOR_CONFIGMAP:-opentelemetry-collector}"
TRACING_CHART="observability-tracing-opensearch"

# Use only tokens this script requests; an inherited one may be expired or
# lack the permissions a step needs.
unset AGENT_MANAGER_TOKEN

for tool in kubectl helm curl python3; do
  command -v "$tool" >/dev/null || { echo "❌ $tool is required" >&2; exit 1; }
done
kubectl version >/dev/null 2>&1 || { echo "❌ kubectl cannot reach the cluster" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

step() { printf '\n=== %s ===\n' "$1"; }
info() { printf '  %s\n' "$1"; }
warn() { printf '  ⚠️  %s\n' "$1"; }
release_exists() { helm status "$1" -n "$2" >/dev/null 2>&1; }
uninstall_release() {
  if ! release_exists "$1" "$2"; then
    info "Release $1 ($2) not found, skipping"
  elif helm uninstall "$1" -n "$2" --wait --timeout 10m >/dev/null; then
    info "Uninstalled $1 ($2)"
  else
    warn "Could not uninstall $1 ($2)"
  fi
}
json() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }
# Quotes a value for a curl config file. Secrets go to curl through its config
# on stdin, so they never appear in the process list.
curl_quote() { local v="${1//\\/\\\\}"; v="${v//\"/\\\"}"; printf '"%s"' "$v"; }
# Prints the names of the resources of the given types that still exist.
remaining() {
  local type
  for type in "$@"; do
    kubectl get "${type}" -A --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
      | sed "s|^|${type%%.*}/|" || true
  done
}
# Waits up to two minutes for the resources of the given types to be deleted,
# then prints what remains.
wait_until_unused() {
  local left=""
  for _ in $(seq 1 24); do
    left="$(remaining "$@")"
    [ -z "${left}" ] && return 0
    sleep 5
  done
  printf '%s' "${left}"
}

echo "This removes WSO2 Agent Manager, its agents, environments, and identities from"
echo "the cluster in context '$(kubectl config current-context)'. OpenChoreo is kept."
if [ "$ASSUME_YES" != true ]; then
  read -r -p "Type 'uninstall' to continue: " answer
  [ "$answer" = "uninstall" ] || { echo "Aborted."; exit 1; }
fi

if [ -z "${AMP_API_CLIENT_SECRET:-}" ]; then
  AMP_API_CLIENT_SECRET="$(kubectl get secret gateway-idp-credentials -n "${DATA_PLANE_NS}" \
    -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d || true)"
fi
# Environments added for Agent Manager have an environment Thunder namespace or
# a gateway release named after them.
helm_releases="$(helm list -A --deployed --failed --pending -q 2>/dev/null || true)"
amp_environment() {
  kubectl get namespace "amp-thunder-${ORG_NAME}-$1" >/dev/null 2>&1 \
    || grep -qx "api-platform-${ORG_NAME}-$1" <<<"${helm_releases}"
}

# --- 1. Agents, projects, pipelines, and additional environments -------------
step "1. Agents, projects, pipelines, and additional environments"
AGENT_MANAGER_TOKEN=""
if curl -fsS -o /dev/null --max-time 10 "${AMP_API_URL}/healthz" 2>/dev/null && [ -n "${AMP_API_CLIENT_SECRET}" ]; then
  SCOPES="amp:project:read amp:project:delete amp:agent:read amp:agent:delete amp:deployment-pipeline:read"
  SCOPES="${SCOPES} amp:deployment-pipeline:update amp:deployment-pipeline:delete amp:environment:read amp:environment:delete"
  # The environment Thunder script also deletes Agent Manager's stored credential for it.
  SCOPES="${SCOPES} amp:org:manage-service-account"
  if ! AGENT_MANAGER_TOKEN="$(printf 'user = %s\n' "$(curl_quote "amp-api-client:${AMP_API_CLIENT_SECRET}")" \
    | curl -fsS --max-time 30 -K - -X POST "${THUNDER_PUBLIC_URL}/oauth2/token" \
      -d grant_type=client_credentials --data-urlencode "scope=${SCOPES}" \
    | json 'print(d["access_token"])')"; then
    AGENT_MANAGER_TOKEN=""
    warn "Could not get an Agent Manager token from ${THUNDER_PUBLIC_URL}"
  fi
fi
if [ -n "${AGENT_MANAGER_TOKEN}" ]; then
  export AGENT_MANAGER_TOKEN
  API="${AMP_API_URL}/api/v1/orgs/${ORG_NAME}"
  call() {
    printf 'header = %s\n' "$(curl_quote "Authorization: Bearer ${AGENT_MANAGER_TOKEN}")" \
      | curl -fsS --max-time 60 -K - -H "Content-Type: application/json" "$@"
  }
  # Prints every item of a paginated list as one JSON document per line. KEY is
  # the response field that holds the items, or empty for a bare array.
  list_all() {
    local path="$1" key="$2" limit="$3" offset=0 page count
    : > "${WORK}/items"
    for _ in $(seq 1 100); do
      page="$(call "${API}${path}?limit=${limit}&offset=${offset}")" || return 1
      count="$(printf '%s' "${page}" | KEY="${key}" OUT="${WORK}/items" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
items = (d.get(os.environ["KEY"]) or []) if os.environ["KEY"] else d
with open(os.environ["OUT"], "a") as out:
    for item in items:
        out.write(json.dumps(item) + "\n")
print(len(items))')" || return 1
      [ "${count}" -lt "${limit}" ] && break
      offset=$((offset + limit))
    done
    cat "${WORK}/items"
  }

  # Agents first: deleting one removes its deployments in every environment.
  agents=""
  if ! agents="$(call "${API}/agents" | json 'print("\n".join(a["projectName"]+"/"+a["name"] for a in d.get("agents") or []))')"; then
    agents=""
    warn "Could not list agents; delete them from the Console, then re-run"
  fi
  for agent in ${agents}; do
    deleted=false code=""
    for attempt in 1 2 3 4 5 6; do
      code="$(printf 'header = %s\n' "$(curl_quote "Authorization: Bearer ${AGENT_MANAGER_TOKEN}")" \
        | curl -sS --max-time 60 -K - -o "${WORK}/response" -w '%{http_code}' -X DELETE \
          "${API}/projects/${agent%%/*}/agents/${agent##*/}")" || true
      case "${code}" in
        2??|404) deleted=true; break ;;
        # A build or other operation still holds the agent; it usually clears quickly.
        409) [ "${attempt}" -lt 6 ] && sleep 10 ;;
        *) break ;;
      esac
    done
    if [ "${deleted}" = true ]; then
      info "Deleted agent ${agent}"
    else
      warn "Could not delete agent ${agent} (HTTP ${code:-none}): $(head -c 300 "${WORK}/response" 2>/dev/null || true)"
      warn "Step 3 still removes its workloads; delete it from the Console first to remove it cleanly."
    fi
  done
  if [ -n "${agents}" ]; then
    info "Waiting for the agent components to be removed..."
    for _ in $(seq 1 60); do
      pending=false
      for agent in ${agents}; do
        kubectl get components.openchoreo.dev -n "${DEFAULT_NS}" "${agent##*/}" >/dev/null 2>&1 && pending=true
      done
      [ "${pending}" = false ] && break
      sleep 5
    done
  fi

  # Projects that held agents. The default project belongs to the platform
  # resources release (step 3); other projects are reported and kept.
  agent_projects="$(printf '%s\n' ${agents} | sed -n 's|/.*||p' | sort -u | grep -vx default || true)"
  if projects="$(list_all /projects projects 50 | python3 -c '
import json, sys
print("\n".join(json.loads(line)["name"] for line in sys.stdin if line.strip()))')"; then
    for project in ${projects}; do
      [ "${project}" = "default" ] && continue
      if grep -qx "${project}" <<<"${agent_projects}"; then
        if call -X DELETE "${API}/projects/${project}" -o /dev/null; then
          info "Deleted project ${project}"
        else
          warn "Could not delete project ${project}"
        fi
      else
        info "Keeping project ${project}: it held no Agent Manager agents. Delete it from the Console if you no longer need it."
      fi
    done
  else
    warn "Could not list projects; delete the projects you added from the Console"
  fi

  environments=""
  if all_environments="$(list_all /environments "" 100 | python3 -c '
import json, sys
print("\n".join(json.loads(line)["name"] for line in sys.stdin if line.strip()))')"; then
    for environment in ${all_environments}; do
      [ "${environment}" = "default" ] && continue
      if amp_environment "${environment}"; then
        environments="${environments} ${environment}"
      else
        info "Keeping environment ${environment}: Agent Manager did not create it"
      fi
    done
  else
    warn "Could not list environments; remove the environments you added with remove-environment.sh"
  fi

  # An environment cannot be deleted while a pipeline references it. Delete the
  # pipelines that reference only Agent Manager environments, and return the
  # default pipeline to its installed state.
  if pipelines="$(list_all /deployment-pipelines deploymentPipelines 50 | AMP_ENVIRONMENTS="default ${environments}" python3 -c '
import json, os, sys
amp = set(os.environ["AMP_ENVIRONMENTS"].split())
for line in sys.stdin:
    if not line.strip():
        continue
    p = json.loads(line)
    # References are environment names, or objects with a name.
    name = lambda ref: ref.get("name") if isinstance(ref, dict) else ref
    refs = set()
    for path in p.get("promotionPaths") or []:
        refs.add(name(path.get("sourceEnvironmentRef")))
        refs.update(name(ref) for ref in path.get("targetEnvironmentRefs") or [])
    refs.discard(None)
    if p["name"] == "default":
        print("reset default")
    elif refs and refs <= amp:
        print("delete " + p["name"])
    else:
        print("keep " + p["name"])')"; then
    while read -r action pipeline; do
      case "${action}" in
        reset)
          if call -X PUT "${API}/deployment-pipelines/default" -o /dev/null \
            -d '{"promotionPaths":[{"sourceEnvironmentRef":"default","targetEnvironmentRefs":[]}]}'; then
            info "Reset the default pipeline to the default environment only"
          else
            warn "Could not reset the default pipeline"
          fi ;;
        delete)
          if call -X DELETE "${API}/deployment-pipelines/${pipeline}" -o /dev/null; then
            info "Deleted pipeline ${pipeline}"
          else
            warn "Could not delete pipeline ${pipeline}"
          fi ;;
        keep) info "Keeping pipeline ${pipeline}: it references environments Agent Manager did not create" ;;
      esac
    done <<<"${pipelines}"
  else
    warn "Could not list deployment pipelines"
  fi

  # Additional environments: the environment, its Thunder, and its gateway.
  # GATEWAY_NAMESPACE is where the README installs every environment's gateway;
  # remove-environment.sh deletes a namespace only when it is named <org>-<env>.
  if [ -z "${environments// /}" ]; then
    info "No additional Agent Manager environments"
  elif curl -fsSL --max-time 60 "${SCRIPT_BASE_URL}/remove-environment.sh" -o "${WORK}/remove-environment.sh"; then
    for environment in ${environments}; do
      ENV_NAME="${environment}" ORG_NAME="${ORG_NAME}" GATEWAY_NAMESPACE="${DATA_PLANE_NS}" \
      AGENT_MANAGER_URL="${AMP_API_URL}" SCRIPT_BASE_URL="${SCRIPT_BASE_URL}" \
      bash "${WORK}/remove-environment.sh" || warn "Could not fully remove environment ${environment}"
    done
  else
    warn "Could not download remove-environment.sh; additional environments were not removed"
  fi
else
  info "Agent Manager API is not reachable at ${AMP_API_URL}, or no amp-api-client secret or token is available."
  info "Skipping agents, projects, pipelines, and additional environments; remove them manually if any remain."
fi

# --- 2. Default environment --------------------------------------------------
step "2. Default environment"
if [ -n "${AMP_API_CLIENT_SECRET}" ] && kubectl get namespace "amp-thunder-${ORG_NAME}-default" >/dev/null 2>&1; then
  if curl -fsSL --max-time 60 "${SCRIPT_BASE_URL}/remove-environment-thunder.sh" -o "${WORK}/remove-environment-thunder.sh"; then
    ENV_NAME=default ORG_NAME="${ORG_NAME}" SCRIPT_BASE_URL="${SCRIPT_BASE_URL}" \
    AMP_API_URL="${AMP_API_URL}/api/v1" IDP_TOKEN_URL="${THUNDER_PUBLIC_URL}/oauth2/token" \
    IDP_CLIENT_ID=amp-api-client IDP_CLIENT_SECRET="${AMP_API_CLIENT_SECRET}" \
    bash "${WORK}/remove-environment-thunder.sh" || warn "Could not fully remove the default environment Thunder"
  else
    warn "Could not download remove-environment-thunder.sh; the default environment Thunder was not removed"
  fi
else
  info "Default environment Thunder not found, skipping"
fi
uninstall_release "api-platform-${ORG_NAME}-default" "${DATA_PLANE_NS}"
kubectl delete secret gateway-idp-credentials -n "${DATA_PLANE_NS}" --ignore-not-found >/dev/null
kubectl label namespace "${DATA_PLANE_NS}" amp.wso2.com/api-platform-gateway- >/dev/null 2>&1 || true

# --- 3. Agent Manager components ---------------------------------------------
step "3. Agent Manager components"
uninstall_release amp-evaluation-extension "${WORKFLOW_NS}"
# Helm never deletes hook resources. The evaluation template is a post-install
# hook, and each gateway release leaves its pre-install bootstrap RBAC behind.
kubectl delete clusterworkflowtemplate.argoproj.io amp-monitor-evaluation --ignore-not-found >/dev/null
for kind in rolebinding role serviceaccount; do
  kubectl get "${kind}" -n "${DATA_PLANE_NS}" -o name 2>/dev/null \
    | grep -E "/api-platform-${ORG_NAME}-[a-z0-9-]+-bootstrap-(role|rolebinding|sa)$" \
    | xargs -r kubectl delete -n "${DATA_PLANE_NS}" --ignore-not-found >/dev/null || true
done
info "Deleted Helm hook leftovers (evaluation template, gateway bootstrap RBAC)"
kubectl delete -n "${OBSERVABILITY_NS}" -f "${MODULE_DIR}/resources/amp-observer-ingress.yaml" --ignore-not-found >/dev/null
uninstall_release amp-observability-traces "${OBSERVABILITY_NS}"
uninstall_release amp-platform-resources "${DEFAULT_NS}"
uninstall_release amp "${AMP_NS}"
if kubectl get namespace "${AMP_NS}" >/dev/null 2>&1; then
  if kubectl delete namespace "${AMP_NS}" --timeout=5m >/dev/null; then
    info "Deleted namespace ${AMP_NS}"
  else
    warn "Namespace ${AMP_NS} is still terminating"
  fi
fi

# Agent Sandbox and the Gateway Operator can serve other modules. Removing
# their CRDs deletes every resource of those types, so both are kept while any
# such resource remains after Agent Manager's own are gone.
SANDBOX_TYPES="sandboxes.agents.x-k8s.io sandboxclaims.extensions.agents.x-k8s.io sandboxtemplates.extensions.agents.x-k8s.io sandboxwarmpools.extensions.agents.x-k8s.io"
if [ "${KEEP_AGENT_SANDBOX}" = true ]; then
  info "Keeping Agent Sandbox (KEEP_AGENT_SANDBOX=true)"
elif in_use="$(wait_until_unused ${SANDBOX_TYPES})" && [ -n "${in_use}" ]; then
  warn "Keeping Agent Sandbox: these sandbox resources remain: $(echo ${in_use})"
  warn "Remove them, or set KEEP_AGENT_SANDBOX=true, then re-run."
else
  uninstall_release agent-sandbox "${DATA_PLANE_NS}"
  # The chart applies the upstream controller with a Job, so Helm does not track
  # it. Remove it as the agent-sandbox module describes.
  if kubectl get namespace agent-sandbox-system >/dev/null 2>&1; then
    kubectl delete namespace agent-sandbox-system --timeout=5m >/dev/null && info "Deleted namespace agent-sandbox-system"
  fi
  kubectl delete clusterrole agent-sandbox-controller agent-sandbox-controller-extensions --ignore-not-found >/dev/null
  kubectl delete clusterrolebinding agent-sandbox-controller agent-sandbox-controller-extensions --ignore-not-found >/dev/null
  kubectl delete crd ${SANDBOX_TYPES} --ignore-not-found >/dev/null
  info "Deleted the Agent Sandbox controller, RBAC, and CRDs"
fi
GATEWAY_TYPES="$(kubectl get crd -o name 2>/dev/null | sed 's|.*/||' | grep '\.gateway\.api-platform\.wso2\.com$' || true)"
if [ "${KEEP_GATEWAY_OPERATOR}" = true ]; then
  info "Keeping Gateway Operator (KEEP_GATEWAY_OPERATOR=true)"
elif [ -n "${GATEWAY_TYPES}" ] && in_use="$(wait_until_unused ${GATEWAY_TYPES})" && [ -n "${in_use}" ]; then
  warn "Keeping the Gateway Operator: these gateway resources remain: $(echo ${in_use})"
  warn "Remove them, or set KEEP_GATEWAY_OPERATOR=true, then re-run."
else
  kubectl delete -f "${MODULE_DIR}/resources/rbac.yaml" --ignore-not-found >/dev/null
  uninstall_release gateway-operator "${DATA_PLANE_NS}"
  kubectl delete secret gateway-encryption-keys -n "${DATA_PLANE_NS}" --ignore-not-found >/dev/null
  # Helm never deletes a chart's CRDs.
  if [ -n "${GATEWAY_TYPES}" ]; then
    kubectl delete crd ${GATEWAY_TYPES} --ignore-not-found >/dev/null && info "Deleted the API Platform Gateway CRDs"
  fi
fi

# --- 4. Shared configuration -------------------------------------------------
step "4. Shared configuration"
if kubectl get configmap amp-opentelemetry-collector-config -n "${OBSERVABILITY_NS}" >/dev/null 2>&1; then
  # Find the tracing module release and version instead of asking for them.
  tracing_release="" tracing_version=""
  read -r tracing_release tracing_version < <(helm list -n "${OBSERVABILITY_NS}" --deployed --failed --pending -o json 2>/dev/null \
    | CHART="${TRACING_CHART}" python3 -c '
import json, os, sys
prefix = os.environ["CHART"] + "-"
for r in json.load(sys.stdin):
    if r["chart"].startswith(prefix):
        print(r["name"], r["chart"][len(prefix):]); break' || true) || true
  if [ -z "${tracing_release}" ]; then
    warn "The ${TRACING_CHART} release was not found in ${OBSERVABILITY_NS}; keeping the merged collector ConfigMap"
  elif helm upgrade "${tracing_release}" "oci://ghcr.io/openchoreo/helm-charts/${TRACING_CHART}" \
      --version "${tracing_version}" --namespace "${OBSERVABILITY_NS}" --reuse-values \
      --set opentelemetry-collector.configMap.existingName="${TRACING_COLLECTOR_CONFIGMAP}" >/dev/null; then
    kubectl rollout restart deployment/opentelemetry-collector -n "${OBSERVABILITY_NS}" >/dev/null || true
    info "Pointed ${tracing_release} back at ${TRACING_COLLECTOR_CONFIGMAP}"
    # Delete the merged copy only once the collector no longer uses it.
    kubectl delete configmap amp-opentelemetry-collector-config -n "${OBSERVABILITY_NS}" >/dev/null
    info "Deleted the merged collector ConfigMap"
  else
    warn "Could not point ${tracing_release} back at ${TRACING_COLLECTOR_CONFIGMAP}; keeping the merged collector ConfigMap"
  fi
else
  info "Merged collector ConfigMap not found, skipping"
fi
if kubectl get pod openbao-0 -n openbao >/dev/null 2>&1; then
  # Keep secret/workflow-plane-oauth-client-secret: OpenChoreo's builds use it.
  # The token reaches the pod on stdin, so it never appears in a process list.
  bao() {
    printf '%s\n' "${BAO_TOKEN:-root}" | kubectl exec -i -n openbao openbao-0 -- \
      sh -c 'read -r BAO_TOKEN && export BAO_TOKEN && exec bao "$@"' sh "$@"
  }
  for entry in amp-publisher-client-secret amp-system-client-secret; do
    # A delete reports success for a missing entry, so check first.
    if ! check="$(bao kv metadata get "secret/${entry}" 2>&1 >/dev/null)"; then
      if printf '%s' "${check}" | grep -q 'No value found at'; then
        info "secret/${entry} not found in OpenBao, skipping"
      else
        warn "Could not read secret/${entry} from OpenBao; check BAO_TOKEN"
      fi
    elif bao kv metadata delete "secret/${entry}" >/dev/null 2>&1; then
      info "Deleted secret/${entry} from OpenBao"
    else
      warn "Could not delete secret/${entry} from OpenBao; check BAO_TOKEN"
    fi
  done
fi

# --- 5. Identities -----------------------------------------------------------
step "5. Identities"
AMP_IDENTITY_CONFIG="${AMP_IDENTITY_CONFIG:-${AMP_IDENTITY_WORK:+${AMP_IDENTITY_WORK}/configuration.yaml}}"
if [ -n "${OPENCHOREO_SYSTEM_APP_SECRET:-}" ]; then
  # The same system-scoped token IDENTITY.md requests. Always request a new one:
  # an exported token from an earlier session has usually expired. The secret
  # reaches curl on stdin, so it never appears in a process list.
  if ! THUNDER_ADMIN_TOKEN="$(printf '%s' "${OPENCHOREO_SYSTEM_APP_SECRET}" \
    | curl -fsS --max-time 30 -X POST "${THUNDER_PUBLIC_URL}/oauth2/token" \
      -d grant_type=client_credentials -d client_id=openchoreo-system-app \
      --data-urlencode client_secret@- -d scope=system \
      --data-urlencode "resource=${THUNDER_PUBLIC_URL}/mcp" | json 'print(d["access_token"])')"; then
    THUNDER_ADMIN_TOKEN=""
    warn "Could not get a Thunder administration token with OPENCHOREO_SYSTEM_APP_SECRET"
  fi
fi
export THUNDER_ADMIN_TOKEN="${THUNDER_ADMIN_TOKEN:-}"
if [ -n "${THUNDER_ADMIN_TOKEN}" ] && [ -n "${AMP_IDENTITY_CONFIG}" ] && [ -f "${AMP_IDENTITY_CONFIG}" ]; then
  python="${MODULE_DIR}/.venv/bin/python"
  [ -x "${python}" ] || { make -C "${MODULE_DIR}" .venv/bin/python >/dev/null 2>&1 || true; }
  [ -x "${python}" ] || python=python3
  args=(--config "${AMP_IDENTITY_CONFIG}" --thunder-url "${THUNDER_ADMIN_URL:-${THUNDER_PUBLIC_URL}}" --apply)
  [ -n "${OPENCHOREO_CA_FILE:-}" ] && args+=(--ca-file "${OPENCHOREO_CA_FILE}")
  [ "${THUNDER_PUBLIC_URL%%:*}" = "http" ] && args+=(--allow-http)
  "${python}" "${MODULE_DIR}/scripts/provision-thunder-identities.py" remove "${args[@]}" \
    || warn "Could not remove every identity; re-run, or follow IDENTITY.md (Remove the identities)"
else
  info "Skipped: set OPENCHOREO_SYSTEM_APP_SECRET (or THUNDER_ADMIN_TOKEN) and AMP_IDENTITY_CONFIG"
  info "(or AMP_IDENTITY_WORK) to remove the identities,"
  info "or follow IDENTITY.md (Remove the identities). A new installation requires it."
fi

# --- Summary -----------------------------------------------------------------
step "Remaining Agent Manager resources"
leftover="$(helm list -A --deployed --failed --pending -o json 2>/dev/null | json '
names=[r["namespace"]+"/"+r["name"] for r in d if r["name"].startswith(("amp", "api-platform-")) or r["name"] in ("agent-sandbox", "gateway-operator")]
print("\n".join(names))' || true)"
namespaces="$(kubectl get namespaces --no-headers -o custom-columns=NAME:.metadata.name \
  | grep -E "^(${AMP_NS}|amp-thunder-${ORG_NAME}-.*)$" || true)"
crds="$(kubectl get crd -o name | grep -E '\.gateway\.api-platform\.wso2\.com$|\.agents\.x-k8s\.io$' || true)"
[ "${KEEP_AGENT_SANDBOX}" = true ] && crds="$(echo "${crds}" | grep -v 'agents\.x-k8s\.io' || true)"
[ "${KEEP_GATEWAY_OPERATOR}" = true ] && crds="$(echo "${crds}" | grep -v 'api-platform' || true)"
[ "${KEEP_AGENT_SANDBOX}" != true ] && kubectl get namespace agent-sandbox-system >/dev/null 2>&1 \
  && namespaces="${namespaces} agent-sandbox-system"
[ -n "${leftover}" ] && info "Helm releases: $(echo ${leftover})"
[ -n "${crds}" ] && info "CRDs: $(echo ${crds})"
[ -n "${namespaces// /}" ] && info "Namespaces: $(echo ${namespaces})"
[ -z "${leftover}${namespaces// /}${crds}" ] && info "None. Agent Manager is removed."
exit 0
