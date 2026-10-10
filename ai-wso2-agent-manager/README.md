# WSO2 Agent Manager Module for OpenChoreo

[WSO2 Agent Manager](https://github.com/wso2/agent-manager) is an open control plane for deploying, managing, and governing AI agents at scale. This module installs Agent Manager v1.0.0 on an existing OpenChoreo v1.3.x installation and wires it into OpenChoreo's identity provider and its data, workflow, and observability planes.

> **Important:** Agent Manager reuses OpenChoreo's Thunder identity provider, OpenBao secret store, plane gateways, and OpenSearch. It does not install a second copy of any of them. Read [Prerequisites](#prerequisites) before you start: the target cluster must not contain OpenChoreo's getting-started sample resources.

## Table of Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Configuration Variables](#configuration-variables)
- [Step 1: Configure Identities](#step-1-configure-identities)
- [Step 2: Prepare OpenChoreo](#step-2-prepare-openchoreo)
- [Step 3: Install Gateway Operator](#step-3-install-gateway-operator)
- [Step 4: Install Agent Manager Core](#step-4-install-agent-manager-core)
- [Step 5: Install Agent Sandbox](#step-5-install-agent-sandbox)
- [Step 6: Install Platform Resources](#step-6-install-platform-resources)
- [Step 7: Install Observability Extension](#step-7-install-observability-extension)
- [Step 8: Install Evaluation Extension](#step-8-install-evaluation-extension)
- [Step 9: Install API Platform Gateway Extension](#step-9-install-api-platform-gateway-extension)
- [Step 10: Configure the Environments](#step-10-configure-the-environments)
- [Verification](#verification)
- [Access](#access)
- [Adding Environments](#adding-environments)
- [Uninstallation](#uninstallation)
- [Compatibility](#compatibility)

---

## Architecture

Agent Manager components are distributed across the OpenChoreo planes as shown below. This guide targets a single-cluster OpenChoreo installation, where each plane is a namespace.

```text
┌─── Control Plane ───────────────────────────┐   ┌─── Data Plane ─────────────────────────────┐
│ ns: openchoreo-control-plane                │   │ ns: openchoreo-data-plane                  │
│   OpenChoreo Control Plane                  │   │   OpenChoreo Data Plane                    │
│                                             │   │   + Gateway Operator             (Step 3)  │
│ ns: thunder                                 │   │   + Agent Sandbox RBAC           (Step 5)  │
│   OpenChoreo Thunder                        │   │   + API Platform Gateways        (Step 10) │
│   + AMP identities and settings  (Step 1)   │   └────────────────────────────────────────────┘
│                                             │
│ ns: wso2-amp                                │   ┌─── Workflow Plane ─────────────────────────┐
│   Agent Manager Core             (Step 4)   │   │ ns: openchoreo-workflow-plane              │
│                                             │   │   OpenChoreo Workflow Plane                │
│ ns: default                                 │   │   + Evaluation Extension         (Step 8)  │
│   Platform Resources             (Step 6)   │   └────────────────────────────────────────────┘
│                                             │
│ ns: amp-thunder-default-default             │   ┌─── Observability Plane ────────────────────┐
│   Environment Thunder            (Step 10)  │   │ ns: openchoreo-observability-plane         │
└─────────────────────────────────────────────┘   │   OpenChoreo Observability Plane           │
                                                  │   + Observability Extension      (Step 7)  │
┌─── Agent Sandbox ───────────────────────────┐   └────────────────────────────────────────────┘
│ ns: agent-sandbox-system                    │
│   Sandbox controller             (Step 5)   │
└─────────────────────────────────────────────┘
```

### Component Summary

| Component | Chart | Namespace | Required |
|-----------|-------|-----------|----------|
| Gateway Operator | `oci://ghcr.io/wso2/api-platform/helm-charts/gateway-operator` `0.11.0` | `openchoreo-data-plane` | Yes |
| Agent Manager Core | `oci://ghcr.io/wso2/wso2-agent-manager` | `wso2-amp` | Yes |
| Agent Sandbox | `oci://ghcr.io/openchoreo/helm-charts/agent-sandbox` `0.1.1` | `openchoreo-data-plane` | Yes |
| Platform Resources | `oci://ghcr.io/wso2/wso2-amp-platform-resources-extension` | `default` | Yes |
| Observability Extension | `oci://ghcr.io/wso2/wso2-amp-observability-extension` | `openchoreo-observability-plane` | Yes, for traces, logs, and metrics in the console |
| Evaluation Extension | `oci://ghcr.io/wso2/wso2-amp-evaluation-extension` | `openchoreo-workflow-plane` | No |
| API Platform Gateway Extension | `oci://ghcr.io/wso2/wso2-amp-api-platform-gateway-extension` | `openchoreo-data-plane` | Yes |
| Environment Thunder | Installed by `scripts/configure-environments.sh` | `amp-thunder-<org>-<env>` | Yes, for agent identities |

Agent Manager charts are pulled from `oci://ghcr.io/wso2` at version `1.0.0` unless noted otherwise.

---

## Prerequisites

- OpenChoreo v1.3.x installed with the control plane, data plane, workflow plane, and observability plane running, following the [OpenChoreo installation guide](https://openchoreo.dev/docs/getting-started/try-it-out/on-your-environment/)
- ThunderID 1.0.x as OpenChoreo's identity provider. OpenChoreo v1.3.x installs ThunderID 1.0.1 as the `thunder` release in the `thunder` namespace
- A Vault-compatible secret store for Agent Manager, which reads and writes Git credentials and agent secrets over the Vault KV v2 API. OpenChoreo installs OpenBao by default; HashiCorp Vault also works. The `default` `ClusterSecretStore` may use another provider; see [Using a secret store other than OpenBao](#using-a-secret-store-other-than-openbao)
- The `observability-logs-opensearch` and `observability-tracing-opensearch` modules installed in `openchoreo-observability-plane`
- A container registry the workflow plane can push to, which creates repositories on push and uses static credentials (for example CNCF Distribution or Harbor; Amazon ECR does not work)
- `helm` v3.12+ (Helm 3 only), `kubectl` v1.32+, `curl`, and Python 3.10+
- Linux kernel 6.3+ on build nodes, or set `buildWorkflows.userNamespaces=false` in [Step 6](#step-6-install-platform-resources)

### Resource Conflicts

The Platform Resources chart creates resources whose names are hard-coded in Agent Manager. OpenChoreo's getting-started sample bundle (`samples/getting-started/all.yaml` and the workflow templates) creates resources with the same names but different specifications, so Helm refuses to install over them. Agent Manager's `horizontal-pod-autoscaler` trait, for example, takes different parameters from OpenChoreo's.

Check that none of these exist before installing. Each command must report `NotFound`:

```bash
kubectl get project default -n default
kubectl get deploymentpipeline default -n default
kubectl get clustertrait horizontal-pod-autoscaler
kubectl get clusterworkflowtemplate checkout-source publish-image \
  containerfile-build gcp-buildpacks-build ballerina-buildpack-build
```

If any exist, install Agent Manager on an OpenChoreo installation where the sample bundle was not applied. Deleting or replacing them breaks OpenChoreo components that use them.

---

## Configuration Variables

Set these before running any commands in this guide. The base domains are the ones you chose when installing OpenChoreo; the Agent Manager hostnames sit directly under them, so the existing wildcard gateway certificates already cover them.

```bash
export AMP_VERSION="1.0.0"
export HELM_CHART_REGISTRY="ghcr.io/wso2"
export AMP_RAW="https://raw.githubusercontent.com/wso2/agent-manager/amp/v${AMP_VERSION}"
export MODULE_RAW="https://raw.githubusercontent.com/openchoreo/community-modules/main/ai-wso2-agent-manager"

export AMP_NS="wso2-amp"
export CONTROL_PLANE_NS="openchoreo-control-plane"
export DATA_PLANE_NS="openchoreo-data-plane"
export WORKFLOW_NS="openchoreo-workflow-plane"
export OBSERVABILITY_NS="openchoreo-observability-plane"
export DEFAULT_NS="default"

# OpenChoreo base domains (from the OpenChoreo installation)
export CP_BASE_DOMAIN="openchoreo.example.com"
export DP_DOMAIN="apps.openchoreo.example.com"
export OBS_BASE_DOMAIN="openchoreo.observability.example.com"

# Agent Manager hostnames
export AMP_CONSOLE_HOST="amp.${CP_BASE_DOMAIN}"
export AMP_API_HOST="amp-api.${CP_BASE_DOMAIN}"
export AMP_OBSERVER_HOST="amp-observer.${OBS_BASE_DOMAIN}"
export AMP_GATEWAY_HOST="default-default.${DP_DOMAIN}"

export AMP_CONSOLE_URL="https://${AMP_CONSOLE_HOST}"
export AMP_API_URL="https://${AMP_API_HOST}"
export AMP_OBSERVER_URL="https://${AMP_OBSERVER_HOST}"
export INSTRUMENTATION_URL="https://${AMP_GATEWAY_HOST}/otel"

# OpenChoreo's Thunder: public issuer and in-cluster service
export THUNDER_PUBLIC_URL="https://thunder.${CP_BASE_DOMAIN}"
export THUNDER_NAMESPACE="thunder"
export THUNDER_PORT="8090"
export THUNDER_INTERNAL_HOST="thunder-service.${THUNDER_NAMESPACE}.svc.cluster.local"
export THUNDER_INTERNAL_URL="http://${THUNDER_INTERNAL_HOST}:${THUNDER_PORT}"
export OPENCHOREO_API_HOST="openchoreo-api.${CONTROL_PLANE_NS}.svc.cluster.local"
export OPENCHOREO_API_URL="http://${OPENCHOREO_API_HOST}:8080"

# Data plane gateway ports, as registered on the ClusterDataPlane
export AGENTS_HTTP_PORT="80"
export AGENTS_HTTPS_PORT="443"

# Registry the workflow plane pushes agent images to
# (on OpenChoreo's local k3d setup: host.k3d.internal:10082)
export REGISTRY_ENDPOINT="registry.example.com"
```

Set your own values after this block, not before: each line here overwrites the variable. To test changes that are not merged yet, point `MODULE_RAW` at your fork's branch, for example `https://raw.githubusercontent.com/<you>/community-modules/refs/heads/<branch>/ai-wso2-agent-manager`.

### Read the Values from OpenChoreo

Instead of editing the domain, port, and Thunder lines by hand, read them from your OpenChoreo installation. Run this after the block above: it takes the Thunder issuer and in-cluster address and the control plane domain from the control plane release, the observability domain from the observability plane release, and the agent domain and ports from the `default` ClusterDataPlane. It then sets the Agent Manager addresses that depend on them and prints the result. Check the printed values; any it could not read are reported, and you set those by hand. `REGISTRY_ENDPOINT` is not recorded by OpenChoreo, so always set it yourself:

```bash
eval "$(CP_VALUES="$(helm get values openchoreo-control-plane -n "${CONTROL_PLANE_NS}" -a -o json)" \
  OBS_VALUES="$(helm get values openchoreo-observability-plane -n "${OBSERVABILITY_NS}" -a -o json)" \
  DP_GATEWAY="$(kubectl get clusterdataplane default -o jsonpath='{.spec.gateway.ingress.external}')" \
  python3 -c '
import json, os, shlex, sys
from urllib.parse import urlsplit
cp, obs = json.loads(os.environ["CP_VALUES"]), json.loads(os.environ["OBS_VALUES"])
dp = json.loads(os.environ["DP_GATEWAY"] or "{}")
def get(d, path):
    for key in path.split("."):
        d = d.get(key) if isinstance(d, dict) else None
    return d
def domain(wildcard, url):
    if isinstance(wildcard, str) and wildcard.startswith("*."):
        return wildcard[2:]
    host = urlsplit(url or "").hostname or ""
    return host.split(".", 1)[1] if "." in host else ""
token_url = urlsplit(get(cp, "security.oidc.tokenUrl") or "")
values = {
    "THUNDER_PUBLIC_URL": get(cp, "security.oidc.issuer"),
    "THUNDER_INTERNAL_HOST": token_url.hostname,
    "THUNDER_PORT": token_url.port,
    "THUNDER_NAMESPACE": (token_url.hostname or "").split(".")[1] if (token_url.hostname or "").count(".") >= 2 else None,
    "CP_BASE_DOMAIN": domain(get(cp, "gateway.tls.hostname"), get(cp, "openchoreoApi.config.server.publicUrl")),
    "OBS_BASE_DOMAIN": domain(get(obs, "gateway.tls.hostname"), get(cp, "portalAssistant.config.observerApiUrl")),
    "DP_DOMAIN": get(dp, "https.host") or get(dp, "http.host"),
    "AGENTS_HTTP_PORT": get(dp, "http.port"),
    "AGENTS_HTTPS_PORT": get(dp, "https.port"),
}
missing = [name for name, value in values.items() if value in (None, "")]
if missing:
    print("Could not read " + ", ".join(missing) + "; set them by hand.", file=sys.stderr)
for name, value in values.items():
    if value not in (None, ""):
        print(f"export {name}={shlex.quote(str(value))}")
')"
export AMP_CONSOLE_HOST="amp.${CP_BASE_DOMAIN}" AMP_API_HOST="amp-api.${CP_BASE_DOMAIN}"
export AMP_OBSERVER_HOST="amp-observer.${OBS_BASE_DOMAIN}" AMP_GATEWAY_HOST="default-default.${DP_DOMAIN}"
export AMP_CONSOLE_URL="https://${AMP_CONSOLE_HOST}" AMP_API_URL="https://${AMP_API_HOST}"
export AMP_OBSERVER_URL="https://${AMP_OBSERVER_HOST}" INSTRUMENTATION_URL="https://${AMP_GATEWAY_HOST}/otel"
export THUNDER_INTERNAL_URL="http://${THUNDER_INTERNAL_HOST}:${THUNDER_PORT}"
for name in CP_BASE_DOMAIN DP_DOMAIN OBS_BASE_DOMAIN AGENTS_HTTP_PORT AGENTS_HTTPS_PORT THUNDER_PUBLIC_URL \
            THUNDER_NAMESPACE THUNDER_INTERNAL_URL AMP_CONSOLE_URL AMP_API_URL AMP_OBSERVER_URL AMP_GATEWAY_HOST; do
  printenv "${name}" >/dev/null && echo "${name}=$(printenv "${name}")"
done
```

The Thunder variables assume OpenChoreo's default release, `thunder` in the `thunder` namespace, whose values set `fullnameOverride: thunder` and so name the service `thunder-service`. Confirm the service with `kubectl get svc -n ${THUNDER_NAMESPACE}`, and adjust `THUNDER_NAMESPACE`, `THUNDER_PORT`, and `THUNDER_INTERNAL_HOST` if yours differs; every command in this guide reads them. `THUNDER_PUBLIC_URL` must match the `iss` claim in tokens Thunder issues:

```bash
kubectl run thunder-issuer --rm -i --restart=Never --image=curlimages/curl -- \
  -s "${THUNDER_INTERNAL_URL}/.well-known/openid-configuration" | grep -o '"issuer":"[^"]*"'
```

### Download the Module Tools

Identity provisioning ([Step 1](#step-1-configure-identities)), trace ingestion ([Step 2](#step-2-prepare-openchoreo)), and [uninstallation](#uninstallation) run this module's scripts, which read templates from its `values/` and `resources/` folders. Download them with that layout into an empty working folder, and run every remaining command in this guide from that folder:

```bash
mkdir -p amp-install && cd amp-install
for f in scripts/provision-thunder-identities.py scripts/merge-collector-config.py scripts/uninstall.sh \
         scripts/configure-environments.sh scripts/requirements.txt values/thunder-identities.yaml \
         values/agent-manager-v1.yaml values/api-platform-gateway-extension.yaml \
         resources/amp-thunder-identities.yaml resources/amp-observer-ingress.yaml resources/rbac.yaml; do
  curl -fsSL --create-dirs -o "${f}" "${MODULE_RAW}/${f}"
done
```

### Trust the Gateway CA

Several steps call Thunder and the Agent Manager API over HTTPS from your machine, so trust the CA that signs the gateway certificates first. `OPENCHOREO_CA_FILE` is used by the Python identity tool and the environment Thunder; `CURL_CA_BUNDLE` by `curl`.

OpenChoreo's reference installation issues its gateway certificates from a self-signed CA, `openchoreo-ca`. Export it from the cluster:

```bash
export OPENCHOREO_CA_FILE="${PWD}/openchoreo-ca.crt"
kubectl get secret openchoreo-ca-secret -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > "${OPENCHOREO_CA_FILE}"
```

If your gateway certificates come from elsewhere, set the variable instead of running that block:

- **Your organization's private CA:** set `OPENCHOREO_CA_FILE` to the path of a PEM bundle with the root CA and any intermediate CAs that sign the gateway certificates. The cluster has no `openchoreo-ca-secret` in this case.
- **A publicly trusted CA:** set `OPENCHOREO_CA_FILE=""` and skip the rest of this section.

Confirm that the file holds certificates, then build the bundle `curl` uses from the system trust store plus that file. The first command must print `1` or more:

```bash
grep -c 'BEGIN CERTIFICATE' "${OPENCHOREO_CA_FILE}"
```

```bash
export CURL_CA_BUNDLE="${PWD}/amp-ca-bundle.crt"
{ cat /etc/ssl/cert.pem 2>/dev/null || cat /etc/ssl/certs/ca-certificates.crt; cat "${OPENCHOREO_CA_FILE}"; } > "${CURL_CA_BUNDLE}"
```

[Step 10](#step-10-configure-the-environments) passes the same file to the environment Thunder, so every environment trusts the same CA.

Keep this shell session and working folder for the whole installation. [Step 1](#step-1-configure-identities) also exports the client secrets used by later steps.

---

## Step 1: Configure Identities

> **Cluster:** Control Plane

Agent Manager uses Thunder for authentication, authorization, identity administration, and agent identity provisioning. Follow [IDENTITY.md](IDENTITY.md) to provision the Agent Manager identities into the Thunder instance OpenChoreo already runs. Use the hostnames from [Configuration Variables](#configuration-variables) in its configuration file:

| IDENTITY.md setting | Value |
|---|---|
| `thunderPublicUrl` | `${THUNDER_PUBLIC_URL}` |
| `consolePublicUrl` | `${AMP_CONSOLE_URL}` |
| `apiPublicUrl` | `${AMP_API_URL}` |
| `observerPublicUrl` | `${AMP_OBSERVER_URL}` |
| `instrumentationUrl` | `${INSTRUMENTATION_URL}` |
| `thunderTokenUrl` | `${THUNDER_INTERNAL_URL}/oauth2/token` |
| `thunderJwksUrl` | `${THUNDER_INTERNAL_URL}/oauth2/jwks` |
| `thunderResolveToHost` | `${THUNDER_INTERNAL_HOST}:${THUNDER_PORT}` |
| `openChoreoApiUrl` | `${OPENCHOREO_API_URL}` |

The procedure keeps the existing issuer, signing keys, users, and OpenChoreo clients. It creates these clients, together with the AMP resource servers, permission catalog, roles, and an administrators group:

| Client ID | Purpose |
|-----------|---------|
| `amp-console-client` | Console login |
| `amp-api-client` | Backend API access |
| `amp-system-client` | Thunder identity administration |
| `amp-publisher-client` | Evaluation result publishing |
| `am-observer-client` | Access to the OpenChoreo observer |
| `amctl` | CLI login |
| `am-mcp` | Agent Manager MCP access |
| `am-obs-mcp` | Observer MCP access |

It also sets the default resource server and adds the console to Thunder's CORS origins where they are missing, and it renders the identity values used in [Step 4](#step-4-install-agent-manager-core).

> **Note:** Do not install the `wso2-amp-thunder-extension` chart or apply the upstream Agent Manager Thunder bootstrap on an OpenChoreo installation. The bootstrap creates sample users and overwrites shared Thunder settings, including the CORS origins OpenChoreo relies on. Step 1 creates only the identities Agent Manager needs, including the `engineer` user type the console creates users with.

When IDENTITY.md is complete, these variables must be set in your shell, and `AMP_IDENTITY_WORK` must point at the rendered bundle:

```bash
: "${AMP_API_CLIENT_SECRET:?}" "${AMP_SYSTEM_CLIENT_SECRET:?}" \
  "${AMP_PUBLISHER_CLIENT_SECRET:?}" "${AM_OBSERVER_CLIENT_SECRET:?}" \
  "${AMP_IDENTITY_WORK:?}"
```

---

## Step 2: Prepare OpenChoreo

> **Cluster:** Control Plane, Workflow Plane, and Observability Plane

### Enable Secret Management

Agent Manager stores each agent's environment variables through the OpenChoreo secret API, which is disabled by default. Without it, every agent creation fails with `501 Secret API is disabled on this server`. Set `OPENCHOREO_VERSION` to your installed control plane chart version:

```bash
export OPENCHOREO_VERSION="1.3.0"

helm upgrade openchoreo-control-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
  --version ${OPENCHOREO_VERSION} \
  --namespace ${CONTROL_PLANE_NS} \
  --reuse-values \
  --set features.secretManagement.enabled=true

kubectl rollout status deployment/openchoreo-api -n ${CONTROL_PLANE_NS} --timeout=300s
```

### Store Agent Manager Secrets in OpenBao

Evaluation jobs, the platform build workflows, and Agent Manager read these secrets from OpenBao. Set `BAO_TOKEN` to a token that can write `secret/*`. In OpenChoreo's default development-mode OpenBao, that is `root`:

```bash
export BAO_TOKEN="root"
bao_exec() {
  kubectl exec -n openbao openbao-0 -- env BAO_TOKEN="${BAO_TOKEN}" bao "$@"
}
```

The helper runs `bao` inside the OpenBao pod, which reaches its own listener at the `BAO_ADDR` the OpenBao chart sets: `http` in development mode, or `https` with the chart's CA when TLS is enabled.

Development-mode OpenBao keeps its data in memory. When its pod restarts, the entries below are lost and evaluations and builds fail to read them; run this section again after a restart.

Store the two Agent Manager client secrets generated in [Step 1](#step-1-configure-identities):

```bash
bao_exec kv put secret/amp-publisher-client-secret value="${AMP_PUBLISHER_CLIENT_SECRET}"
bao_exec kv put secret/amp-system-client-secret value="${AMP_SYSTEM_CLIENT_SECRET}"
```

The build workflows authenticate as OpenChoreo's existing `openchoreo-workload-publisher-client`, reading its secret from `secret/workflow-plane-oauth-client-secret`. Other workflows may already use that entry, so keep it if it exists. Only when it is missing, create it with the secret your Thunder registers for that client: the `clientSecret` of the workload publisher application in the Thunder values you installed OpenChoreo with. Do not copy the example value from OpenChoreo's reference files unless your Thunder uses it:

```bash
BAO_CHECK="$(bao_exec kv get -field=value secret/workflow-plane-oauth-client-secret 2>&1 >/dev/null)" && BAO_RC=0 || BAO_RC=$?
if [ "${BAO_RC}" -eq 0 ]; then
  echo "Keeping the existing secret/workflow-plane-oauth-client-secret"
elif printf '%s' "${BAO_CHECK}" | grep -q 'No value found at'; then
  : "${WORKLOAD_PUBLISHER_CLIENT_SECRET:?Set to the client secret Thunder registers for openchoreo-workload-publisher-client}"
  bao_exec kv put secret/workflow-plane-oauth-client-secret value="${WORKLOAD_PUBLISHER_CLIENT_SECRET}"
else
  echo "Could not read secret/workflow-plane-oauth-client-secret; nothing was written:" >&2
  echo "${BAO_CHECK}" >&2
fi
```

`bao` returns the same exit code for a missing entry, a denied token, and an unreachable server, so the block writes only when OpenBao reports `No value found at`. For any other error it prints the message and changes nothing; fix the token or connection and run it again.

If the stored value does not match Thunder, agent builds fail at the workload-publish step with `Failed to get access token`.

Create the Secret holding the OpenBao token Agent Manager uses. Development-mode OpenBao accepts `root`. For a sealed, production OpenBao, mint a periodic token with the `openchoreo-secret-writer-policy` instead, and renew it before its period lapses:

```bash
# Production only: replaces the development-mode token
# export AMP_BAO_TOKEN=$(bao_exec token create -policy=openchoreo-secret-writer-policy -period=768h -field=token)
export AMP_BAO_TOKEN="${AMP_BAO_TOKEN:-root}"

kubectl create namespace ${AMP_NS} --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic amp-openbao-token -n ${AMP_NS} \
  --from-literal=openbao-token="${AMP_BAO_TOKEN}" \
  --from-literal=workflow-plane-openbao-token="${AMP_BAO_TOKEN}"
```

#### Using a secret store other than OpenBao

The commands above write to OpenBao, the secret store OpenChoreo installs by default. If your `default` `ClusterSecretStore` uses another backend, create the same entries there with that store's own tools, under the same names and with the secret in a `value` field:

| Entry | Value |
|---|---|
| `amp-publisher-client-secret` | `${AMP_PUBLISHER_CLIENT_SECRET}` |
| `amp-system-client-secret` | `${AMP_SYSTEM_CLIENT_SECRET}` |
| `workflow-plane-oauth-client-secret` | Only if it is missing: the secret Thunder registers for `openchoreo-workload-publisher-client` |

Build and evaluation workflows read these through External Secrets, so any provider that External Secrets supports works for them. The Agent Manager API itself also reads and writes Git credentials and agent secrets over the Vault KV v2 API, so it still needs OpenBao or another Vault-compatible store, such as HashiCorp Vault. For a store at a different address, set `agentManagerService.config.openbao.url` and `agentManagerService.config.workflowPlaneOpenbao.url` in [Step 4](#step-4-install-agent-manager-core), and put a token for that store in the `amp-openbao-token` Secret.

### Configure Trace Ingestion

Agent Manager needs two additions to the tracing module's OpenTelemetry Collector: the OTLP HTTP receiver must keep request metadata, and a `resource/amp` processor copies the `x-user-*` headers set by the Agent Manager gateway into `openchoreo.dev/*` resource attributes. Spans without those headers are left unchanged.

Do not replace the collector configuration. Build a merged copy from the live one instead: [`scripts/merge-collector-config.py`](scripts/merge-collector-config.py) keeps every existing receiver (including OTLP gRPC on port `4317`), processor (such as `k8sattributes` and tail sampling), exporter, and customized value, and adds only the two changes. Run it from the [module tools](#download-the-module-tools) folder, with the virtual environment from [Step 1](#step-1-configure-identities):

```bash
kubectl get configmap opentelemetry-collector -n ${OBSERVABILITY_NS} -o yaml \
  | .venv/bin/python scripts/merge-collector-config.py \
  | kubectl apply -f -

# Review the merged pipeline before switching to it
kubectl get configmap amp-opentelemetry-collector-config -n ${OBSERVABILITY_NS} \
  -o jsonpath='{.data.relay}'
```

In the review output, confirm that the `otlp` receiver still has `grpc` on `0.0.0.0:4317`, that `http` now has `include_metadata: true`, and that the traces pipeline lists `resource/amp` right after `k8sattributes` (with `k8sattributes, resource/amp, tail_sampling` for the module defaults).

`opentelemetry-collector` is the tracing module's default `opentelemetry-collector.configMap.existingName`; use your value if you changed it. Then point the tracing module at the merged copy. Set `TRACING_MODULE_VERSION` to the installed module version shown by `helm list -n ${OBSERVABILITY_NS}`, and use your release name if it differs:

```bash
export TRACING_MODULE_VERSION="0.6.0"

# Stops here if the merged ConfigMap was not created by the previous block
kubectl get configmap amp-opentelemetry-collector-config -n ${OBSERVABILITY_NS} -o name

helm upgrade observability-traces-opensearch \
  oci://ghcr.io/openchoreo/helm-charts/observability-tracing-opensearch \
  --version ${TRACING_MODULE_VERSION} \
  --namespace ${OBSERVABILITY_NS} \
  --reuse-values \
  --set opentelemetry-collector.configMap.existingName="amp-opentelemetry-collector-config"

# Load the merged configuration. The chart does not track the content of an
# existing ConfigMap, so a later merge would not restart the collector by itself.
kubectl rollout restart deployment/opentelemetry-collector -n ${OBSERVABILITY_NS}
```

Verify that the collector restarted with the merged configuration:

```bash
kubectl rollout status deployment/opentelemetry-collector -n ${OBSERVABILITY_NS} --timeout=300s

# Expect: opentelemetry-collector-configmap=amp-opentelemetry-collector-config
kubectl get deployment opentelemetry-collector -n ${OBSERVABILITY_NS} \
  -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}={.configMap.name}{"\n"}{end}' | grep configmap

# Expect: "Starting GRPC server", "Starting HTTP server", and "Everything is ready"
kubectl logs deployment/opentelemetry-collector -n ${OBSERVABILITY_NS} --tail=200 \
  | grep -E 'Starting GRPC server|Starting HTTP server|Everything is ready'
```

If the rollout does not finish and the new pod stays in `ContainerCreating` with a `FailedMount` event, the merged ConfigMap does not exist. The previous collector pod keeps running meanwhile. Run the merge block above; the new pod then starts on its own.

The tracing module samples traces at the collector, with a rate limit of 10 spans per second shared by all agents. One agent request produces many spans (the agent run, each model call, each tool call, and the MCP sessions around them), so under that default whole traces are dropped without an error; tool-heavy requests are the first to go. The collector counts the drops in `otelcol_processor_tail_sampling_count_traces_sampled{sampled="false"}` on its metrics port, 8888. Raise the limit to your expected span rate in the tracing module, then repeat the merge, the `helm upgrade`, and the restart above:

```bash
helm upgrade observability-traces-opensearch \
  oci://ghcr.io/openchoreo/helm-charts/observability-tracing-opensearch \
  --version ${TRACING_MODULE_VERSION} \
  --namespace ${OBSERVABILITY_NS} \
  --reuse-values \
  --set opentelemetryCollectorCustomizations.tailSampling.spansPerSecond=500
```

The module's own ConfigMap is left in place. After you upgrade the tracing module, repeat the merge, the `helm upgrade`, and the restart so the merged copy picks up the module's changes. Whenever you change the merged ConfigMap, restart the collector; it does not reload the file on its own.

---

## Step 3: Install Gateway Operator

> **Cluster:** Data Plane

The WSO2 API Platform Gateway Operator manages the API Platform Gateway that fronts deployed agents and secures trace ingestion.

The gateway controller encrypts stored credentials at rest and will not start without a key. The Secret key name must be exactly `default-aesgcm256-v1.bin`. Store the key with your other platform secrets; losing it means the stored entries cannot be decrypted:

```bash
openssl rand 32 > gateway-aesgcm.key
kubectl create secret generic gateway-encryption-keys \
  --namespace ${DATA_PLANE_NS} \
  --from-file=default-aesgcm256-v1.bin=gateway-aesgcm.key
rm -f gateway-aesgcm.key
```

> **If you already have the WSO2 API Platform Gateway Operator installed** (for example from the `gateway-wso2-api-platform` community module), check that it is version `0.11.0` and pins the gateway chart and images shown below before reusing it:
> ```bash
> helm list -n ${DATA_PLANE_NS} | grep operator
> ```

Install the operator. Pin the gateway chart and the images explicitly: the `1.2.2` chart defaults to `1.2.0` images, and the `1.2.1` images are published without a matching chart:

```bash
helm install gateway-operator \
  oci://ghcr.io/wso2/api-platform/helm-charts/gateway-operator \
  --version 0.11.0 \
  --namespace ${DATA_PLANE_NS} \
  --set logging.level=info \
  --set gatewayApi.installStandardCRDs=false \
  --set gateway.helm.chartVersion=1.2.2 \
  --set gateway.values.gateway.controller.image.repository=ghcr.io/wso2/api-platform/gateway-controller \
  --set gateway.values.gateway.controller.image.tag=1.2.1 \
  --set gateway.values.gateway.gatewayRuntime.image.repository=ghcr.io/wso2/api-platform/gateway-runtime \
  --set gateway.values.gateway.gatewayRuntime.image.tag=1.2.1 \
  --set gateway.values.gateway.controller.encryptionKeys.enabled=true \
  --set gateway.values.gateway.controller.encryptionKeys.secretName=gateway-encryption-keys \
  --timeout 600s

kubectl wait --for=condition=Available deployment \
  -l app.kubernetes.io/name=gateway-operator \
  -n ${DATA_PLANE_NS} --timeout=300s
```

### Grant RBAC to the Data Plane Service Account

The OpenChoreo data plane service account needs permission to manage WSO2 API Platform CRDs:

```bash
kubectl apply -f ${MODULE_RAW}/resources/rbac.yaml
```

---

## Step 4: Install Agent Manager Core

> **Cluster:** Control Plane

Installs the Agent Manager API (`amp-api`), the Agent Manager Console (`amp-console`), and PostgreSQL. The console and API are exposed through the OpenChoreo control plane gateway at `${AMP_CONSOLE_HOST}` and `${AMP_API_HOST}`.

Download the deployment values:

```bash
curl -sOL ${MODULE_RAW}/values/agent-manager.yaml
```

The file runs one API replica with autoscaling off and two console replicas, and references the `amp-openbao-token` Secret from [Step 2](#store-agent-manager-secrets-in-openbao). Each API replica caches the policy manifest that gateways push in its own memory, so a second replica that never received a push rejects MCP OAuth security with `gateway "…" does not support mcp-auth/mcp-authz v1 policies required for Agent Identity security`. To run more API replicas, provide a Redis instance and add `--set agentManagerService.config.gatewayManifestCache.backend=redis`, `--set agentManagerService.config.gatewayManifestCache.redis.host=<redis-host>`, and the password through `gatewayManifestCache.redis.existingSecret`, then raise `agentManagerService.replicaCount` or re-enable autoscaling. By default the chart also deploys an in-cluster PostgreSQL with a default password. For production, create a managed database and a credentials Secret, and uncomment the `postgresql` block in `agent-manager.yaml`. Skip this for an evaluation install that uses the in-cluster database:

```bash
# Production only: an external database
kubectl create secret generic amp-db-credentials \
  --namespace ${AMP_NS} \
  --from-literal=password='<AMP_DB_PASSWORD>'
```

Install the chart with the deployment values followed by the identity values rendered in [Step 1](#step-1-configure-identities). The later file wins, so the rendered identity settings take precedence:

```bash
helm install amp \
  oci://${HELM_CHART_REGISTRY}/wso2-agent-manager \
  --version ${AMP_VERSION} \
  --namespace ${AMP_NS} \
  --create-namespace \
  --values agent-manager.yaml \
  --values "${AMP_IDENTITY_WORK}/rendered/agent-manager.yaml" \
  --set agentManagerService.config.agentsBaseDomain="${DP_DOMAIN}" \
  --set-string agentManagerService.config.agentsHttpPort="${AGENTS_HTTP_PORT}" \
  --set-string agentManagerService.config.agentsHttpsPort="${AGENTS_HTTPS_PORT}" \
  --set agentManagerService.config.idpHostBaseDomain="${CP_BASE_DOMAIN}" \
  --set console.config.idpHostBaseDomain="${CP_BASE_DOMAIN}" \
  --timeout 1800s

kubectl wait --for=condition=Available deployment/amp-api \
  -n ${AMP_NS} --timeout=600s
kubectl wait --for=condition=Available deployment/amp-console \
  -n ${AMP_NS} --timeout=600s
```

The ports must be passed with `--set-string`: the chart schema types them as strings. `idpHostBaseDomain` makes the API and console build each environment's identity URL as `https://<handle>.${CP_BASE_DOMAIN}`, which the control plane wildcard certificate covers.

Verify the installation. The chart publishes the console and API on the control plane gateway through two HTTPRoutes:

```bash
# Expect amp-api, amp-console, and (with the in-cluster database) amp-postgresql-0 Running
kubectl get pods -n ${AMP_NS}

# Expect both routes Accepted=True
kubectl get httproute amp-console amp-api -n ${CONTROL_PLANE_NS} \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.status.parents[0].conditions[?(@.type=="Accepted")].status}{"\n"}{end}'

# Expect HTTP 200 from the console
curl -s -o /dev/null -w '%{http_code}\n' "${AMP_CONSOLE_URL}/"

# Expect JSON whose "resource" is ${AMP_API_URL}
curl -s "${AMP_API_URL}/.well-known/oauth-protected-resource"
```

The last command confirms that the API is reachable on its public URL and advertises the public URL it was configured with.

---

## Step 5: Install Agent Sandbox

> **Cluster:** Data Plane

Agents run as sandboxed pods managed by the [Agent Sandbox](https://agent-sandbox.sigs.k8s.io/) controller instead of plain Deployments. This module is required: without it, agent deployments cannot be rendered. It is the [`agent-sandbox`](../agent-sandbox/README.md) community module.

```bash
helm upgrade --install agent-sandbox \
  oci://ghcr.io/openchoreo/helm-charts/agent-sandbox \
  --version 0.1.1 \
  --namespace ${DATA_PLANE_NS} \
  --wait \
  --timeout 10m \
  --set namespace=${CONTROL_PLANE_NS} \
  --set dataPlaneNamespace=${DATA_PLANE_NS} \
  --set dataPlaneServiceAccount=cluster-agent-dataplane \
  --set upstream.version=v0.4.6

kubectl wait -n agent-sandbox-system \
  --for=condition=available --timeout=180s \
  deployment/agent-sandbox-controller
```

To show sandboxes and their pods in the OpenChoreo release resource tree, add the rules described in the [agent-sandbox module](../agent-sandbox/README.md#release-resource-tree).

---

## Step 6: Install Platform Resources

> **Cluster:** Control Plane

Creates the Agent Manager component types, traits, build workflows, and workflow templates, the `default` Project, Environment, and DeploymentPipeline the console needs on first login, and the OpenChoreo authorization bindings for `amp-api-client`, `am-observer-client`, and the workload publisher. Confirm the [resource conflict check](#resource-conflicts) passes first.

The chart defaults point at a local k3d cluster. These values point the build workflows at OpenChoreo's Thunder and API, the traits at the namespace the gateway is installed in ([Step 9](#step-9-install-api-platform-gateway-extension)), and the default Environment at the data plane domain:

```bash
helm install amp-platform-resources \
  oci://${HELM_CHART_REGISTRY}/wso2-amp-platform-resources-extension \
  --version ${AMP_VERSION} \
  --namespace ${DEFAULT_NS} \
  --set global.oauth.tokenUrl="${THUNDER_INTERNAL_URL}/oauth2/token" \
  --set global.oauth.hostHeader="${THUNDER_INTERNAL_HOST}" \
  --set global.apiServer.url="${OPENCHOREO_API_URL}" \
  --set global.apiServer.hostHeader="${OPENCHOREO_API_HOST}" \
  --set global.registry.endpoint="${REGISTRY_ENDPOINT}" \
  --set global.defaultResources.registry.tlsVerify=true \
  --set apiPlatformGateway.namespace=${DATA_PLANE_NS} \
  --set environment.gateway.http.host="${DP_DOMAIN}" \
  --set environment.gateway.http.port=${AGENTS_HTTP_PORT} \
  --set environment.gateway.https.host="${DP_DOMAIN}" \
  --set environment.gateway.https.port=${AGENTS_HTTPS_PORT} \
  --timeout 1800s
```

The Environment's gateway binding replaces the data plane's rather than merging with it, so set both variants, each on the port its listener serves. Putting the HTTPS port on the `http` variant makes the console publish `http://<host>:443`, which a browser blocks as mixed content.

`global.defaultResources.registry.tlsVerify=true` makes build pushes use HTTPS and verify the registry's certificate. Set it to `false` only for a registry served over plain HTTP, such as a local evaluation registry; with `true`, pushes to such a registry fail in the `publish-image` step with `server gave HTTP response to HTTPS client`.

If the registry's certificate is signed by a private CA, two components must trust that CA, or builds fail with `x509: certificate signed by unknown authority`:

- **Build pods**, which push with Podman. Podman reads extra CAs from `/etc/containers/certs.d/<registry-host:port>/ca.crt`. Mount the CA there for workflow pods, for example through the workflow plane's Argo `workflowDefaults`.
- **Every node's container runtime**, which pulls the agent images. Configure the CA for the registry host in the runtime's registry configuration, for example `registries.yaml` on k3s.

Build pushes read registry credentials from the OpenBao key `registry-push-secret`, through the `default` ClusterSecretStore. Each build run copies them into its own `<run>-registry-push-secret` Secret, and pushes unauthenticated when the key is absent; a Kubernetes Secret named `registry-push-secret` is not used. See [OpenChoreo's registry guide](https://openchoreo.dev/docs/platform-engineer-guide/container-registry-configuration/#registry-providers) for provider-specific authentication.

---

## Step 7: Install Observability Extension

> **Cluster:** Observability Plane

Deploys the Agent Manager Observer, which serves trace, log, and metrics data from OpenSearch to the console and CLI. It is exposed through the observability plane gateway at `${AMP_OBSERVER_HOST}`.

Download `values/observability-extension.yaml`, which sets the replica count. The command points the observer at OpenChoreo's Thunder:

```bash
curl -sOL ${MODULE_RAW}/values/observability-extension.yaml

helm install amp-observability-traces \
  oci://${HELM_CHART_REGISTRY}/wso2-amp-observability-extension \
  --version ${AMP_VERSION} \
  --namespace ${OBSERVABILITY_NS} \
  --values observability-extension.yaml \
  --set amObserver.ocIngress.hostname="${AMP_OBSERVER_HOST}" \
  --set amObserver.publicUrl="${AMP_OBSERVER_URL}" \
  --set amObserver.auth.issuer="${THUNDER_PUBLIC_URL}" \
  --set amObserver.observer.idpClientSecret="${AM_OBSERVER_CLIENT_SECRET}" \
  --set amObserver.observer.idpTokenUrl="${THUNDER_INTERNAL_URL}/oauth2/token" \
  --set amObserver.auth.jwksUrl="${THUNDER_INTERNAL_URL}/oauth2/jwks" \
  --timeout 1800s

kubectl wait --for=condition=Available deployment/amp-observer \
  -n ${OBSERVABILITY_NS} --timeout=600s
```

`amObserver.auth.issuer` must be the public Thunder URL, the same issuer the API validates. With any other value the traces page stays empty and the observer logs `JWT validation failed ... invalid issuer`. To keep the client secret out of Helm release history, use `amObserver.observer.existingSecret` instead.

OpenChoreo restricts ingress in the observability plane namespace to its own pods, and two Agent Manager callers dial the observer directly: the Agent Manager API, for build and monitor run logs, and evaluation jobs, for the traces they score. Allow both, or the console shows `Failed to retrieve logs` and monitor runs fail with `Connection refused` to `amp-observer...:9098`:

```bash
kubectl apply -n ${OBSERVABILITY_NS} -f ${MODULE_RAW}/resources/amp-observer-ingress.yaml
```

The policy admits only the Agent Manager API pods in `wso2-amp` and evaluation job pods in `workflows-default`. If you use a different `${AMP_NS}`, or an organization namespace other than `default`, edit the matching `kubernetes.io/metadata.name` value (`workflows-<namespace>` for evaluation jobs).

---

## Step 8: Install Evaluation Extension

> **Cluster:** Workflow Plane

Installs workflow templates for running automated evaluations against agent traces. Evaluation jobs publish scores as `amp-publisher-client`, reading its secret from OpenBao at `secret/amp-publisher-client-secret` ([Step 2](#store-agent-manager-secrets-in-openbao)).

The chart defaults point the publisher at a Thunder instance that does not exist here, and its NetworkPolicy only allows egress to that instance's namespace. Point both at OpenChoreo's Thunder. The NetworkPolicy port is the Thunder pod's port:

```bash
helm install amp-evaluation-extension \
  oci://${HELM_CHART_REGISTRY}/wso2-amp-evaluation-extension \
  --version ${AMP_VERSION} \
  --namespace ${WORKFLOW_NS} \
  --set global.registry.endpoint="${REGISTRY_ENDPOINT}" \
  --set ampEvaluation.publisher.idpTokenUrl="${THUNDER_INTERNAL_URL}/oauth2/token" \
  --set networkPolicy.evaluationJob.idp.namespace="${THUNDER_NAMESPACE}" \
  --set "networkPolicy.evaluationJob.idp.ports[0]=${THUNDER_PORT}" \
  --timeout 1800s
```

Evaluation jobs fetch traces from the observer directly. They need the observer ingress policy from [Step 7](#step-7-install-observability-extension), or every monitor run fails with `Connection refused` to `amp-observer...:9098`.

Monitors read traces through the tracing module's adapter, whose default memory limit is 128 MiB. A monitor over a past time window loads many agent traces at once, including their prompts and responses, and the adapter is killed (`OOMKilled`). The run then fails with `Failed to fetch traces: HTTP 500`, while monitors on future windows, which read small batches, keep working. Raise the adapter's limit in the tracing module:

```bash
helm upgrade observability-traces-opensearch \
  oci://ghcr.io/openchoreo/helm-charts/observability-tracing-opensearch \
  --version ${TRACING_MODULE_VERSION} \
  --namespace ${OBSERVABILITY_NS} \
  --reuse-values \
  --set adapter.resources.limits.memory=512Mi \
  --set adapter.resources.limits.cpu=500m
```

The job's NetworkPolicy allows egress to the Kubernetes API server by address range, defaulting to all of RFC 1918. If `kubectl -n default get endpoints kubernetes` shows a public address or one in `100.64.0.0/10`, add `--set "networkPolicy.evaluationJob.apiServer.cidrs[0]=<control-plane-subnet>"`, or every evaluation publishes its scores and then reports `FAILED`.

---

## Step 9: Install API Platform Gateway Extension

> **Cluster:** Data Plane

Each environment gets its own API Platform Gateway, registered with Agent Manager. It serves the environment's deployed agents at `https://<env>-<org>.${DP_DOMAIN}` (for the default environment and organization, `${AMP_GATEWAY_HOST}`), and the default environment's gateway carries the OTLP trace-ingest route at `${INSTRUMENTATION_URL}`. This step prepares what every gateway needs; [Step 10](#step-10-configure-the-environments) installs the gateways, after the Agent Manager API is running.

The bootstrap job authenticates as `amp-api-client`. Store its credentials in a Secret so they stay out of Helm release history:

```bash
kubectl create secret generic gateway-idp-credentials \
  --namespace ${DATA_PLANE_NS} \
  --from-literal=client-id=amp-api-client \
  --from-literal=client-secret="${AMP_API_CLIENT_SECRET}"
```

Agent sandboxes and evaluation jobs reach gateway runtimes only in namespaces labelled as API Platform Gateway namespaces. Label the data plane namespace, which holds the gateway of every environment:

```bash
kubectl label namespace ${DATA_PLANE_NS} amp.wso2.com/api-platform-gateway=true --overwrite
```

Step 10 installs each gateway from `values/api-platform-gateway-extension.yaml` in the [module tools](#download-the-module-tools) folder. Its address, `gateway.vhost`, is written into Agent Manager at first registration only; a later `helm upgrade` does not change it. `gateway.hostname` sets the host of the gateway's route and follows upgrades.

Agent Manager builds the MCP proxy URLs it injects into agents from `gateway.vhost`. Each URL also serves as the MCP server's OAuth resource identifier, so agents must call it at that exact address, from inside the cluster. Pods must therefore resolve `${AMP_GATEWAY_HOST}` and reach the gateway's HTTPS listener at that address. Otherwise MCP tools fail to load with `Name or service not known` and the agent answers without them. Platform-managed LLM proxies use a separate path: Agent Manager injects the gateway's in-cluster `runtimeUrl` on port 22893, which the sandbox network policy allows to the namespace labelled above, so the requirements in this and the next paragraph do not apply to them.

The agent sandbox's network policy, which the `agent-api` component type defines, allows ports 443 and 80 only to public addresses: it excludes `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, and `169.254.0.0/16`. If `${AMP_GATEWAY_HOST}` resolves to a private address, as an internal load balancer often does on premises, agents cannot reach it and MCP tools fail with `All connection attempts failed`. Agent Manager v1.0.0 does not make this policy configurable; give the data plane gateway an address outside those ranges, or expect agents to run without gateway-managed MCP proxies. Managed LLM proxies are not affected. Agents must also trust the certificate the gateway presents at that address, so use one from a publicly trusted CA.

---

## Step 10: Configure the Environments

> **Cluster:** Control Plane and Data Plane

Agent Manager lists every OpenChoreo environment in `${DEFAULT_NS}`: the `default` environment that [Step 6](#step-6-install-platform-resources) created, and any environment that already existed in OpenChoreo. Before agents can run in an environment, it needs two things:

- **An environment Thunder**, which issues each agent its OAuth2 credential (AgentID) and the tokens agents use for OAuth-protected MCP servers. It is separate from OpenChoreo's Thunder, which handles console and API sign-in. Without it, agents never get an AgentID and Agent Manager keeps retrying in the background.
- **An API Platform Gateway** registered for the environment, which serves its agents and their MCP and LLM proxies, with that environment Thunder as its key manager and identity provider.

[`scripts/configure-environments.sh`](scripts/configure-environments.sh) gives every environment both, in that order. It skips whatever is already in place, so it is safe to re-run, for example after you create another environment. An environment that existed before Agent Manager keeps its own settings and gets the label `amp.wso2.com/adopted=true`, so [uninstallation](#uninstallation) removes only its Thunder and gateway and keeps the environment.

The environment Thunders are served the same way as OpenChoreo's Thunder, over HTTPS when `THUNDER_PUBLIC_URL` uses it, and trust the CA in `OPENCHOREO_CA_FILE` from [Trust the Gateway CA](#trust-the-gateway-ca), which [Step 2](#step-2-prepare-openchoreo) and the script's own `curl` calls also use. The script reads the `amp-api-client` secret from the Secret created in [Step 9](#step-9-install-api-platform-gateway-extension).

> **Note:** The environment Thunder only trusts a platform issuer whose JWKS it can fetch over HTTPS; ThunderID allows plain HTTP only for `localhost`, `127.0.0.1`, and `::1`. Otherwise the install fails in its pre-install `setup` job with `trusted_issuer.jwks_url must use https`. The issuer itself may stay HTTP. If OpenChoreo's Thunder is served over plain HTTP, enable an HTTPS listener on the control plane gateway, set `OPENCHOREO_CA_FILE` to its signing CA, and export its HTTPS JWKS URL before running the script, for example `export PLATFORM_THUNDER_JWKS_URL="https://thunder.${CP_BASE_DOMAIN}:8443/oauth2/jwks"`. The script uses `PLATFORM_THUNDER_JWKS_URL` when it is set.

Run it from the [module tools](#download-the-module-tools) folder, with the [Configuration Variables](#configuration-variables) exported. Set `ENVIRONMENTS` to a space-separated list to configure only those environments:

```bash
bash scripts/configure-environments.sh
```

For each environment it reports the Thunder and the gateway, then a summary. With only the default environment:

```text
=== Environment default ===
  Installing ThunderID amp-thunder-default-default...
  ThunderID ready at https://default-idp.openchoreo.localhost
  Installing gateway api-platform-default-default...
  Gateway ready: https://default-default.openchoreoapis.localhost

=== Summary ===
  default: ready (gateway https://default-default.openchoreoapis.localhost, ThunderID https://default-idp.openchoreo.localhost)
```

It exits with an error, and prints the end of the failing command's output, if an environment could not be completed; fix the cause and run it again. Verify the gateways and environments. Each gateway should report `Accepted=True Programmed=True`, and existing environments show `true` under `ADOPTED`:

```bash
kubectl get apigateway -n ${DATA_PLANE_NS} \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[*].status'
kubectl get environments.openchoreo.dev -n ${DEFAULT_NS} -L amp.wso2.com/adopted
```

Each environment Thunder has its own administrator, `admin`, for administering that Thunder only. Read its password with:

```bash
kubectl get secret amp-thunder-default-<env>-admin-credentials \
  -n amp-thunder-default-<env> -o jsonpath='{.data.password}' | base64 -d
```

When the script updates an existing gateway, it restarts the gateway controller, whose volume is `ReadWriteOnce`. On a multi-node cluster the new pod can stick in `ContainerCreating` with `Multi-Attach error for volume`; delete the old controller pod to release it:

```bash
kubectl get pods -n ${DATA_PLANE_NS} | grep gateway-controller
```

```bash
kubectl get pods -n ${DATA_PLANE_NS} | grep gateway-controller
```

---

## Verification

```bash
# Agent Manager core
kubectl get pods -n ${AMP_NS}

# Gateway Operator, API Platform Gateway, and its bootstrap
kubectl get pods -n ${DATA_PLANE_NS} -l app.kubernetes.io/name=gateway-operator
kubectl get apigateway api-platform-default-default -n ${DATA_PLANE_NS}
kubectl get jobs -n ${DATA_PLANE_NS} | grep api-platform-default-default-bootstrap

# Agent Sandbox
kubectl get pods -n agent-sandbox-system
kubectl get crd sandboxtemplates.extensions.agents.x-k8s.io \
  sandboxwarmpools.extensions.agents.x-k8s.io sandboxclaims.extensions.agents.x-k8s.io

# Platform resources
kubectl get environment,deploymentpipeline,project -n ${DEFAULT_NS}
kubectl get clusterauthzrolebinding amp-api-client-binding amp-observer-reader-binding amp-workload-deployer-binding

# Observability extension
kubectl get deployment amp-observer -n ${OBSERVABILITY_NS}

# Environment Thunder
kubectl get pods -n amp-thunder-default-default

# Helm releases
helm list -A | grep -E 'amp|gateway|agent-sandbox'
```

The `APIGateway` should report `Programmed`, and the bootstrap job `Complete`. Then open the console, sign in with an existing OpenChoreo user in the AMP administrators group, and create, build, and deploy an agent.

---

## Access

| Service | URL |
|---------|-----|
| Agent Manager Console | `https://${AMP_CONSOLE_HOST}` |
| Agent Manager API | `https://${AMP_API_HOST}` |
| Agent Manager Observer | `https://${AMP_OBSERVER_HOST}` |
| Deployed agents | `https://<env>-<org>.${DP_DOMAIN}`, for example `https://${AMP_GATEWAY_HOST}` |
| OTLP trace ingest | `${INSTRUMENTATION_URL}` |

Print the addresses and the console sign-in accounts. Sign in with a user from `AMP_ADMIN_USER_IDS`, the members of the AMP administrators group that [Step 1](#step-1-configure-identities) created. On OpenChoreo's reference installation these are its sample users, whose passwords are in the Thunder release values; for any other user, use that user's OpenChoreo password. Run it from the [module tools](#download-the-module-tools) folder, which has the virtual environment:

```bash
echo "Console:  ${AMP_CONSOLE_URL}"
echo "API:      ${AMP_API_URL}"
echo "Observer: ${AMP_OBSERVER_URL}"
echo "Agents:   https://${AMP_GATEWAY_HOST}"
echo "Sign in to the console as:"
helm get values thunder -n ${THUNDER_NAMESPACE} -a -o json \
  | AMP_ADMIN_USER_IDS="${AMP_ADMIN_USER_IDS}" .venv/bin/python -c '
import json, os, sys, yaml
admins = os.environ["AMP_ADMIN_USER_IDS"].replace(",", " ").split()
users = {}
for name, script in ((json.load(sys.stdin).get("bootstrap") or {}).get("scripts") or {}).items():
    if name.endswith((".yaml", ".yml")):
        for doc in yaml.safe_load_all(script):
            if isinstance(doc, dict) and doc.get("resource_type") == "user":
                users[doc.get("id")] = doc
for user_id in admins:
    user = users.get(user_id)
    if user:
        print("  ", user["attributes"].get("username"), "/", (user.get("credentials") or {}).get("password"))
    else:
        print("  ", user_id, "is not in the Thunder bootstrap values; use the OpenChoreo password of that user")'
```

The sample passwords are for evaluation; change them before you share the installation. The environment Thunder's own administrator, `admin`, is only for administering that Thunder; [Step 10](#step-10-configure-the-environments) shows how to read its password.

---

## Adding Environments

To add an environment, create it in OpenChoreo, then re-run [Step 10](#step-10-configure-the-environments) for it. Do not use the command that the Console's **Create Environment** generates on this setup: it installs the environment's gateway in another namespace and without the identity settings this module uses.

Create the environment in `${DEFAULT_NS}`, on the data plane that Step 10's gateways serve:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: openchoreo.dev/v1alpha1
kind: Environment
metadata:
  name: staging
  namespace: ${DEFAULT_NS}
  annotations:
    openchoreo.dev/display-name: Staging
spec:
  dataPlaneRef:
    kind: ClusterDataPlane
    name: default
  isProduction: false
EOF
```

Then give it a Thunder and a gateway:

```bash
ENVIRONMENTS=staging bash scripts/configure-environments.sh
```

**Then add the environment to a deployment pipeline.** An agent's Deploy page shows only the environments in its project's pipeline, and creating an environment does not add it to one. The `default` pipeline contains only the `default` environment. It is managed by the `amp-platform-resources` Helm release, so a later `helm upgrade` of that release resets it; create a separate pipeline instead:

1. In the Console, open **Deployment Pipelines** (organization level, **INFRASTRUCTURE**) and click **Create Pipeline**.
2. Add the environments in promotion order, for example **Default → Staging**, and click **Create**.
3. Open **Projects**, choose **Edit** on the project, select the new pipeline under **Deployment Pipeline**, and click **Update Project**.

Agents in the project can then be promoted from the first environment to the next.

---

## Uninstallation

`scripts/uninstall.sh` removes everything this module installs on top of OpenChoreo, in the reverse order of the installation steps. OpenChoreo, its Thunder, OpenBao, and the observability modules are kept, as are OpenChoreo projects, environments, and pipelines that Agent Manager did not create. Every step skips what is already gone, and a removal that fails is reported and skipped, so you can re-run the script after fixing the cause.

| Step | What it removes |
|---|---|
| 1 | Through the Agent Manager API, while it is still running: all agents and the projects that held them, the environments added through Agent Manager's own environment script with their environment Thunder and gateway, and the pipelines that reference only Agent Manager environments. It returns the `default` pipeline to the `default` environment only, because an environment that a pipeline references cannot be deleted. Environments labelled `amp.wso2.com/adopted=true` by [Step 10](#step-10-configure-the-environments), other projects, and pipelines of only those environments are kept |
| 2 | The environment Thunder and gateway of the `default` environment and of each adopted environment, the `gateway-idp-credentials` Secret, and the gateway namespace label. Adopted environments themselves are kept, without the label |
| 3 | The evaluation, observability, platform resources, and core releases, the `${AMP_NS}` namespace, and the observer ingress policy. Agent Sandbox, including the upstream controller, RBAC, and CRDs that its chart applies outside Helm, and the Gateway Operator with its CRDs. Each is kept while resources of its types remain after Agent Manager's own are gone, because deleting a CRD deletes every resource of that type. Also what `helm uninstall` leaves behind: the `amp-monitor-evaluation` workflow template, each removed gateway's bootstrap Job and RBAC, registration token Secret, and controller TLS Secret, the monitor runs, the workflow-plane objects (Argo workflows, ExternalSecrets, Secrets) that deleted build and monitor runs leave behind, and the OpenChoreo access Agent Manager grants its runtime clients |
| 4 | Points the tracing module back at its own collector configuration and, once that succeeds, deletes the merged copy, and deletes the two Agent Manager client secrets from OpenBao. `secret/workflow-plane-oauth-client-secret` is kept for OpenChoreo's builds. Also the secrets Agent Manager stored through OpenChoreo's secret management (agent API keys and identities, agent environment variables, MCP and LLM proxy keys, monitor credentials), with their SecretReferences, PushSecrets, and OpenBao keys. They are recognized by Agent Manager's label and naming, including names that start with an agent's name |
| 5 | The Agent Manager identities and shared-setting changes in OpenChoreo's Thunder, with the `remove` command from [IDENTITY.md](IDENTITY.md#remove-the-identities). A new installation requires this: the Step 1 import refuses to overwrite existing identities |

Run it from the [module tools](#download-the-module-tools) folder, with the [Configuration Variables](#configuration-variables) exported. For step 5, also export the identity configuration from [IDENTITY.md](IDENTITY.md#2-prepare-the-configuration-and-client-secrets) and the secret of OpenChoreo's `openchoreo-system-app` client, which the script uses to request a Thunder administration token. Without them it skips step 5 and tells you so:

```bash
export AMP_IDENTITY_CONFIG="${AMP_IDENTITY_WORK}/configuration.yaml"
export OPENCHOREO_SYSTEM_APP_SECRET="$(helm get values thunder -n "${THUNDER_NAMESPACE}" -a -o json | python3 -c '
import json, re, sys
scripts = (json.load(sys.stdin).get("bootstrap") or {}).get("scripts") or {}
for text in scripts.values():
    m = re.search(r"clientId:\s*openchoreo-system-app\s*\n\s*clientSecret:\s*\"?([^\s\"]+)", text)
    if m:
        print(m.group(1)); break
else:
    sys.exit("openchoreo-system-app is not in the Thunder bootstrap values; set OPENCHOREO_SYSTEM_APP_SECRET by hand")')"
```

The second command reads the secret from the Thunder release, as in [IDENTITY.md](IDENTITY.md#1-collect-the-existing-identity-configuration).

The script reads the Agent Manager client secret from the cluster when `AMP_API_CLIENT_SECRET` is not set, and uses `BAO_TOKEN` (default `root`) for OpenBao. Agent Sandbox and the Gateway Operator may be shared with other modules; set `KEEP_AGENT_SANDBOX=true` or `KEEP_GATEWAY_OPERATOR=true` to keep them even when nothing else uses them. Run the script and type `uninstall` when asked, or pass `--yes`:

```bash
bash scripts/uninstall.sh
```

It ends by listing any Agent Manager Helm releases or namespaces that remain. Expect `None. Agent Manager is removed.`

---

## Compatibility

> **Note:** The Helm chart versions specified in the installation commands above are for the latest Agent Manager release compatible with this module. Refer to the compatibility table below to determine the appropriate versions for your OpenChoreo installation.

| Agent Manager Version | OpenChoreo Version | Thunder Version |
| --------------------- | ------------------ | --------------- |
| v1.0.x                | v1.3.x             | ThunderID 1.0.x |

OpenChoreo v1.2.x ships Thunder 0.28.0, which Agent Manager v1.0.0 does not support. See [IDENTITY.md](IDENTITY.md#compatibility) for details.
