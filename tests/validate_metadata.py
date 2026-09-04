#!/usr/bin/env python3

"""Validate the public surface and safe composition rules of every action."""

from __future__ import annotations

import re
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
README = (ROOT / "README.md").read_text(encoding="utf-8")
CONTRACTS = {
    "check-version": {
        "inputs": {"working-directory", "helm"},
        "outputs": set(),
    },
    "is-file-changed": {
        "inputs": {"pattern", "token"},
        "outputs": {"changed"},
    },
    "bump-version": {
        "inputs": {"token", "increment", "working-directory", "helm", "go"},
        "outputs": set(),
    },
    "checkout-dependencies": {
        "inputs": {"working-directory", "go-version"},
        "outputs": set(),
    },
    "container-build-push": {
        "inputs": {
            "version",
            "component",
            "push",
            "username",
            "password",
            "auth-token",
            "working-directory",
            "build-contexts",
            "build-args",
            "registry",
            "image-repository",
        },
        "outputs": set(),
    },
    "helm-package-push": {
        "inputs": {
            "development",
            "username",
            "password",
            "push",
            "app-version",
            "working-directory",
            "registry",
            "repository",
        },
        "outputs": {"chart-name", "chart-version"},
    },
    "chart-update-deploy": {
        "inputs": {
            "token",
            "environment",
            "chart-name",
            "chart-version",
            "dependency",
            "username",
            "password",
            "target-repository",
            "target-ref",
            "wrapper-chart-path",
            "registry",
        },
        "outputs": set(),
    },
}
IMMUTABLE_ACTION = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$")


def fail(message: str) -> None:
    raise SystemExit(message)


action_metadata = {}
for action_name, contract in CONTRACTS.items():
    metadata_path = ROOT / action_name / "action.yaml"
    if not metadata_path.is_file():
        fail(f"missing {metadata_path.relative_to(ROOT)}")
    data = yaml.safe_load(metadata_path.read_text(encoding="utf-8"))
    action_metadata[action_name] = data
    if data.get("runs", {}).get("using") != "composite":
        fail(f"{action_name} is not a composite action")
    if set(data.get("inputs", {})) != contract["inputs"]:
        fail(f"{action_name} input contract differs from the approved set")
    if set(data.get("outputs", {})) != contract["outputs"]:
        fail(f"{action_name} output contract differs from the approved set")
    for input_name, input_metadata in data.get("inputs", {}).items():
        if not input_metadata.get("description"):
            fail(f"{action_name} input {input_name} has no description")
        if not isinstance(input_metadata.get("required"), bool):
            fail(f"{action_name} input {input_name} must declare a boolean required field")
    for output_name, output_metadata in data.get("outputs", {}).items():
        if not output_metadata.get("description") or not output_metadata.get("value"):
            fail(f"{action_name} output {output_name} must declare a description and value")
    public_reference = f"SayakMukhopadhyay/github-actions/{action_name}@v1"
    if public_reference not in README:
        fail(f"README does not document {public_reference}")
    for step in data["runs"].get("steps", []):
        uses = step.get("uses")
        if uses and not IMMUTABLE_ACTION.fullmatch(uses):
            fail(f"{action_name} contains a non-immutable action reference: {uses}")
        if "run" in step and not step.get("shell"):
            fail(f"{action_name} has a run step without an explicit shell")

container_action = action_metadata["container-build-push"]
if container_action["inputs"]["build-args"].get("default") != "":
    fail("container-build-push build-args must default to an empty string")
container_build_steps = [
    step
    for step in container_action["runs"]["steps"]
    if step.get("uses", "").startswith("docker/build-push-action@")
]
if len(container_build_steps) != 1:
    fail("container-build-push must contain exactly one Docker build step")
if container_build_steps[0].get("with", {}).get("build-args") != "${{ inputs.build-args }}":
    fail("container-build-push must forward build-args unchanged")

ci_workflow = yaml.safe_load(
    (ROOT / ".github" / "workflows" / "ci.yaml").read_text(encoding="utf-8")
)
action_level_steps = ci_workflow["jobs"]["action-level"]["steps"]
container_fixtures = [
    step for step in action_level_steps if step.get("uses") == "$/container-build-push"
]
if len(container_fixtures) != 1:
    fail("CI must contain exactly one container-build-push action-level fixture")
expected_build_args = "VERSION=fixture-version\nCOMMIT=fixture-commit\n"
if container_fixtures[0].get("with", {}).get("build-args") != expected_build_args:
    fail("container-build-push CI fixture must exercise multiline build-args")

unexpected = {
    path.parent.name
    for path in ROOT.glob("*/action.yaml")
    if path.parent.name not in CONTRACTS
}
if unexpected:
    fail(f"unexpected public action directories: {sorted(unexpected)}")

print(f"Validated {len(CONTRACTS)} composite action contracts")
