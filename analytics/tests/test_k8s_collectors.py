"""
Golden-file tests for the Kubernetes cluster collector output.

Fixtures live at analytics/tests/fixtures/k8s/ and are captured from
live CronJob runs.  All tests run entirely offline — no cluster or S3
connection is required.
"""

import json
import pathlib

import pytest

FIXTURE_DIR = pathlib.Path(__file__).parent / "fixtures" / "k8s"


def load(filename: str) -> object:
    return json.loads((FIXTURE_DIR / filename).read_text())


# ---------------------------------------------------------------------------
# cluster.json — NodeList
# ---------------------------------------------------------------------------


class TestClusterFixture:
    def setup_method(self):
        self.data = load("cluster.json")

    def test_is_dict(self):
        assert isinstance(self.data, dict)

    def test_has_items_array(self):
        assert "items" in self.data
        assert isinstance(self.data["items"], list)

    def test_items_not_empty(self):
        assert len(self.data["items"]) > 0

    def test_each_item_has_name(self):
        for item in self.data["items"]:
            assert "name" in item, f"Missing 'name' in node: {item}"
            assert isinstance(item["name"], str)

    def test_each_item_has_conditions(self):
        for item in self.data["items"]:
            assert "conditions" in item, f"Missing 'conditions' in node: {item['name']}"
            assert isinstance(item["conditions"], list)

    def test_conditions_have_required_fields(self):
        for item in self.data["items"]:
            for cond in item["conditions"]:
                assert "type" in cond
                assert "status" in cond

    def test_each_item_has_allocatable(self):
        for item in self.data["items"]:
            assert "allocatable" in item

    def test_each_item_has_node_info(self):
        for item in self.data["items"]:
            assert "node_info" in item
            info = item["node_info"]
            assert "kubelet_version" in info
            assert "os_image" in info


# ---------------------------------------------------------------------------
# workloads.json — WorkloadList (Deployments + Pods)
# ---------------------------------------------------------------------------


class TestWorkloadsFixture:
    def setup_method(self):
        self.data = load("workloads.json")

    def test_is_dict(self):
        assert isinstance(self.data, dict)

    def test_has_items_array(self):
        assert "items" in self.data
        assert isinstance(self.data["items"], list)

    def test_items_not_empty(self):
        assert len(self.data["items"]) > 0

    def test_each_item_has_required_fields(self):
        for item in self.data["items"]:
            assert "name" in item, f"Missing 'name': {item}"
            assert "namespace" in item, f"Missing 'namespace': {item}"
            assert "kind" in item, f"Missing 'kind': {item}"

    def test_known_kinds_present(self):
        kinds = {item["kind"] for item in self.data["items"]}
        # The collector captures at minimum Deployments and Pods
        assert "Deployment" in kinds or "Pod" in kinds, f"Unexpected kinds: {kinds}"

    def test_deployments_have_status(self):
        deployments = [i for i in self.data["items"] if i["kind"] == "Deployment"]
        for dep in deployments:
            assert "status" in dep, f"Deployment {dep['name']} missing 'status'"


# ---------------------------------------------------------------------------
# ingress.json — IngressList
# ---------------------------------------------------------------------------


class TestIngressFixture:
    def setup_method(self):
        self.data = load("ingress.json")

    def test_is_dict(self):
        assert isinstance(self.data, dict)

    def test_has_items_key(self):
        # Key must exist even when there are no ingresses
        assert "items" in self.data

    def test_items_is_list(self):
        assert isinstance(self.data["items"], list)

    def test_each_item_has_required_fields(self):
        for item in self.data["items"]:
            assert "name" in item
            assert "namespace" in item

    def test_each_item_has_rules(self):
        for item in self.data["items"]:
            assert "rules" in item
            assert isinstance(item["rules"], list)


# ---------------------------------------------------------------------------
# certs.json — CertificateList
# ---------------------------------------------------------------------------


class TestCertsFixture:
    def setup_method(self):
        self.data = load("certs.json")

    def test_is_dict(self):
        assert isinstance(self.data, dict)

    def test_has_items_array(self):
        assert "items" in self.data
        assert isinstance(self.data["items"], list)

    def test_items_not_empty(self):
        assert len(self.data["items"]) > 0

    def test_each_item_has_name_and_namespace(self):
        for item in self.data["items"]:
            assert "name" in item
            assert "namespace" in item

    def test_each_item_has_dns_names(self):
        for item in self.data["items"]:
            assert "dns_names" in item
            assert isinstance(item["dns_names"], list)

    def test_each_item_has_conditions(self):
        for item in self.data["items"]:
            assert "conditions" in item
            assert isinstance(item["conditions"], list)

    def test_conditions_have_type_and_status(self):
        for item in self.data["items"]:
            for cond in item["conditions"]:
                assert "type" in cond
                assert "status" in cond

    def test_each_item_has_expiry_fields(self):
        for item in self.data["items"]:
            assert "not_after" in item
            assert "not_before" in item


# ---------------------------------------------------------------------------
# events.json — EventList
# ---------------------------------------------------------------------------


class TestEventsFixture:
    def setup_method(self):
        self.data = load("events.json")

    def test_is_dict(self):
        assert isinstance(self.data, dict)

    def test_has_items_array(self):
        assert "items" in self.data
        assert isinstance(self.data["items"], list)

    def test_each_item_has_core_fields(self):
        for item in self.data["items"]:
            assert "name" in item
            assert "namespace" in item
            assert "reason" in item
            assert "type" in item
            assert "message" in item

    def test_each_item_has_involved_object(self):
        for item in self.data["items"]:
            assert "involved_object" in item
            obj = item["involved_object"]
            assert "kind" in obj
            assert "name" in obj


# ---------------------------------------------------------------------------
# app-health.json — dict keyed by "{namespace}/{app}"
# ---------------------------------------------------------------------------


class TestAppHealthFixture:
    def setup_method(self):
        self.data = load("app-health.json")

    def test_is_dict(self):
        assert isinstance(self.data, dict)

    def test_not_empty(self):
        assert len(self.data) > 0

    def test_keys_follow_namespace_app_pattern(self):
        for key in self.data:
            assert "/" in key, f"Key '{key}' does not follow namespace/app pattern"

    def test_values_are_lists(self):
        for key, pods in self.data.items():
            assert isinstance(pods, list), f"Value for '{key}' is not a list"

    def test_each_pod_has_required_fields(self):
        for key, pods in self.data.items():
            for pod in pods:
                assert "name" in pod, f"Missing 'name' in pod under '{key}'"
                assert "phase" in pod, f"Missing 'phase' in pod under '{key}'"
                assert "ready" in pod, f"Missing 'ready' in pod under '{key}'"
                assert (
                    "restart_count" in pod
                ), f"Missing 'restart_count' in pod under '{key}'"

    def test_ready_is_bool(self):
        for key, pods in self.data.items():
            for pod in pods:
                assert isinstance(
                    pod["ready"], bool
                ), f"'ready' is not bool for pod {pod['name']} under '{key}'"

    def test_restart_count_is_non_negative_int(self):
        for key, pods in self.data.items():
            for pod in pods:
                assert isinstance(pod["restart_count"], int)
                assert pod["restart_count"] >= 0
