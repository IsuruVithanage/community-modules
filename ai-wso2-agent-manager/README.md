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
- [Step 8: Install Evaluation Extension (Optional)](#step-8-install-evaluation-extension-optional)
- [Step 9: Install API Platform Gateway Extension](#step-9-install-api-platform-gateway-extension)
- [Step 10: Provision the Environment Identity Provider](#step-10-provision-the-environment-identity-provider)
- [Adding Environments](#adding-environments)
- [Verification](#verification)
- [Access](#access)
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
│   OpenChoreo Thunder                        │   │   + API Platform Gateway         (Step 9)  │
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
| Environment Thunder | Installed by `add-environment-thunder.sh` | `amp-thunder-<org>-<env>` | Yes, for agent identities |

Agent Manager charts are pulled from `oci://ghcr.io/wso2` at version `1.0.0` unless noted otherwise.

---

## Prerequisites

- OpenChoreo v1.3.x installed with the control plane, data plane, workflow plane, and observability plane running, following the [OpenChoreo installation guide](https://openchoreo.dev/docs/getting-started/try-it-out/on-your-environment/)
- ThunderID 1.0.x as OpenChoreo's identity provider. OpenChoreo v1.3.x installs ThunderID 1.0.1 as the `thunder` release in the `thunder` namespace
- OpenBao as the backend of the `default` `ClusterSecretStore`. Agent Manager reads Git credentials from OpenBao directly over the Vault API, so another External Secrets provider cannot replace it
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
export REGISTRY_ENDPOINT="registry.example.com"
```

The Thunder variables assume OpenChoreo's default release, `thunder` in the `thunder` namespace, whose values set `fullnameOverride: thunder` and so name the service `thunder-service`. Confirm the service with `kubectl get svc -n ${THUNDER_NAMESPACE}`, and adjust `THUNDER_NAMESPACE`, `THUNDER_PORT`, and `THUNDER_INTERNAL_HOST` if yours differs; every command in this guide reads them. `THUNDER_PUBLIC_URL` must match the `iss` claim in tokens Thunder issues:

```bash
kubectl run thunder-issuer --rm -i --restart=Never --image=curlimages/curl -- \
  -s "${THUNDER_INTERNAL_URL}/.well-known/openid-configuration" | grep -o '"issuer":"[^"]*"'
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

[Step 10](#step-10-provision-the-environment-identity-provider) passes the same file to the environment Thunder, so every environment trusts the same CA.

Keep this shell session for the whole installation. [Step 1](#step-1-configure-identities) also exports the client secrets used by later steps.

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

### Configure Trace Ingestion

Agent Manager needs two additions to the tracing module's OpenTelemetry Collector: the OTLP HTTP receiver must keep request metadata, and a `resource/amp` processor copies the `x-user-*` headers set by the Agent Manager gateway into `openchoreo.dev/*` resource attributes. Spans without those headers are left unchanged.

Do not replace the collector configuration. Build a merged copy from the live one instead: [`scripts/merge-collector-config.py`](scripts/merge-collector-config.py) keeps every existing receiver (including OTLP gRPC on port `4317`), processor (such as `k8sattributes` and tail sampling), exporter, and customized value, and adds only the two changes. Run it from your checkout of this module, with the virtual environment from [Step 1](#step-1-configure-identities):

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

## Step 8: Install Evaluation Extension (Optional)

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

Registers an API Platform Gateway with Agent Manager for the default organization and environment. It serves deployed agents at `https://<env>-<org>.${DP_DOMAIN}` (for the default environment and organization, `${AMP_GATEWAY_HOST}`) and carries the OTLP trace-ingest route at `${INSTRUMENTATION_URL}`. Install it last: the bootstrap job needs the Agent Manager API running.

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

Download `values/api-platform-gateway-extension.yaml` and install. `gateway.vhost` is written into Agent Manager at first registration only; a later `helm upgrade` does not change it. `gateway.hostname` sets the host of the gateway's route and follows upgrades, so keep it matching the vhost's host.

Agent Manager builds the MCP proxy URLs it injects into agents from `gateway.vhost`. Each URL also serves as the MCP server's OAuth resource identifier, so agents must call it at that exact address, from inside the cluster. Pods must therefore resolve `${AMP_GATEWAY_HOST}` and reach the gateway's HTTPS listener at that address. Otherwise MCP tools fail to load with `Name or service not known` and the agent answers without them. Platform-managed LLM proxies use a separate path: Agent Manager injects the gateway's in-cluster `runtimeUrl` on port 22893, which the sandbox network policy allows to the namespace labelled above, so the requirements in this and the next paragraph do not apply to them.

The agent sandbox's network policy, which the `agent-api` component type defines, allows ports 443 and 80 only to public addresses: it excludes `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, and `169.254.0.0/16`. If `${AMP_GATEWAY_HOST}` resolves to a private address, as an internal load balancer often does on premises, agents cannot reach it and MCP tools fail with `All connection attempts failed`. Agent Manager v1.0.0 does not make this policy configurable; give the data plane gateway an address outside those ranges, or expect agents to run without gateway-managed MCP proxies. Managed LLM proxies are not affected. Agents must also trust the certificate the gateway presents at that address, so use one from a publicly trusted CA.

Install the gateway extension:

```bash
curl -sOL ${MODULE_RAW}/values/api-platform-gateway-extension.yaml

KM=apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers
helm install api-platform-default-default \
  oci://${HELM_CHART_REGISTRY}/wso2-amp-api-platform-gateway-extension \
  --version ${AMP_VERSION} \
  --namespace ${DATA_PLANE_NS} \
  --values api-platform-gateway-extension.yaml \
  --set agentManager.idp.tokenUrl="${THUNDER_INTERNAL_URL}/oauth2/token" \
  --set gateway.vhost="https://${AMP_GATEWAY_HOST}" \
  --set gateway.hostname="${AMP_GATEWAY_HOST}" \
  --set "${KM}[0].name=agent-manager-service" \
  --set "${KM}[0].issuer=agent-manager-service" \
  --set "${KM}[0].jwks.remote.uri=http://amp-api.${AMP_NS}.svc.cluster.local:9000/auth/external/jwks.json" \
  --set "${KM}[0].jwks.remote.skipTlsVerify=true" \
  --set "${KM}[1].name=ThunderKeyManager" \
  --set "${KM}[1].issuer=${THUNDER_PUBLIC_URL}" \
  --set "${KM}[1].jwks.remote.uri=${THUNDER_INTERNAL_URL}/oauth2/jwks" \
  --set "${KM}[1].jwks.remote.skipTlsVerify=false" \
  --timeout 1800s

kubectl wait --for=condition=complete job/api-platform-default-default-bootstrap \
  -n ${DATA_PLANE_NS} --timeout=300s
```

Both key managers must be listed: `--set` on an indexed list replaces the whole list, and API-key authentication relies on the `agent-manager-service` entry. [Step 10](#step-10-provision-the-environment-identity-provider) repoints the second entry at the environment's own Thunder.

---

## Step 10: Provision the Environment Identity Provider

> **Cluster:** Control Plane and Data Plane

Every Agent Manager environment needs its own Thunder instance, which issues each agent its OAuth2 credential (AgentID). This is separate from OpenChoreo's Thunder, which handles console and API login. Without it, agents never get an AgentID and Agent Manager keeps retrying in the background.

Download the release-pinned script:

```bash
curl -fsSL "${AMP_RAW}/deployments/scripts/add-environment-thunder.sh" -o add-environment-thunder.sh
```

The environment Thunder must be served the same way as OpenChoreo's Thunder, and must trust the CA that signed OpenChoreo's Thunder certificate. Derive both settings from [Configuration Variables](#configuration-variables) and [Trust the Gateway CA](#trust-the-gateway-ca):

```bash
# HTTPS when OpenChoreo's Thunder is served over HTTPS
if [ "${THUNDER_PUBLIC_URL%%:*}" = "https" ]; then
  export ENV_THUNDER_TLS_ENABLED=true
else
  export ENV_THUNDER_TLS_ENABLED=false
fi

# Mount OpenChoreo's private CA when there is one; otherwise skip CA handling
if [ -n "${OPENCHOREO_CA_FILE}" ]; then
  export PLATFORM_THUNDER_CA_PEM="$(cat "${OPENCHOREO_CA_FILE}")" SKIP_CA_BUNDLE_TRUST=false
else
  export PLATFORM_THUNDER_CA_PEM="" SKIP_CA_BUNDLE_TRUST=true
fi
echo "TLS_ENABLED=${ENV_THUNDER_TLS_ENABLED} SKIP_CA_BUNDLE_TRUST=${SKIP_CA_BUNDLE_TRUST}"
```

With the self-signed `openchoreo-ca`, this prints `TLS_ENABLED=true SKIP_CA_BUNDLE_TRUST=false`. With a publicly trusted certificate, where `OPENCHOREO_CA_FILE` is empty, it skips the CA flow. With a plain-HTTP Thunder, it also turns TLS off. The script's own `curl` calls use `CURL_CA_BUNDLE`.

> **Note:** The environment Thunder only trusts a platform issuer whose JWKS it can fetch over HTTPS; ThunderID allows plain HTTP only for `localhost`, `127.0.0.1`, and `::1`. Otherwise the install fails in its pre-install `setup` job with `trusted_issuer.jwks_url must use https`. The issuer itself may stay HTTP. If OpenChoreo's Thunder is served over plain HTTP, enable an HTTPS listener on the control plane gateway, set `OPENCHOREO_CA_FILE` to its signing CA, and export its HTTPS JWKS URL before running the script, for example `export PLATFORM_THUNDER_JWKS_URL="https://thunder.${CP_BASE_DOMAIN}:8443/oauth2/jwks"`. The command below uses `PLATFORM_THUNDER_JWKS_URL` when it is set.

Run the script. `IDP_CLIENT_SECRET` must be the real `amp-api-client` secret; the script's default is the shipped placeholder:

```bash
ENV_NAME=default \
DISPLAY_NAME="Default" \
ORG_NAME=default \
THUNDER_HANDLE=default-idp \
WAIT_TIMEOUT=300s \
CHART_VERSION=1.0.0 \
SCRIPT_BASE_URL="${AMP_RAW}/deployments/scripts" \
AMP_API_URL="${AMP_API_URL}/api/v1" \
IDP_TOKEN_URL="${THUNDER_PUBLIC_URL}/oauth2/token" \
IDP_CLIENT_ID=amp-api-client \
IDP_CLIENT_SECRET="${AMP_API_CLIENT_SECRET}" \
AGENT_MANAGER_TOKEN="" \
PLATFORM_THUNDER_ISSUER="${THUNDER_PUBLIC_URL}" \
PLATFORM_THUNDER_JWKS_URL="${PLATFORM_THUNDER_JWKS_URL:-${THUNDER_PUBLIC_URL}/oauth2/jwks}" \
PLATFORM_THUNDER_CA_PEM="${PLATFORM_THUNDER_CA_PEM}" \
SKIP_CA_BUNDLE_TRUST="${SKIP_CA_BUNDLE_TRUST}" \
THUNDER_HOST_BASE_DOMAIN="${CP_BASE_DOMAIN}" \
TLS_ENABLED="${ENV_THUNDER_TLS_ENABLED}" \
bash add-environment-thunder.sh
```

The script prints the environment's issuer: `https://default-idp.${CP_BASE_DOMAIN}` with TLS, or `http://default-idp.${CP_BASE_DOMAIN}:8080` without. `CHART_VERSION` is the ThunderID chart and image version, not the Agent Manager version. `AGENT_MANAGER_TOKEN=""` makes it request a new token with the `IDP_*` values: it otherwise reuses an exported `AGENT_MANAGER_TOKEN`, and a token from an earlier session fails with `Could not register the thunder url handle in agent-manager-service (HTTP 401)`. It is safe to re-run; the system-client secret and admin password are reused, never rotated. Retrieve the environment Thunder's admin password with:

```bash
kubectl get secret amp-thunder-default-default-admin-credentials \
  -n amp-thunder-default-default -o jsonpath='{.data.password}' | base64 -d
```

### Point the Gateway at the Environment Thunder

Register the environment Thunder with the gateway, both as a key manager that validates agents' OAuth tokens and as an identity provider shown in the console:

```bash
export ENV_THUNDER_RELEASE="amp-thunder-default-default"
# Must equal the Issuer the script printed
if [ "${ENV_THUNDER_TLS_ENABLED}" = "true" ]; then
  export ENV_THUNDER_ISSUER="https://default-idp.${CP_BASE_DOMAIN}"
else
  export ENV_THUNDER_ISSUER="http://default-idp.${CP_BASE_DOMAIN}:8080"
fi
export ENV_THUNDER_JWKS="http://${ENV_THUNDER_RELEASE}-service.${ENV_THUNDER_RELEASE}.svc.cluster.local:8090/oauth2/jwks"

KM=apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers
helm upgrade api-platform-default-default \
  oci://${HELM_CHART_REGISTRY}/wso2-amp-api-platform-gateway-extension \
  --version ${AMP_VERSION} \
  --namespace ${DATA_PLANE_NS} \
  --reuse-values \
  --set "${KM}[0].name=agent-manager-service" \
  --set "${KM}[0].issuer=agent-manager-service" \
  --set "${KM}[0].jwks.remote.uri=http://amp-api.${AMP_NS}.svc.cluster.local:9000/auth/external/jwks.json" \
  --set "${KM}[0].jwks.remote.skipTlsVerify=true" \
  --set "${KM}[1].name=ThunderKeyManager" \
  --set "${KM}[1].issuer=${ENV_THUNDER_ISSUER}" \
  --set "${KM}[1].jwks.remote.uri=${ENV_THUNDER_JWKS}" \
  --set "${KM}[1].jwks.remote.skipTlsVerify=false" \
  --set "bootstrap.identityProviders[0].name=ThunderKeyManager" \
  --set "bootstrap.identityProviders[0].issuer=${ENV_THUNDER_ISSUER}" \
  --set "bootstrap.identityProviders[0].jwksUri=${ENV_THUNDER_JWKS}" \
  --set "bootstrap.identityProviders[0].skipTlsVerify=false" \
  --timeout 900s
```

Use the issuer the script printed if you chose a different `THUNDER_HANDLE`. Without this step agents still accept API keys, but no agent endpoint can validate an OAuth token, and the console's gateway page shows *No identity providers configured*.

Verify that the gateway picked up the environment Thunder:

```bash
kubectl rollout status deployment/api-platform-default-default-gw-gateway-controller \
  -n ${DATA_PLANE_NS} --timeout=300s

# Expect Accepted=True Programmed=True
kubectl get apigateway api-platform-default-default -n ${DATA_PLANE_NS} \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'

# Expect both key managers, the second with issuer ${ENV_THUNDER_ISSUER}
helm get values api-platform-default-default -n ${DATA_PLANE_NS} -o json \
  | python3 -c 'import json,sys; [print(k["name"], k["issuer"]) for k in json.load(sys.stdin)["apiGateway"]["config"]["policyConfigurations"]["jwtauth_v1"]["keymanagers"]]'
```

This upgrade restarts the gateway controller, whose volume is `ReadWriteOnce`. On a multi-node cluster the new pod can stick in `ContainerCreating` with `Multi-Attach error for volume`; delete the old controller pod to release it:

```bash
kubectl get pods -n ${DATA_PLANE_NS} | grep gateway-controller
```

---

## Adding Environments

Additional environments are created from the Console (**Deployment Pipelines → Environments → Create Environment**), which generates an `add-environment.sh` command to run in a terminal with `kubectl` and `helm` configured. The self-hosted release has no automatic provisioning; on Agent Manager Cloud, WSO2 runs the equivalent automation.

The generated command assumes Agent Manager's own installation layout, not this module's. On this module's setup it needs corrections before and after running it.

**Before running the command**, export the gateway placement in the same shell. The script installs each environment's gateway in its own `<org>-<env>` namespace by default, but [Step 6](#step-6-install-platform-resources) sets `apiPlatformGateway.namespace` to `${DATA_PLANE_NS}`, so agents address every environment's gateway there. A gateway anywhere else leaves the agent without a route: **Try It** reports `The request was not authorized` (the gateway route answers `503 no healthy upstream`), and the agent's traces are dropped. The other settings give the gateway the same `https://<env>-<org>.${DP_DOMAIN}` address as the default environment. The script registers that address with Agent Manager once, and a reinstall does not change it:

```bash
export GATEWAY_NAMESPACE="${DATA_PLANE_NS}"
export GATEWAY_BASE_DOMAIN="${DP_DOMAIN}" GATEWAY_VHOST_SCHEME=https GATEWAY_VHOST_PORT=443
```

Also export the platform Thunder settings. The generated command passes exported variables through to the environment Thunder script. Without them, the environment Thunder trusts a local-development issuer (`http://thunder.amp.localhost:8080`) instead of OpenChoreo's Thunder:

```bash
export PLATFORM_THUNDER_ISSUER="${THUNDER_PUBLIC_URL}"
export PLATFORM_THUNDER_JWKS_URL="${PLATFORM_THUNDER_JWKS_URL:-${THUNDER_PUBLIC_URL}/oauth2/jwks}"
```

Also export `PLATFORM_THUNDER_CA_PEM` and `SKIP_CA_BUNDLE_TRUST` as in [Step 10](#step-10-provision-the-environment-identity-provider).

The generated command carries your Console access token inline as `AGENT_MANAGER_TOKEN`, and both scripts use it for every Agent Manager call. Copy the command from the Console just before you run it: a command copied earlier fails with `HTTP 401` once that token expires.

**After running the command**, complete the environment's gateway. The script installs the environment's API Platform Gateway without the bootstrap identity settings, so its bootstrap job requests a token from Agent Manager's own Thunder service, which does not exist here. The install then fails with `job api-platform-<org>-<env>-bootstrap failed: BackoffLimitExceeded`. Run this only after the Console's command has finished; it repairs the release that command installed. If `helm get values` reports `release: not found`, the command has not run, or it ran with a different `GATEWAY_NAMESPACE`. Reinstall the release with the script's values plus the identity settings. The chart enables development mode by default and the script does not turn it off, so the command also sets `developmentMode=false`, as [Step 9](#step-9-install-api-platform-gateway-extension) does for the default gateway. It reuses the `gateway-idp-credentials` Secret from [Step 9](#step-9-install-api-platform-gateway-extension). Set `NEW_ENV` to the environment's name:

```bash
export NEW_ENV="staging"
export NEW_ENV_NS="${DATA_PLANE_NS}" NEW_ENV_RELEASE="api-platform-default-${NEW_ENV}"

# Keep the values the script set, remove the failed release, and reinstall it.
# The chain stops at the first failure, so nothing is installed if the
# environment's release does not exist yet.
helm get values ${NEW_ENV_RELEASE} -n ${NEW_ENV_NS} -o yaml > ${NEW_ENV_RELEASE}-values.yaml \
&& helm uninstall ${NEW_ENV_RELEASE} -n ${NEW_ENV_NS} \
&& helm install ${NEW_ENV_RELEASE} \
  oci://${HELM_CHART_REGISTRY}/wso2-amp-api-platform-gateway-extension \
  --version ${AMP_VERSION} \
  --namespace ${NEW_ENV_NS} \
  --values ${NEW_ENV_RELEASE}-values.yaml \
  --set agentManager.idp.tokenUrl="${THUNDER_INTERNAL_URL}/oauth2/token" \
  --set agentManager.idp.existingSecret=gateway-idp-credentials \
  --set apiGateway.namespace="${NEW_ENV_NS}" \
  --set developmentMode=false \
  --timeout 1800s \
&& kubectl wait --for=condition=complete job/${NEW_ENV_RELEASE}-bootstrap \
  -n ${NEW_ENV_NS} --timeout=300s
```

Verify the environment. Expect `Accepted=True Programmed=True`, and the trusted issuer `${THUNDER_PUBLIC_URL}`:

```bash
kubectl get apigateway ${NEW_ENV_RELEASE} -n ${NEW_ENV_NS} \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'

helm get values amp-thunder-default-${NEW_ENV} -n amp-thunder-default-${NEW_ENV} -o json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["configuration"]["server"]["security"]["trustedIssuer"]["issuer"])'
```

**Finally, add the environment to a deployment pipeline.** An agent's Deploy page shows only the environments in its project's pipeline, and creating an environment does not add it to one. The `default` pipeline contains only the `default` environment. It is managed by the `amp-platform-resources` Helm release, so a later `helm upgrade` of that release resets it; create a separate pipeline instead:

1. In the Console, open **Deployment Pipelines** (organization level, **INFRASTRUCTURE**) and click **Create Pipeline**.
2. Add the environments in promotion order, for example **Default → Staging**, and click **Create**.
3. Open **Projects**, choose **Edit** on the project, select the new pipeline under **Deployment Pipeline**, and click **Update Project**.

Agents in the project can then be promoted from the first environment to the next.

If the environment was already created without the exported settings, re-run the Step 10 `add-environment-thunder.sh` command with `ENV_NAME`, `DISPLAY_NAME`, and `THUNDER_HANDLE` set to that environment's values. It is safe to re-run: it keeps the environment's secrets and updates the trusted issuer.

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

---

## Uninstallation

`scripts/uninstall.sh` removes everything this module installs on top of OpenChoreo, in the reverse order of the installation steps. OpenChoreo, its Thunder, OpenBao, and the observability modules are kept, as are OpenChoreo projects, environments, and pipelines that Agent Manager did not create. Every step skips what is already gone, and a removal that fails is reported and skipped, so you can re-run the script after fixing the cause.

| Step | What it removes |
|---|---|
| 1 | Through the Agent Manager API, while it is still running: all agents and the projects that held them, the environments added for Agent Manager with their environment Thunder and gateway, and the pipelines that reference only Agent Manager environments. It returns the `default` pipeline to the `default` environment only, because an environment that a pipeline references cannot be deleted. Other projects, environments, and pipelines are listed and kept |
| 2 | The default environment's Thunder and API Platform Gateway, the `gateway-idp-credentials` Secret, and the gateway namespace label |
| 3 | The evaluation, observability, platform resources, and core releases, the `${AMP_NS}` namespace, and the observer ingress policy. Agent Sandbox, including the upstream controller, RBAC, and CRDs that its chart applies outside Helm, and the Gateway Operator with its CRDs. Each is kept while resources of its types remain after Agent Manager's own are gone, because deleting a CRD deletes every resource of that type. Also what `helm uninstall` leaves behind: the `amp-monitor-evaluation` workflow template, each removed gateway's bootstrap Job and RBAC, registration token Secret, and controller TLS Secret, the monitor runs, the workflow-plane objects (Argo workflows, ExternalSecrets, Secrets) that deleted build and monitor runs leave behind, and the OpenChoreo access Agent Manager grants its runtime clients |
| 4 | Points the tracing module back at its own collector configuration and, once that succeeds, deletes the merged copy, and deletes the two Agent Manager client secrets from OpenBao. `secret/workflow-plane-oauth-client-secret` is kept for OpenChoreo's builds. Also the secrets Agent Manager stored through OpenChoreo's secret management (agent API keys and identities, agent environment variables, MCP and LLM proxy keys, monitor credentials), with their SecretReferences, PushSecrets, and OpenBao keys. They are recognized by Agent Manager's label and naming, including names that start with an agent's name |
| 5 | The Agent Manager identities and shared-setting changes in OpenChoreo's Thunder, with the `remove` command from [IDENTITY.md](IDENTITY.md#remove-the-identities). A new installation requires this: the Step 1 import refuses to overwrite existing identities |

Run it from a checkout of this module, with the [Configuration Variables](#configuration-variables) exported. For step 5, also export the identity configuration from [IDENTITY.md](IDENTITY.md#2-prepare-the-configuration-and-client-secrets) and the secret of OpenChoreo's `openchoreo-system-app` client, which the script uses to request a Thunder administration token. Without them it skips step 5 and tells you so:

```bash
export AMP_IDENTITY_CONFIG="${AMP_IDENTITY_WORK}/configuration.yaml"
export OPENCHOREO_SYSTEM_APP_SECRET="<openchoreo-system-app client secret>"
```

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
