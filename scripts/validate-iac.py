#!/usr/bin/env python3
"""Repository-local structural checks for the non-live Terraform plan.

Terraform itself remains the authoritative parser/validator when installed. This
small check keeps the repository's safety invariants testable on machines that
only have the OVH CLI and shell tooling available.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TF = ROOT / "infra" / "terraform"

required_files = [
    TF / "versions.tf",
    TF / "variables.tf",
    TF / "main.tf",
    TF / "terraform.tfvars.example",
    TF / "backend.hcl.example",
    TF / "imports.tf.example",
    TF / "README.md",
    ROOT / "CONTEXT.md",
    ROOT / "docs" / "deployment-plan.md",
]
for path in required_files:
    if not path.is_file():
        raise SystemExit(f"missing required deployment artifact: {path.relative_to(ROOT)}")

main = (TF / "main.tf").read_text()
variables = (TF / "variables.tf").read_text()
versions = (TF / "versions.tf").read_text()
plan = (ROOT / "docs" / "deployment-plan.md").read_text()
context = (ROOT / "CONTEXT.md").read_text()

required_fragments = {
    "OVH VPS resource": 'resource "ovh_vps" "platform"',
    "Cloudflare DNS resources": 'resource "cloudflare_dns_record"',
    "Cloudflare Tunnel": 'resource "cloudflare_zero_trust_tunnel_cloudflared"',
    "Cloudflare Access": 'resource "cloudflare_zero_trust_access_application"',
    "Cloudflare R2": 'resource "cloudflare_r2_bucket"',
    "OpenBao machine credential escrow": 'resource "vault_kv_secret_v2" "access_service_token"',
    "encrypted production backend": 'backend "s3" {}',
    "preserved-resource lifecycle guards": "prevent_destroy = true",
    "non-live VPS default": 'default     = false',
    "sensitive tunnel secret": 'variable "cloudflare_tunnel_secret"',
    "Cloudflare provider": 'source  = "cloudflare/cloudflare"',
    "OVH provider": 'source  = "ovh/ovh"',
}
for label, fragment in required_fragments.items():
    haystack = variables if "secret" in label or "default" in label else main + versions
    if fragment not in haystack:
        raise SystemExit(f"{label} invariant missing: {fragment}")

for heading in [
    "## Evidence and change register",
    "## Target architecture",
    "## Domain contract",
    "## Secret and state lifecycle",
    "## Deployment and rollback sequence",
    "## Verification commands",
]:
    if heading not in plan:
        raise SystemExit(f"deployment plan section missing: {heading}")

if "Cloudflare is the exclusive public DNS/edge provider" not in plan:
    raise SystemExit("deployment plan does not state the Cloudflare-only edge boundary")
if "graft check" not in plan or "graft build" not in plan:
    raise SystemExit("deployment plan does not contain the graft verification workflow")
if "ovhcloud vps list --output json" not in plan:
    raise SystemExit("deployment plan does not document OVH CLI discovery")

# The human dashboard identity must be enforced in configuration and present
# in the blessed example: no valid apply may omit ksonny4@gmail.com.
variables = (TF / "variables.tf").read_text()
if 'contains(var.admin_emails, "ksonny4@gmail.com")' not in variables:
    raise SystemExit("admin_emails retention validation missing from variables.tf")

# The canonical domain must remain an operator input, never a committed value.
example = (TF / "terraform.tfvars.example").read_text()
if '"ksonny4@gmail.com"' not in example:
    raise SystemExit("blessed example must retain ksonny4@gmail.com in admin_emails")
for placeholder in [
    "REPLACE_WITH_APPROVED_DOMAIN",
    "REPLACE_WITH_CLOUDFLARE_ACCOUNT_ID",
    "REPLACE_WITH_EXTERNAL_SECRET",
    "REPLACE_WITH_BASE64_TUNNEL_SECRET",
]:
    if placeholder not in example:
        raise SystemExit(f"safe example is missing placeholder: {placeholder}")

# Check tracked and newly-created content for credential-shaped material.
# Documentation names are fine; concrete assignments and private-key bodies are not.
# Include untracked files so this gate protects the same pre-commit surface as
# the final review, while skipping generated/local state.
ignored_parts = {".git", ".pi-glla", ".terraform", ".graph", ".cache"}
source_paths = []
for path in ROOT.rglob("*"):
    if not path.is_file():
        continue
    relative_parts = path.relative_to(ROOT).parts
    if any(part in ignored_parts for part in relative_parts):
        continue
    if relative_parts and relative_parts[0] == "graft":
        continue
    source_paths.append(path)

assignment = re.compile(
    r"\b(?:API_TOKEN|TOKEN|SECRET|PASSWORD|PRIVATE_KEY|ACCESS_KEY|APP_KEY)\b\s*[:=]\s*[\"']?([^\s\"']{20,})",
    re.IGNORECASE,
)
for path in source_paths:
    text = path.read_text(errors="replace")
    name = path.relative_to(ROOT).as_posix()
    private_key_marker = "PRIVATE " + "KEY-----"
    if "-----BEGIN " in text and private_key_marker in text:
        raise SystemExit(f"private-key material found in tracked file: {name}")
    for line_no, line in enumerate(text.splitlines(), start=1):
        match = assignment.search(line)
        if not match:
            continue
        value = match.group(1)
        if (
            value.startswith("REPLACE_WITH_")
            or "example.invalid" in value
            or value.startswith("<")
            or value.startswith(("var.", "local.", "data.", "resource."))
        ):
            continue
        raise SystemExit(f"credential-shaped assignment in tracked file {name}:{line_no}")

# Context is part of the source-of-truth boundary, not a detached note.
for term in ["OVHcloud VPS", "Cloudflare", "External secret manager", "Graft"]:
    if term not in context:
        raise SystemExit(f"context invariant missing: {term}")

print("IaC structural validation passed: providers, safety defaults, plan sections, context, and tracked-secret checks")
