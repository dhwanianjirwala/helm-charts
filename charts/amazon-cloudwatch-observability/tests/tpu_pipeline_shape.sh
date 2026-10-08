#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins the shape of the TPU branch of the OTEL Container Insights pipeline.
#
# tpuMetrics.enabled adds one node-level pipeline that scrapes the TPU metrics
# endpoint (default port 2112) of the node the agent runs on, keeps only the two
# TPU utilization metrics, stamps the cluster name and exports through the shared
# CloudWatch metrics destination. The assertions that matter most:
#
#   1. The receiver only targets TPU nodes (gke-tpu-accelerator label) and only
#      the agent's own node (K8S_NODE_NAME), so a daemonset never scrapes a
#      neighbour's TPU endpoint or a non-TPU node.
#   2. The scrape address is <node InternalIP>:<tpuMetrics.port>.
#   3. Nothing TPU-related renders when the flag is off or when
#      otelContainerInsights is off (the node-level config is not generated).
#
# Assertions run on the parsed otelConfig (PyYAML), not on rendered text, so
# they are independent of key order, line folding and string escaping.
#
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/tpu_pipeline_shape.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM="${HELM:-helm}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# render <tpuMetrics.enabled> <otelContainerInsights.enabled> <out> [extra helm args...]
render() {
    local tpu="$1" otel="$2" out="$3"
    shift 3
    "$HELM" template "$CHART_DIR" \
        --set region=us-west-2 \
        --set clusterName=test-cluster \
        --set "otelContainerInsights.enabled=${otel}" \
        --set "tpuMetrics.enabled=${tpu}" "$@" > "$out"
}

render true true "${TMP_DIR}/enabled.yaml"
render true true "${TMP_DIR}/port.yaml" --set tpuMetrics.port=8431
render false true "${TMP_DIR}/disabled.yaml"
render true false "${TMP_DIR}/no-otel-ci.yaml"

python3 - "${TMP_DIR}/enabled.yaml" "${TMP_DIR}/port.yaml" "${TMP_DIR}/disabled.yaml" "${TMP_DIR}/no-otel-ci.yaml" <<'PY'
import sys

import yaml

AGENT = "cloudwatch-agent"
RECEIVER = "prometheus/cw_k8s_ci_v0_tpu"
FILTER = "filter/cw_k8s_ci_v0_tpu"
PIPELINE = "metrics/cw_k8s_ci_v0_tpu"
EXPORTER = "otlphttp/cw_k8s_ci_v0_metrics_dest"
KEEP_METRICS = "tensorcore_utilization_node|memory_bandwidth_utilization_node"

GREEN, RED, YELLOW, RESET = "\033[0;32m", "\033[0;31m", "\033[1;33m", "\033[0m"
passed = failed = 0


def check(desc, ok):
    global passed, failed
    if ok:
        print(f"  {GREEN}PASS{RESET}: {desc}")
        passed += 1
    else:
        print(f"  {RED}FAIL{RESET}: {desc}")
        failed += 1
    return ok


def otel_config(path):
    """otelConfig of the cloudwatch-agent CR, selected by name, parsed."""
    with open(path) as f:
        for doc in yaml.safe_load_all(f):
            if (doc or {}).get("kind") == "AmazonCloudWatchAgent" and \
                    doc["metadata"]["name"] == AGENT:
                return yaml.safe_load(doc["spec"].get("otelConfig") or "{}") or {}
    return {}


def scrape_config(cfg):
    receiver = (cfg.get("receivers") or {}).get(RECEIVER) or {}
    configs = (receiver.get("config") or {}).get("scrape_configs") or []
    return configs[0] if configs else {}


def relabel(scrape, target_label=None, action=None):
    """relabel_configs entries matching target_label and/or action."""
    return [r for r in scrape.get("relabel_configs") or []
            if (target_label is None or r.get("target_label") == target_label)
            and (action is None or r.get("action") == action)]


# --- tpuMetrics.enabled=true ----------------------------------------------------
print(f"\n{YELLOW}[tpuMetrics.enabled=true]{RESET}")
cfg = otel_config(sys.argv[1])
scrape = scrape_config(cfg)
pipelines = (cfg.get("service") or {}).get("pipelines") or {}
pipeline = pipelines.get(PIPELINE) or {}
processors = cfg.get("processors") or {}

# Guards: without these, every assertion below could pass on empty input.
check(f"{AGENT} CR renders an otelConfig", bool(cfg))
check(f"{RECEIVER} renders a scrape config", bool(scrape))
check(f"{PIPELINE} renders", bool(pipeline))

check("scrape job is tpu-device-plugin", scrape.get("job_name") == "tpu-device-plugin")
check("targets are discovered with the node role",
      [k.get("role") for k in scrape.get("kubernetes_sd_configs") or []] == ["node"])

keeps = {r["source_labels"][0]: r.get("regex")
         for r in relabel(scrape, action="keep") if r.get("source_labels")}
check("only nodes carrying the gke-tpu-accelerator label are kept",
      keeps.get("__meta_kubernetes_node_label_cloud_google_com_gke_tpu_accelerator") == "(.+)")
check("only the agent's own node is kept (K8S_NODE_NAME)",
      keeps.get("__meta_kubernetes_node_name") == "${env:K8S_NODE_NAME}")

port = relabel(scrape, target_label="__tpu_metrics_port")
check("default port is 2112", len(port) == 1 and port[0].get("replacement") == "2112")
address = relabel(scrape, target_label="__address__")
check("scrape address is <node InternalIP>:<port>",
      len(address) == 1
      and address[0].get("source_labels") == ["__meta_kubernetes_node_address_InternalIP", "__tpu_metrics_port"]
      and address[0].get("separator") == ":")
check("scrape interval and timeout are set",
      bool(scrape.get("scrape_interval")) and bool(scrape.get("scrape_timeout")))

keep_filter = ((processors.get(FILTER) or {}).get("metrics") or {}).get("metric") or []
check("filter drops everything except the two TPU utilization metrics",
      len(keep_filter) == 1 and KEEP_METRICS in keep_filter[0] and keep_filter[0].endswith("!= true"))

check("pipeline reads from the TPU receiver", pipeline.get("receivers") == [RECEIVER])
chain = pipeline.get("processors") or []
check("pipeline filters, then sets the cluster name, then batches",
      chain == [FILTER, "transform/cw_k8s_ci_v0_set_cluster_name", "batch/cw_k8s_ci_v0_metrics_dest"])
check("pipeline exports through the shared CloudWatch metrics destination",
      pipeline.get("exporters") == [EXPORTER])
check("every referenced processor is defined", all(p in processors for p in chain))
check("the referenced exporter is defined", EXPORTER in (cfg.get("exporters") or {}))

# --- tpuMetrics.port override ---------------------------------------------------
print(f"\n{YELLOW}[tpuMetrics.port=8431]{RESET}")
port = relabel(scrape_config(otel_config(sys.argv[2])), target_label="__tpu_metrics_port")
check("custom port is rendered as a string replacement",
      len(port) == 1 and port[0].get("replacement") == "8431")

# --- tpuMetrics.enabled=false ---------------------------------------------------
print(f"\n{YELLOW}[tpuMetrics.enabled=false]{RESET}")
off = otel_config(sys.argv[3])
check(f"{AGENT} CR still renders an otelConfig", bool(off))
check(f"no {RECEIVER} when tpuMetrics is off", RECEIVER not in (off.get("receivers") or {}))
check(f"no {FILTER} when tpuMetrics is off", FILTER not in (off.get("processors") or {}))
check(f"no {PIPELINE} when tpuMetrics is off",
      PIPELINE not in ((off.get("service") or {}).get("pipelines") or {}))

# --- otelContainerInsights.enabled=false ----------------------------------------
print(f"\n{YELLOW}[tpuMetrics.enabled=true, otelContainerInsights.enabled=false]{RESET}")
no_ci = otel_config(sys.argv[4])
check(f"no {RECEIVER} without OTEL Container Insights", RECEIVER not in (no_ci.get("receivers") or {}))
check(f"no {PIPELINE} without OTEL Container Insights",
      PIPELINE not in ((no_ci.get("service") or {}).get("pipelines") or {}))

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
