#!/usr/bin/env python3
# Copyright 2026 The OpenChoreo Authors
# SPDX-License-Identifier: Apache-2.0
"""Add Agent Manager trace handling to an existing OpenChoreo collector config.

Reads the tracing module's live ConfigMap on stdin and writes a new ConfigMap
on stdout. Everything already in the pipeline is kept: receivers (including
OTLP gRPC), processors such as k8sattributes and tail_sampling, exporters, and
any customized values. Only two additions are made, taken from
wso2/agent-manager amp/v1.0.0 deployments/values/oc-collector-configmap.yaml:

- the OTLP HTTP receiver keeps request metadata (include_metadata), and
- a resource/amp processor copies the x-user-* headers the Agent Manager
  gateway sets into openchoreo.dev/* resource attributes.
"""
import argparse
import sys

import yaml

PROCESSOR = "resource/amp"
AMP_ATTRIBUTES = [
    {"key": "openchoreo.dev/component-uid", "from_context": "metadata.x-user-component", "action": "upsert"},
    {"key": "openchoreo.dev/environment-uid", "from_context": "metadata.x-user-environment", "action": "upsert"},
    {"key": "openchoreo.dev/project-uid", "from_context": "metadata.x-user-project", "action": "upsert"},
    {"key": "openchoreo.dev/namespace", "from_context": "metadata.x-user-namespace", "action": "upsert"},
]


class MergeError(Exception):
    pass


class _Dumper(yaml.SafeDumper):
    pass


# Keep multi-line values, such as the relay configuration, readable in the output.
_Dumper.add_representer(str, lambda dumper, value: dumper.represent_scalar(
    "tag:yaml.org,2002:str", value, style="|" if "\n" in value else None))


def merge_relay(relay):
    config = yaml.safe_load(relay)
    if not isinstance(config, dict):
        raise MergeError("The relay configuration is not a YAML mapping.")
    try:
        protocols = config["receivers"]["otlp"]["protocols"]
        pipeline = config["service"]["pipelines"]["traces"]
    except (KeyError, TypeError):
        raise MergeError("Expected an otlp receiver and a traces pipeline; this is not the tracing module's collector config.") from None
    if "opensearch" not in (pipeline.get("exporters") or []):
        raise MergeError("The traces pipeline does not export to OpenSearch. Run this against the receiving collector in the observability plane.")
    # The Agent Manager gateway exports over OTLP HTTP.
    http = protocols.get("http")
    if http is None:
        http = protocols["http"] = {"endpoint": "0.0.0.0:4318"}
    http["include_metadata"] = True
    processors = config.get("processors") or {}
    processors[PROCESSOR] = {"attributes": AMP_ATTRIBUTES}
    config["processors"] = processors
    # Run after k8sattributes so header values win for spans the gateway
    # relays, and before sampling. Spans without these headers are untouched.
    order = [name for name in (pipeline.get("processors") or []) if name != PROCESSOR]
    position = order.index("k8sattributes") + 1 if "k8sattributes" in order else 0
    order.insert(position, PROCESSOR)
    pipeline["processors"] = order
    return yaml.safe_dump(config, sort_keys=False)


def merge_configmap(source, name):
    if not isinstance(source, dict) or source.get("kind") != "ConfigMap" or "relay" not in (source.get("data") or {}):
        raise MergeError("Input must be the tracing module's collector ConfigMap, with a relay key.")
    return {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        # Fresh metadata: no Helm ownership, resourceVersion, or UID from the source.
        "metadata": {
            "name": name,
            "namespace": source["metadata"]["namespace"],
            "labels": {"app.kubernetes.io/part-of": "wso2-agent-manager"},
            "annotations": {"wso2.com/merged-from": source["metadata"]["name"]},
        },
        "data": {**source["data"], "relay": merge_relay(source["data"]["relay"])},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--name", default="amp-opentelemetry-collector-config", help="Name of the ConfigMap to write.")
    args = parser.parse_args()
    try:
        output = merge_configmap(yaml.safe_load(sys.stdin), args.name)
    except (MergeError, yaml.YAMLError) as error:
        print(str(error), file=sys.stderr)
        return 1
    except (KeyError, TypeError):
        print("Input ConfigMap is missing its metadata.", file=sys.stderr)
        return 1
    yaml.dump(output, sys.stdout, Dumper=_Dumper, sort_keys=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
