import json
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


def write_executable(path: pathlib.Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


ARTIFACT_FRESHNESS_STUB = """#!/usr/bin/env python3
import pathlib
import sys

cmd = sys.argv[1]
args = sys.argv[2:]

def value_for(flag: str) -> str:
    for index, item in enumerate(args):
        if item == flag and index + 1 < len(args):
            return args[index + 1]
    return ""

path = pathlib.Path(value_for("--path") or value_for("--output"))

if cmd == "phase2-trust-state":
    print("success" if path.exists() else "missing")
    raise SystemExit(0)
if cmd == "phase2-is-trusted":
    raise SystemExit(0 if path.exists() else 1)
if cmd == "is-fresh":
    raise SystemExit(1)
raise SystemExit(0)
"""


COST_TELEMETRY_STUB = """#!/usr/bin/env python3
import json
import pathlib
import sys

cmd = sys.argv[1]
args = sys.argv[2:]

def value_for(flag: str) -> str:
    for index, item in enumerate(args):
        if item == flag and index + 1 < len(args):
            return args[index + 1]
    return ""

output = value_for("--output")
if output:
    path = pathlib.Path(output)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"command": cmd}, indent=2) + "\\n", encoding="utf-8")
raise SystemExit(0)
"""


RUN_PHASE2_STUB = """#!/usr/bin/env bash
set -euo pipefail
python3 - "$@" <<'PY'
import json
import os
import pathlib
import sys

args = sys.argv[1:]
slug = ""
for index, item in enumerate(args):
    if item == "--slug" and index + 1 < len(args):
        slug = args[index + 1]
        break
if not slug and args and not args[0].startswith("--"):
    slug = args[0]
if not slug:
    slug = "unknown"

root = pathlib.Path.cwd()
capture = pathlib.Path(os.environ["STUB_PHASE2_CAPTURE"])
capture.parent.mkdir(parents=True, exist_ok=True)
payload = {
    "argv": args,
    "env": {
        "PHASE2_CHUNKED_RESUME_MISSING_ONLY": os.environ.get("PHASE2_CHUNKED_RESUME_MISSING_ONLY", ""),
        "PHASE2_WORKER_CHUNK_PARALLEL_LIMIT": os.environ.get("PHASE2_WORKER_CHUNK_PARALLEL_LIMIT", ""),
        "PIPELINE_PROGRESS_MODE": os.environ.get("PIPELINE_PROGRESS_MODE", ""),
        "PIPELINE_PROGRESS_PHASE1_WEIGHT": os.environ.get("PIPELINE_PROGRESS_PHASE1_WEIGHT", ""),
        "PIPELINE_PROGRESS_PHASE2_WEIGHT": os.environ.get("PIPELINE_PROGRESS_PHASE2_WEIGHT", ""),
        "PIPELINE_PROGRESS_PHASE3_WEIGHT": os.environ.get("PIPELINE_PROGRESS_PHASE3_WEIGHT", ""),
        "PIPELINE_PROGRESS_START_TS": os.environ.get("PIPELINE_PROGRESS_START_TS", ""),
    },
}
capture.write_text(json.dumps(payload, indent=2) + "\\n", encoding="utf-8")

phase2_dir = root / "reports" / "phase2"
phase2_dir.mkdir(parents=True, exist_ok=True)
(phase2_dir / f"{slug}-phase2.json").write_text("{\\"trust_state\\": \\"success\\"}\\n", encoding="utf-8")
(phase2_dir / f"{slug}-phase2.local.json").write_text("{\\"trust_state\\": \\"success\\"}\\n", encoding="utf-8")
(phase2_dir / f"{slug}-phase2.consensus.json").write_text("{\\"trust_state\\": \\"success\\"}\\n", encoding="utf-8")
(phase2_dir / f"{slug}-phase2.loop-summary.json").write_text("{}\\n", encoding="utf-8")
(phase2_dir / f"{slug}-phase2.state.json").write_text("{\\"status\\": \\"success\\"}\\n", encoding="utf-8")
PY
"""


RUN_PHASE3_STUB = """#!/usr/bin/env bash
set -euo pipefail
python3 - "$@" <<'PY'
import pathlib
import sys

args = sys.argv[1:]
slug = ""
for index, item in enumerate(args):
    if item == "--slug" and index + 1 < len(args):
        slug = args[index + 1]
        break
if not slug and args and not args[0].startswith("--"):
    slug = args[0]
if not slug:
    slug = "unknown"

root = pathlib.Path.cwd()
phase3_dir = root / "reports" / "phase3"
phase3_dir.mkdir(parents=True, exist_ok=True)
(phase3_dir / f"{slug}-phase3.json").write_text("{}\\n", encoding="utf-8")
(phase3_dir / f"{slug}-phase3.final.json").write_text("{}\\n", encoding="utf-8")
(phase3_dir / f"20260410-{slug}.md").write_text("# report\\n", encoding="utf-8")
final_dir = root / "reports" / "final"
final_dir.mkdir(parents=True, exist_ok=True)
(final_dir / f"20260410-{slug}.md").write_text("# final report\\n", encoding="utf-8")
PY
"""


SCAN_ALL_STUB = """#!/usr/bin/env bash
set -euo pipefail
python3 - "$@" <<'PY'
import json
import os
import pathlib
import sys

plugin_dir = pathlib.Path(sys.argv[1])
slug = plugin_dir.name
root = pathlib.Path.cwd()
capture = os.environ.get("STUB_SCAN_ALL_CAPTURE")
if capture:
    capture_path = pathlib.Path(capture)
    capture_path.parent.mkdir(parents=True, exist_ok=True)
    capture_path.write_text(
        json.dumps({"plugin_dir": str(plugin_dir), "slug": slug}, indent=2) + "\\n",
        encoding="utf-8",
    )
phase1_dir = root / "reports" / "phase1"
phase1_dir.mkdir(parents=True, exist_ok=True)
(phase1_dir / f"{slug}-ir.json").write_text(json.dumps({"metadata": {"plugin_slug": slug}}, indent=2) + "\\n", encoding="utf-8")
(phase1_dir / f"{slug}-surface.txt").write_text("surface\\n", encoding="utf-8")
(phase1_dir / f"{slug}-semgrep.json").write_text("[]\\n", encoding="utf-8")
(phase1_dir / f"{slug}-psalm.sarif").write_text("{}\\n", encoding="utf-8")
context_dir = root / "reports" / "context"
context_dir.mkdir(parents=True, exist_ok=True)
(context_dir / f"{slug}-threat-context.json").write_text(json.dumps({"plugin_slug": slug}, indent=2) + "\\n", encoding="utf-8")
PY
"""


THREAT_CONTEXT_STUB = """#!/usr/bin/env python3
import json
import pathlib
import sys

args = sys.argv[1:]
slug = args[0]
reports_dir = "reports"
for index, item in enumerate(args):
    if item == "--reports-dir" and index + 1 < len(args):
        reports_dir = args[index + 1]
path = pathlib.Path(reports_dir) / "context" / f"{slug}-threat-context.json"
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({"plugin_slug": slug}, indent=2) + "\\n", encoding="utf-8")
raise SystemExit(0)
"""


CONSOLE_UI_STUB = """#!/bin/bash
log_section() { echo "== $* =="; }
log_stage() { echo "[stage] $*"; }
log_info() { echo "[info] $*"; }
log_warn() { echo "[warn] $*"; }
log_error() { echo "[error] $*"; }
log_warn_block() { echo "[warn] $*"; }
log_error_block() { echo "[error] $*"; }
"""


PROVIDER_STRATEGY_STUB = """#!/usr/bin/env python3
import json
import pathlib
import sys

cmd = sys.argv[1]
args = sys.argv[2:]

def value_for(flag: str) -> str:
    for index, item in enumerate(args):
        if item == flag and index + 1 < len(args):
            return args[index + 1]
    return ""

def build_doc(output_path: str) -> None:
    path = pathlib.Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    doc = {
        "final": {
            "tier_id": "A0",
            "tier_label": "test_baseline",
            "high_value_potential": False,
            "trigger_reasons": ["test"],
            "stage_providers": {
                "worker": "codex",
                "reviewer_core": "codex",
                "reviewer_explore": "codex",
                "cluster_synth": "codex",
                "cluster_challenger": "codex",
            },
            "phase3_recommendation": {
                "primary_provider": "codex",
                "providers": ["codex"],
            },
        }
    }
    path.write_text(json.dumps(doc, indent=2) + "\\n", encoding="utf-8")

if cmd in {"prephase2", "fallback"}:
    build_doc(value_for("--output"))
elif cmd == "postreview":
    output_path = value_for("--output")
    policy_path = pathlib.Path(value_for("--policy"))
    path = pathlib.Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(policy_path.read_text(encoding="utf-8"), encoding="utf-8")
raise SystemExit(0)
"""


PREPARE_AGENT_INPUTS_STUB = """#!/usr/bin/env python3
import json
import pathlib
import sys

slug = sys.argv[1]
output_dir = "reports"
args = sys.argv[2:]
for index, item in enumerate(args):
    if item == "--output-dir" and index + 1 < len(args):
        output_dir = args[index + 1]

reports_root = pathlib.Path(output_dir)
prep_dir = reports_root / "phase2" / "prep" / slug
bundles_dir = prep_dir / "candidate-bundles"
bundles_dir.mkdir(parents=True, exist_ok=True)
(prep_dir / "legacy-slices").mkdir(parents=True, exist_ok=True)

bundle_path = bundles_dir / "agent-w01.input.json"
bundle_path.write_text(json.dumps({"metadata": {"plugin_slug": slug}}, indent=2) + "\\n", encoding="utf-8")
(prep_dir / "candidate-inventory.json").write_text(json.dumps({"plugin_slug": slug, "total_bundles": 1}, indent=2) + "\\n", encoding="utf-8")

dispatch = {
    "slug": slug,
    "agents": ["agent-w01"],
    "inputs": {
        "agent-w01": f"reports/phase2/prep/{slug}/candidate-bundles/agent-w01.input.json",
    },
    "source_dir": f"plugins/{slug}/",
    "timeout_seconds": 30,
    "default_provider": "codex",
    "provider_map": {"agent-w01": "codex"},
    "reviewer_provider": "codex",
    "reviewer_model": "gpt-5.4",
    "bundle_review_enabled": False,
    "review_rounds": 0,
    "bundle_inventory": f"reports/phase2/prep/{slug}/candidate-inventory.json",
}
(prep_dir / "dispatch.json").write_text(json.dumps(dispatch, indent=2) + "\\n", encoding="utf-8")
raise SystemExit(0)
"""


ORCHESTRATE_CAPTURE_STUB = """#!/usr/bin/env bash
set -euo pipefail
python3 - "$@" <<'PY'
import json
import os
import pathlib
import sys

args = sys.argv[1:]
slug = args[0]
root = pathlib.Path.cwd()
capture = pathlib.Path(os.environ["STUB_ORCHESTRATOR_CAPTURE"])
capture.parent.mkdir(parents=True, exist_ok=True)
existing_output = root / "reports" / "phase2" / "agents" / slug / "agent-w01.output.json"
payload = {
    "argv": args,
    "existing_output_present": existing_output.exists(),
    "existing_output_contents": existing_output.read_text(encoding="utf-8") if existing_output.exists() else "",
}
capture.write_text(json.dumps(payload, indent=2) + "\\n", encoding="utf-8")

phase2_dir = root / "reports" / "phase2"
phase2_dir.mkdir(parents=True, exist_ok=True)
doc = {
    "trust_state": "success",
    "degradation_signals": [],
    "true_positives": 0,
    "false_positives": 0,
    "needs_review": 0,
    "total_findings_analyzed": 0,
    "overall_risk": "LOW",
    "findings": [],
}
(phase2_dir / f"{slug}-phase2.local.json").write_text(json.dumps(doc, indent=2) + "\\n", encoding="utf-8")
PY
"""


PHASE2_POSTPROCESS_STUB = """#!/usr/bin/env python3
raise SystemExit(0)
"""


PHASE2_REVISION_INPUT_STUB = """#!/usr/bin/env python3
import json
import pathlib
import sys

args = sys.argv[1:]
output_path = ""
for index, item in enumerate(args):
    if item == "--output" and index + 1 < len(args):
        output_path = args[index + 1]

path = pathlib.Path(output_path)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(
    json.dumps(
        {
            "plugin_slug": "sample-plugin",
            "round": 2,
            "worker_mode": "revision",
            "revision_targets": [{"finding_id": "finding-1"}],
        },
        indent=2,
    )
    + "\\n",
    encoding="utf-8",
)
raise SystemExit(0)
"""


PHASE2_REVIEWER_INPUT_STUB = """#!/usr/bin/env python3
import json
import pathlib
import sys

slug = sys.argv[1]
args = sys.argv[2:]
round_number = "1"
review_mode = "core"
output_path = ""

for index, item in enumerate(args):
    if item == "--round" and index + 1 < len(args):
        round_number = args[index + 1]
    elif item == "--review-mode" and index + 1 < len(args):
        review_mode = args[index + 1]
    elif item == "--output" and index + 1 < len(args):
        output_path = args[index + 1]

path = pathlib.Path(output_path)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(
    json.dumps(
        {
            "plugin_slug": slug,
            "review_round": int(round_number),
            "review_mode": review_mode,
            "finding_packets": [
                {
                    "packet_id": "pkt-1",
                    "parent_finding_id": "finding-1",
                }
            ],
        },
        indent=2,
    )
    + "\\n",
    encoding="utf-8",
)
raise SystemExit(0)
"""


PHASE2_REVIEWER_BATCH_BUILDER_STUB = """#!/usr/bin/env python3
import json
import pathlib
import re
import sys

args = sys.argv[1:]
input_path = ""
output_plan = ""
for index, item in enumerate(args):
    if item == "--input" and index + 1 < len(args):
        input_path = args[index + 1]
    elif item == "--output-plan" and index + 1 < len(args):
        output_plan = args[index + 1]

review_input = json.loads(pathlib.Path(input_path).read_text(encoding="utf-8"))
slug = review_input.get("plugin_slug", "sample-plugin")
round_number = int(review_input.get("review_round", 1))
review_mode = review_input.get("review_mode", "core")

batch_input_rel = f"reports/phase2/{slug}-phase2.review.r{round_number}.{review_mode}.b01.input.json"
batch_output_rel = f"reports/phase2/{slug}-phase2.review.r{round_number}.{review_mode}.b01.json"
batch_input_path = pathlib.Path(batch_input_rel)
batch_input_path.parent.mkdir(parents=True, exist_ok=True)
batch_input_path.write_text(
    json.dumps(
        {
            "plugin_slug": slug,
            "review_round": round_number,
            "review_mode": review_mode,
            "finding_packets": [{"packet_id": "pkt-1", "parent_finding_id": "finding-1"}],
        },
        indent=2,
    )
    + "\\n",
    encoding="utf-8",
)

plan = {
    "plugin_slug": slug,
    "review_round": round_number,
    "review_mode": review_mode,
    "total_batches": 1,
    "batches": [
        {
            "batch_id": "b01",
            "packet_count": 1,
            "load_score": 5,
            "input_path": batch_input_rel,
            "output_path": batch_output_rel,
        }
    ],
}
plan_path = pathlib.Path(output_plan)
plan_path.parent.mkdir(parents=True, exist_ok=True)
plan_path.write_text(json.dumps(plan, indent=2) + "\\n", encoding="utf-8")
raise SystemExit(0)
"""


PHASE2_REVIEWER_BATCH_MERGER_STUB = """#!/usr/bin/env python3
import json
import pathlib
import shutil
import sys

args = sys.argv[1:]
plan_path = ""
output_path = ""
for index, item in enumerate(args):
    if item == "--plan" and index + 1 < len(args):
        plan_path = args[index + 1]
    elif item == "--output" and index + 1 < len(args):
        output_path = args[index + 1]

plan = json.loads(pathlib.Path(plan_path).read_text(encoding="utf-8"))
batch_output = pathlib.Path((plan.get("batches") or [{}])[0].get("output_path", ""))
target = pathlib.Path(output_path)
target.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(batch_output, target)
raise SystemExit(0)
"""


PHASE2_CONSENSUS_WRITER_STUB = """#!/usr/bin/env python3
import json
import pathlib
import shutil
import sys

slug = sys.argv[1]
reports_dir = "reports"
args = sys.argv[2:]
for index, item in enumerate(args):
    if item == "--reports-dir" and index + 1 < len(args):
        reports_dir = args[index + 1]

reports = pathlib.Path(reports_dir)
local_path = reports / "phase2" / f"{slug}-phase2.local.json"
consensus_path = reports / "phase2" / f"{slug}-phase2.consensus.json"
canonical_path = reports / "phase2" / f"{slug}-phase2.json"
consensus_path.parent.mkdir(parents=True, exist_ok=True)
doc = json.loads(local_path.read_text(encoding="utf-8"))
doc["trust_state"] = "success"
consensus_path.write_text(json.dumps(doc, indent=2) + "\\n", encoding="utf-8")
canonical_path.write_text(json.dumps(doc, indent=2) + "\\n", encoding="utf-8")
raise SystemExit(0)
"""


FAKE_CODEX_REVIEW_WRITER = """#!/usr/bin/env python3
import json
import pathlib
import re
import sys

joined = "\\n".join(sys.argv[1:])
matches = re.findall(r"(reports/phase2/[^\\s]+\\.json)", joined)
if not matches:
    raise SystemExit(1)
output_path = pathlib.Path(matches[-1])
output_path.parent.mkdir(parents=True, exist_ok=True)
terminal_mode = "terminal_core" in joined
payload = {
    "plugin_slug": "sample-plugin",
    "review_round": 1,
    "review_mode": "terminal_core" if terminal_mode else "core",
    "review_status": "stable",
    "summary": {
        "worker_findings_reviewed": 1,
        "material_issues_found": False,
        "new_candidate_count": 0,
        "notes": "stub reviewer batch completed",
    },
    "finding_reviews": [
        {
            "packet_id": "pkt-1",
            "finding_id": "finding-1",
            "parent_finding_id": "finding-1",
            "assessment": "retract" if terminal_mode else "keep",
            "closure_verdict": "FP" if terminal_mode else None,
            "reason": "Stub reviewer confirmed the packet can stay as-is." if not terminal_mode else "Stub terminal reviewer rejected the packet after bounded review.",
            "required_changes": [],
            "counter_evidence": [],
            "missing_evidence": [] if not terminal_mode else ["Concrete exploit proof."],
            "expansion_attempts": [],
        }
    ],
}
output_path.write_text(json.dumps(payload, indent=2) + "\\n", encoding="utf-8")
raise SystemExit(0)
"""


FAKE_CODEX_TIMEOUT = """#!/usr/bin/env python3
import sys

print("stub codex timeout during worker revision", file=sys.stderr)
raise SystemExit(124)
"""


FAKE_CODEX_RATE_LIMIT_THEN_SUCCESS = """#!/usr/bin/env python3
import json
import os
import pathlib
import re
import sys

counter_path = pathlib.Path(os.environ["STUB_CODEX_RETRY_COUNTER"])
counter_path.parent.mkdir(parents=True, exist_ok=True)
attempt = 0
if counter_path.exists():
    attempt = int(counter_path.read_text(encoding="utf-8").strip() or "0")
attempt += 1
counter_path.write_text(str(attempt), encoding="utf-8")

if attempt < 3:
    print("ERROR: unexpected status 503 Service Unavailable: Rate limit exceeded. Try again in 60s", file=sys.stderr)
    raise SystemExit(1)

joined = "\\n".join(sys.argv[1:])
matches = re.findall(r"(reports/phase2/[^\\s]+\\.json)", joined)
if not matches:
    raise SystemExit(1)
output_path = pathlib.Path(matches[-1])
output_path.parent.mkdir(parents=True, exist_ok=True)
payload = {
    "plugin_slug": "sample-plugin",
    "review_round": 1,
    "review_mode": "core",
    "review_status": "stable",
    "summary": {
        "worker_findings_reviewed": 1,
        "material_issues_found": False,
        "new_candidate_count": 0,
        "notes": "stub reviewer batch completed after retry",
    },
    "finding_reviews": [
        {
            "packet_id": "pkt-1",
            "finding_id": "finding-1",
            "parent_finding_id": "finding-1",
            "assessment": "keep",
            "reason": "Stub reviewer confirmed the packet can stay as-is after provider retry.",
            "required_changes": [],
            "counter_evidence": [],
            "missing_evidence": [],
            "expansion_attempts": [],
        }
    ],
}
output_path.write_text(json.dumps(payload, indent=2) + "\\n", encoding="utf-8")
raise SystemExit(0)
"""


FAKE_CODEX_PHASE2_WRITER = """#!/usr/bin/env python3
import json
import pathlib
import re
import sys

joined = "\\n".join(sys.argv[1:])
matches = re.findall(r"(reports/phase2/[^\\s]+\\.json)", joined)
candidates = [item for item in matches if ".input.json" not in item]
if not candidates:
    raise SystemExit(1)
for item in candidates:
    if ".worker." not in item and ".review." not in item:
        continue
    output_path = pathlib.Path(item)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    if ".review." in output_path.name:
        terminal_mode = "terminal_core" in joined
        payload = {
            "plugin_slug": "sample-plugin",
            "review_round": 3,
            "review_mode": "terminal_core" if terminal_mode else "core",
            "review_status": "stable",
            "summary": {
                "worker_findings_reviewed": 1,
                "material_issues_found": False,
                "new_candidate_count": 0,
                "notes": "stub reviewer completed",
            },
            "finding_reviews": [
                {
                    "packet_id": "pkt-1",
                    "finding_id": "finding-1",
                    "parent_finding_id": "finding-1",
                    "assessment": "retract" if terminal_mode else "keep",
                    "closure_verdict": "FP" if terminal_mode else None,
                    "reason": "stub reviewer confirmed the packet can stay as-is." if not terminal_mode else "stub terminal reviewer rejected the packet after bounded review.",
                    "required_changes": [],
                    "counter_evidence": [],
                    "missing_evidence": [] if not terminal_mode else ["Concrete exploit proof."],
                    "expansion_attempts": [],
                }
            ],
        }
    else:
        payload = {
            "plugin_slug": "sample-plugin",
            "analysis_summary": "stub worker revision output",
            "overall_risk": "LOW",
            "true_positives": 0,
            "false_positives": 1,
            "needs_review": 0,
            "total_findings_analyzed": 1,
            "findings": [
                {
                    "finding_id": "finding-1",
                    "verdict": "FP",
                    "severity": "low",
                    "auth_required": "subscriber",
                    "vuln_type": "broken_access_control",
                    "title": "stub finding",
                    "file_path": "src/example.php",
                    "line_number": 10,
                    "source_file_path": "src/example.php",
                    "source_line_number": 10,
                    "sink_file_path": "src/example.php",
                    "sink_line_number": 20,
                    "patchstack_eligible": False,
                }
            ],
            "negative_findings": [],
        }

    output_path.write_text(json.dumps(payload, indent=2) + "\\n", encoding="utf-8")
raise SystemExit(0)
"""


class ResumeWrapperCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = pathlib.Path(self.tempdir.name)
        (self.root / "plugins" / "sample-plugin").mkdir(parents=True, exist_ok=True)
        (self.root / "reports").mkdir(parents=True, exist_ok=True)

    def _copy_repo_file(self, relative_path: str) -> pathlib.Path:
        source = ROOT / relative_path
        target = self.root / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        return target

    def _write_common_stubs(self) -> None:
        self._copy_repo_file("tools/bin/report-paths.sh")
        write_executable(self.root / "tools" / "bin" / "artifact_freshness.py", ARTIFACT_FRESHNESS_STUB)
        write_executable(self.root / "tools" / "bin" / "cost_telemetry.py", COST_TELEMETRY_STUB)
        write_executable(self.root / "tools" / "bin" / "run-phase2.sh", RUN_PHASE2_STUB)
        write_executable(self.root / "tools" / "bin" / "run-phase3.sh", RUN_PHASE3_STUB)
        write_executable(self.root / "tools" / "bin" / "scan-all.sh", SCAN_ALL_STUB)

    def test_run_single_plugin_public_resume_maps_to_existing_controls(self) -> None:
        self._write_common_stubs()
        self._copy_repo_file("tools/bin/run-single-plugin.sh")

        capture_path = self.root / "captures" / "run-single-phase2.json"
        env = os.environ.copy()
        env["STUB_PHASE2_CAPTURE"] = str(capture_path)

        result = subprocess.run(
            ["bash", str(self.root / "tools" / "bin" / "run-single-plugin.sh"), "sample-plugin", "--resume"],
            cwd=self.root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
        )

        self.assertEqual(result.returncode, 0, msg=result.stderr)
        capture = json.loads(capture_path.read_text(encoding="utf-8"))
        self.assertIn("--resume-existing", capture["argv"])
        self.assertEqual(capture["env"]["PHASE2_CHUNKED_RESUME_MISSING_ONLY"], "true")
        self.assertEqual(capture["env"]["PHASE2_WORKER_CHUNK_PARALLEL_LIMIT"], "")
        self.assertIn("Resume mode: true", result.stdout)
        self.assertTrue((self.root / "reports" / "final" / "20260410-sample-plugin.md").exists())
        self.assertIn("Final report      :", result.stdout)

    def test_run_single_plugin_progress_options_export_effective_weights(self) -> None:
        self._write_common_stubs()
        self._copy_repo_file("tools/bin/run-single-plugin.sh")

        capture_path = self.root / "captures" / "run-single-progress.json"
        env = os.environ.copy()
        env["STUB_PHASE2_CAPTURE"] = str(capture_path)

        result = subprocess.run(
            [
                "bash",
                str(self.root / "tools" / "bin" / "run-single-plugin.sh"),
                "sample-plugin",
                "--resume",
                "--progress-mode",
                "weighted",
                "--progress-weights",
                "20,60,20",
            ],
            cwd=self.root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
        )

        self.assertEqual(result.returncode, 0, msg=result.stderr)
        capture = json.loads(capture_path.read_text(encoding="utf-8"))
        self.assertEqual(capture["env"]["PIPELINE_PROGRESS_MODE"], "weighted")
        self.assertEqual(capture["env"]["PIPELINE_PROGRESS_PHASE1_WEIGHT"], "20")
        self.assertEqual(capture["env"]["PIPELINE_PROGRESS_PHASE2_WEIGHT"], "60")
        self.assertEqual(capture["env"]["PIPELINE_PROGRESS_PHASE3_WEIGHT"], "20")
        self.assertTrue(capture["env"]["PIPELINE_PROGRESS_START_TS"].isdigit())
        self.assertIn("Progress mode: weighted", result.stdout)
        self.assertIn("Progress weights: phase1=20%, phase2=60%, phase3=20%", result.stdout)
        self.assertIn("Pipeline progress: 0% (pipeline start)", result.stdout)

    def test_run_single_plugin_resume_reuses_phase1_outputs_without_scan_all(self) -> None:
        self._write_common_stubs()
        self._copy_repo_file("tools/bin/run-single-plugin.sh")
        write_executable(self.root / "tools" / "bin" / "generate_threat_context.py", THREAT_CONTEXT_STUB)

        slug = "sample-plugin"
        phase1_dir = self.root / "reports" / "phase1"
        phase1_dir.mkdir(parents=True, exist_ok=True)
        (phase1_dir / f"{slug}-ir.json").write_text('{"metadata":{"plugin_slug":"sample-plugin"}}\n', encoding="utf-8")
        (phase1_dir / f"{slug}-surface.txt").write_text("surface\n", encoding="utf-8")
        (phase1_dir / f"{slug}-semgrep.json").write_text("[]\n", encoding="utf-8")

        capture_path = self.root / "captures" / "run-single-phase2.json"
        scan_capture = self.root / "captures" / "scan-all.json"
        env = os.environ.copy()
        env["STUB_PHASE2_CAPTURE"] = str(capture_path)
        env["STUB_SCAN_ALL_CAPTURE"] = str(scan_capture)

        result = subprocess.run(
            ["bash", str(self.root / "tools" / "bin" / "run-single-plugin.sh"), slug, "--resume"],
            cwd=self.root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
        )

        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertFalse(scan_capture.exists(), msg="resume should not rerun scan-all when Phase 1 artifacts already exist")
        self.assertTrue((self.root / "reports" / "context" / f"{slug}-threat-context.json").exists())
        self.assertIn("Resume existing Phase 1 artifacts: reusing surface map, semgrep, and IR", result.stdout)
        self.assertTrue((self.root / "reports" / "final" / f"20260410-{slug}.md").exists())

    def test_run_single_plugin_phase2_only_stops_before_phase3_and_passes_cluster_toggle(self) -> None:
        self._write_common_stubs()
        self._copy_repo_file("tools/bin/run-single-plugin.sh")
        write_executable(self.root / "tools" / "bin" / "generate_threat_context.py", THREAT_CONTEXT_STUB)

        slug = "sample-plugin"
        phase1_dir = self.root / "reports" / "phase1"
        phase1_dir.mkdir(parents=True, exist_ok=True)
        (phase1_dir / f"{slug}-ir.json").write_text('{"metadata":{"plugin_slug":"sample-plugin"}}\n', encoding="utf-8")
        (phase1_dir / f"{slug}-surface.txt").write_text("surface\n", encoding="utf-8")
        (phase1_dir / f"{slug}-semgrep.json").write_text("[]\n", encoding="utf-8")

        capture_path = self.root / "captures" / "run-single-phase2-only.json"
        env = os.environ.copy()
        env["STUB_PHASE2_CAPTURE"] = str(capture_path)

        result = subprocess.run(
            [
                "bash",
                str(self.root / "tools" / "bin" / "run-single-plugin.sh"),
                slug,
                "--resume",
                "--phase2-only",
                "--no-clusters",
            ],
            cwd=self.root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
        )

        self.assertEqual(result.returncode, 0, msg=result.stderr)
        capture = json.loads(capture_path.read_text(encoding="utf-8"))
        self.assertIn("--resume-existing", capture["argv"])
        self.assertIn("--no-clusters", capture["argv"])
        self.assertNotIn("--clusters", capture["argv"])
        self.assertFalse((self.root / "reports" / "phase3" / f"{slug}-phase3.json").exists())
        self.assertFalse((self.root / "reports" / "final" / f"20260410-{slug}.md").exists())
        self.assertIn("Phase 2 only: true", result.stdout)
        self.assertIn("Phase 3           : skipped (--phase2-only)", result.stdout)

    def test_run_single_plugin_phase2_only_progress_weights_are_renormalized(self) -> None:
        self._write_common_stubs()
        self._copy_repo_file("tools/bin/run-single-plugin.sh")

        capture_path = self.root / "captures" / "run-single-phase2-only-progress.json"
        env = os.environ.copy()
        env["STUB_PHASE2_CAPTURE"] = str(capture_path)

        result = subprocess.run(
            [
                "bash",
                str(self.root / "tools" / "bin" / "run-single-plugin.sh"),
                "sample-plugin",
                "--resume",
                "--phase2-only",
                "--progress-mode",
                "weighted",
                "--progress-weights",
                "10,75,15",
            ],
            cwd=self.root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
        )

        self.assertEqual(result.returncode, 0, msg=result.stderr)
        capture = json.loads(capture_path.read_text(encoding="utf-8"))
        self.assertEqual(capture["env"]["PIPELINE_PROGRESS_MODE"], "weighted")
        self.assertEqual(capture["env"]["PIPELINE_PROGRESS_PHASE1_WEIGHT"], "12")
        self.assertEqual(capture["env"]["PIPELINE_PROGRESS_PHASE2_WEIGHT"], "88")
        self.assertEqual(capture["env"]["PIPELINE_PROGRESS_PHASE3_WEIGHT"], "0")
        self.assertIn("Progress weights: phase1=12%, phase2=88%, phase3=0%", result.stdout)
        self.assertIn("Pipeline progress: 100% | ETA 0s (Pipeline complete (--phase2-only))", result.stdout)

    def test_run_pipeline_public_resume_preserves_chunked_parallelism_defaults(self) -> None:
        self._write_common_stubs()
        self._copy_repo_file("tools/bin/run-pipeline.sh")
        write_executable(self.root / "tools" / "bin" / "generate_threat_context.py", THREAT_CONTEXT_STUB)
        write_executable(self.root / "tools" / "bin" / "console-ui.sh", CONSOLE_UI_STUB)

        capture_path = self.root / "captures" / "run-pipeline-phase2.json"
        env = os.environ.copy()
        env["STUB_PHASE2_CAPTURE"] = str(capture_path)

        result = subprocess.run(
            [
                "bash",
                str(self.root / "tools" / "bin" / "run-pipeline.sh"),
                "--slug",
                "sample-plugin",
                "--multi-agent",
                "--resume",
            ],
            cwd=self.root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
        )

        self.assertEqual(result.returncode, 0, msg=result.stderr)
        capture = json.loads(capture_path.read_text(encoding="utf-8"))
        self.assertIn("--resume-existing", capture["argv"])
        self.assertEqual(capture["env"]["PHASE2_CHUNKED_RESUME_MISSING_ONLY"], "true")
        self.assertEqual(
            capture["env"]["PHASE2_WORKER_CHUNK_PARALLEL_LIMIT"],
            "",
            msg="public --resume must not silently force serial debug mode",
        )

    def test_run_pipeline_resume_reuses_phase1_outputs_without_scan_all(self) -> None:
        self._write_common_stubs()
        self._copy_repo_file("tools/bin/run-pipeline.sh")
        write_executable(self.root / "tools" / "bin" / "generate_threat_context.py", THREAT_CONTEXT_STUB)
        write_executable(self.root / "tools" / "bin" / "console-ui.sh", CONSOLE_UI_STUB)

        slug = "sample-plugin"
        phase1_dir = self.root / "reports" / "phase1"
        phase1_dir.mkdir(parents=True, exist_ok=True)
        (phase1_dir / f"{slug}-ir.json").write_text('{"metadata":{"plugin_slug":"sample-plugin"}}\n', encoding="utf-8")
        (phase1_dir / f"{slug}-surface.txt").write_text("surface\n", encoding="utf-8")
        (phase1_dir / f"{slug}-semgrep.json").write_text("[]\n", encoding="utf-8")

        capture_path = self.root / "captures" / "run-pipeline-phase2.json"
        scan_capture = self.root / "captures" / "scan-all-pipeline.json"
        env = os.environ.copy()
        env["STUB_PHASE2_CAPTURE"] = str(capture_path)
        env["STUB_SCAN_ALL_CAPTURE"] = str(scan_capture)

        result = subprocess.run(
            [
                "bash",
                str(self.root / "tools" / "bin" / "run-pipeline.sh"),
                "--slug",
                slug,
                "--multi-agent",
                "--resume",
            ],
            cwd=self.root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
        )

        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertFalse(scan_capture.exists(), msg="pipeline --resume should reuse existing Phase 1 artifacts for a specific slug")
        self.assertIn(f"Resume {slug}: reusing existing Phase 1 artifacts", result.stdout)

    def test_run_phase2_public_resume_preserves_existing_chunked_outputs(self) -> None:
        self._copy_repo_file("tools/bin/run-phase2.sh")
        self._copy_repo_file("tools/bin/report-paths.sh")
        self._copy_repo_file("tools/bin/console-ui.sh")
        self._copy_repo_file("tools/bin/timeout-utils.sh")
        self._copy_repo_file("tools/bin/phase2_terminal_closure.py")
        self._copy_repo_file("tools/config/phase2-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-review-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-terminal-review-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-exploration-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-revision-prompt-template.md")
        self._copy_repo_file("contracts/phase2-review-core-output.schema.json")
        self._copy_repo_file("contracts/phase2-review-terminal-core-output.schema.json")
        self._copy_repo_file("contracts/phase2-review-explore-output.schema.json")
        self._copy_repo_file("contracts/phase2-reviewer-input.schema.json")
        self._copy_repo_file("contracts/phase2-review-batch-plan.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-input.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-output.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-pack.schema.json")
        self._copy_repo_file("contracts/phase2-consensus.schema.json")
        self._copy_repo_file("contracts/phase2-finding.schema.json")
        self._copy_repo_file("tools/bin/build_phase2_reviewer_input.py")
        self._copy_repo_file("tools/bin/build_phase2_reviewer_batches.py")
        self._copy_repo_file("tools/bin/merge_phase2_reviewer_batches.py")
        self._copy_repo_file("tools/bin/build_phase2_revision_input.py")
        write_executable(self.root / "tools" / "bin" / "artifact_freshness.py", ARTIFACT_FRESHNESS_STUB)
        write_executable(self.root / "tools" / "bin" / "cost_telemetry.py", COST_TELEMETRY_STUB)
        write_executable(self.root / "tools" / "bin" / "provider_strategy.py", PROVIDER_STRATEGY_STUB)
        write_executable(self.root / "tools" / "bin" / "prepare_agent_inputs.py", PREPARE_AGENT_INPUTS_STUB)
        write_executable(self.root / "tools" / "bin" / "orchestrate-agents.sh", ORCHESTRATE_CAPTURE_STUB)
        write_executable(self.root / "tools" / "bin" / "phase2_postprocess.py", PHASE2_POSTPROCESS_STUB)

        slug = "sample-plugin"
        phase1_dir = self.root / "reports" / "phase1"
        phase1_dir.mkdir(parents=True, exist_ok=True)
        (phase1_dir / f"{slug}-ir.json").write_text(
            json.dumps(
                {
                    "metadata": {"plugin_slug": slug},
                    "entry_points": [{"type": "ajax", "callable": "handler"}],
                    "sources": [{"kind": "request"}],
                    "sinks": [{"kind": "output"}],
                    "guards": [],
                    "anomalies": [],
                    "unresolved_hooks": [],
                    "coverage_gaps": [],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        prep_dir = self.root / "reports" / "phase2" / "prep" / slug
        prep_dir.mkdir(parents=True, exist_ok=True)
        (prep_dir / "dispatch.json").write_text("{}", encoding="utf-8")
        (prep_dir / "candidate-inventory.json").write_text("{}", encoding="utf-8")

        agents_dir = self.root / "reports" / "phase2" / "agents" / slug
        agents_dir.mkdir(parents=True, exist_ok=True)
        existing_output = agents_dir / "agent-w01.output.json"
        existing_output.write_text("{\"existing\": true}\n", encoding="utf-8")

        capture_path = self.root / "captures" / "run-phase2-orchestrator.json"
        env = os.environ.copy()
        env["STUB_ORCHESTRATOR_CAPTURE"] = str(capture_path)
        env["PHASE2_WORKER_EXECUTION_MODE"] = "chunked"

        result = subprocess.run(
            [
                "bash",
                str(self.root / "tools" / "bin" / "run-phase2.sh"),
                "--slug",
                slug,
                "--resume",
                "--force-deep",
                "--no-clusters",
                "--no-forced-exploration",
            ],
            cwd=self.root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
        )

        capture = json.loads(capture_path.read_text(encoding="utf-8"))
        self.assertTrue(capture["existing_output_present"])
        self.assertIn("--resume-missing-only", capture["argv"])
        self.assertIn("Resume existing chunked artifacts: 1 bundle output(s) already present", result.stdout)

    def test_run_phase2_resume_shows_reviewer_batch_progress_inline(self) -> None:
        self._copy_repo_file("tools/bin/run-phase2.sh")
        self._copy_repo_file("tools/bin/report-paths.sh")
        self._copy_repo_file("tools/bin/console-ui.sh")
        self._copy_repo_file("tools/bin/timeout-utils.sh")
        self._copy_repo_file("tools/config/phase2-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-review-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-terminal-review-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-exploration-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-revision-prompt-template.md")
        self._copy_repo_file("contracts/phase2-review-core-output.schema.json")
        self._copy_repo_file("contracts/phase2-review-terminal-core-output.schema.json")
        self._copy_repo_file("contracts/phase2-review-explore-output.schema.json")
        self._copy_repo_file("contracts/phase2-reviewer-input.schema.json")
        self._copy_repo_file("contracts/phase2-review-batch-plan.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-input.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-output.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-pack.schema.json")
        self._copy_repo_file("contracts/phase2-consensus.schema.json")

        write_executable(self.root / "tools" / "bin" / "artifact_freshness.py", ARTIFACT_FRESHNESS_STUB)
        write_executable(self.root / "tools" / "bin" / "cost_telemetry.py", COST_TELEMETRY_STUB)
        write_executable(self.root / "tools" / "bin" / "provider_strategy.py", PROVIDER_STRATEGY_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_reviewer_input.py", PHASE2_REVIEWER_INPUT_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_reviewer_batches.py", PHASE2_REVIEWER_BATCH_BUILDER_STUB)
        write_executable(self.root / "tools" / "bin" / "merge_phase2_reviewer_batches.py", PHASE2_REVIEWER_BATCH_MERGER_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_revision_input.py", PHASE2_POSTPROCESS_STUB)
        write_executable(self.root / "tools" / "bin" / "phase2_postprocess.py", PHASE2_POSTPROCESS_STUB)
        write_executable(self.root / "tools" / "bin" / "write_phase2_consensus.py", PHASE2_CONSENSUS_WRITER_STUB)

        fake_codex = self.root / "tools" / "bin" / "fake-codex-review.py"
        write_executable(fake_codex, FAKE_CODEX_REVIEW_WRITER)

        slug = "sample-plugin"
        phase1_dir = self.root / "reports" / "phase1"
        phase1_dir.mkdir(parents=True, exist_ok=True)
        (phase1_dir / f"{slug}-ir.json").write_text(
            json.dumps(
                {
                    "metadata": {"plugin_slug": slug},
                    "entry_points": [{"type": "ajax", "callable": "handler", "auth_level": "none"}],
                    "sources": [{"kind": "request"}],
                    "sinks": [{"kind": "sql"}],
                    "guards": [],
                    "anomalies": [],
                    "unresolved_hooks": [],
                    "coverage_gaps": [],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        phase2_dir = self.root / "reports" / "phase2"
        phase2_dir.mkdir(parents=True, exist_ok=True)
        worker_output = phase2_dir / f"{slug}-phase2.worker.r1.json"
        worker_output.write_text(
            json.dumps(
                {
                    "plugin_slug": slug,
                    "findings": [{"finding_id": "finding-1"}],
                    "true_positives": 0,
                    "false_positives": 1,
                    "needs_review": 0,
                    "total_findings_analyzed": 1,
                    "overall_risk": "LOW",
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        (phase2_dir / f"{slug}-phase2.worker.r1.raw.json").write_text(worker_output.read_text(encoding="utf-8"), encoding="utf-8")

        env = os.environ.copy()
        env["CODEX_BIN"] = str(fake_codex)
        env["PIPELINE_PROGRESS_MODE"] = "weighted"
        env["PIPELINE_PROGRESS_PHASE1_WEIGHT"] = "10"
        env["PIPELINE_PROGRESS_PHASE2_WEIGHT"] = "75"
        env["PIPELINE_PROGRESS_PHASE3_WEIGHT"] = "15"

        result = subprocess.run(
            [
                "bash",
                str(self.root / "tools" / "bin" / "run-phase2.sh"),
                "--slug",
                slug,
                "--resume",
                "--force-deep",
                "--no-clusters",
                "--no-forced-exploration",
            ],
            cwd=self.root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
        )

        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertIn("Resume existing artifacts: worker_r1, review_r0", result.stdout)
        self.assertIn("Reviewer core round 1 plan: 1 batch(es) | Phase 2 ~40% | Pipeline ~40%", result.stdout)
        self.assertIn("Reviewer core batch 1/1: b01 (1 packet(s), load=5) | Phase 2 ~40% | Pipeline ~40%", result.stdout)

    def test_run_phase2_reviewer_core_batch_retries_rate_limit_then_succeeds(self) -> None:
        self._copy_repo_file("tools/bin/run-phase2.sh")
        self._copy_repo_file("tools/bin/report-paths.sh")
        self._copy_repo_file("tools/bin/console-ui.sh")
        self._copy_repo_file("tools/bin/timeout-utils.sh")
        self._copy_repo_file("tools/config/phase2-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-review-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-terminal-review-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-exploration-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-revision-prompt-template.md")
        self._copy_repo_file("contracts/phase2-review-core-output.schema.json")
        self._copy_repo_file("contracts/phase2-review-terminal-core-output.schema.json")
        self._copy_repo_file("contracts/phase2-review-explore-output.schema.json")
        self._copy_repo_file("contracts/phase2-reviewer-input.schema.json")
        self._copy_repo_file("contracts/phase2-review-batch-plan.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-input.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-output.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-pack.schema.json")
        self._copy_repo_file("contracts/phase2-consensus.schema.json")

        write_executable(self.root / "tools" / "bin" / "artifact_freshness.py", ARTIFACT_FRESHNESS_STUB)
        write_executable(self.root / "tools" / "bin" / "cost_telemetry.py", COST_TELEMETRY_STUB)
        write_executable(self.root / "tools" / "bin" / "provider_strategy.py", PROVIDER_STRATEGY_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_reviewer_input.py", PHASE2_REVIEWER_INPUT_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_reviewer_batches.py", PHASE2_REVIEWER_BATCH_BUILDER_STUB)
        write_executable(self.root / "tools" / "bin" / "merge_phase2_reviewer_batches.py", PHASE2_REVIEWER_BATCH_MERGER_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_revision_input.py", PHASE2_POSTPROCESS_STUB)
        write_executable(self.root / "tools" / "bin" / "phase2_postprocess.py", PHASE2_POSTPROCESS_STUB)
        write_executable(self.root / "tools" / "bin" / "write_phase2_consensus.py", PHASE2_CONSENSUS_WRITER_STUB)

        fake_codex = self.root / "tools" / "bin" / "fake-codex-rate-limit.py"
        write_executable(fake_codex, FAKE_CODEX_RATE_LIMIT_THEN_SUCCESS)

        slug = "sample-plugin"
        phase1_dir = self.root / "reports" / "phase1"
        phase1_dir.mkdir(parents=True, exist_ok=True)
        (phase1_dir / f"{slug}-ir.json").write_text(
            json.dumps(
                {
                    "metadata": {"plugin_slug": slug},
                    "entry_points": [{"type": "ajax", "callable": "handler", "auth_level": "none"}],
                    "sources": [{"kind": "request"}],
                    "sinks": [{"kind": "sql"}],
                    "guards": [],
                    "anomalies": [],
                    "unresolved_hooks": [],
                    "coverage_gaps": [],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        phase2_dir = self.root / "reports" / "phase2"
        phase2_dir.mkdir(parents=True, exist_ok=True)
        worker_output = phase2_dir / f"{slug}-phase2.worker.r1.json"
        worker_output.write_text(
            json.dumps(
                {
                    "plugin_slug": slug,
                    "findings": [{"finding_id": "finding-1"}],
                    "true_positives": 0,
                    "false_positives": 1,
                    "needs_review": 0,
                    "total_findings_analyzed": 1,
                    "overall_risk": "LOW",
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        (phase2_dir / f"{slug}-phase2.worker.r1.raw.json").write_text(worker_output.read_text(encoding="utf-8"), encoding="utf-8")

        retry_counter = self.root / "captures" / "reviewer-core-retry-count.txt"
        env = os.environ.copy()
        env["CODEX_BIN"] = str(fake_codex)
        env["STUB_CODEX_RETRY_COUNTER"] = str(retry_counter)
        env["PHASE2_REVIEWER_BATCH_RETRY_BACKOFF_SECONDS"] = "0"

        result = subprocess.run(
            [
                "bash",
                str(self.root / "tools" / "bin" / "run-phase2.sh"),
                "--slug",
                slug,
                "--resume",
                "--force-deep",
                "--no-clusters",
                "--no-forced-exploration",
            ],
            cwd=self.root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
        )

        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertEqual(retry_counter.read_text(encoding="utf-8"), "3")
        self.assertIn("Reviewer core batch 1/1: b01 (1 packet(s), load=5)", result.stdout)
        self.assertIn("retry 1/3", result.stdout)
        self.assertIn("retry 2/3", result.stdout)
        self.assertTrue((phase2_dir / f"{slug}-phase2.review.r1.core.b01.json").exists())
        self.assertTrue((phase2_dir / f"{slug}-phase2.review.r1.json").exists())

    def test_run_phase2_resume_reuses_existing_reviewer_batch_output(self) -> None:
        self._copy_repo_file("tools/bin/run-phase2.sh")
        self._copy_repo_file("tools/bin/report-paths.sh")
        self._copy_repo_file("tools/bin/console-ui.sh")
        self._copy_repo_file("tools/bin/timeout-utils.sh")
        self._copy_repo_file("tools/config/phase2-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-review-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-terminal-review-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-exploration-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-revision-prompt-template.md")
        self._copy_repo_file("contracts/phase2-review-core-output.schema.json")
        self._copy_repo_file("contracts/phase2-review-terminal-core-output.schema.json")
        self._copy_repo_file("contracts/phase2-review-explore-output.schema.json")
        self._copy_repo_file("contracts/phase2-reviewer-input.schema.json")
        self._copy_repo_file("contracts/phase2-review-batch-plan.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-input.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-output.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-pack.schema.json")
        self._copy_repo_file("contracts/phase2-consensus.schema.json")

        write_executable(self.root / "tools" / "bin" / "artifact_freshness.py", ARTIFACT_FRESHNESS_STUB)
        write_executable(self.root / "tools" / "bin" / "cost_telemetry.py", COST_TELEMETRY_STUB)
        write_executable(self.root / "tools" / "bin" / "provider_strategy.py", PROVIDER_STRATEGY_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_reviewer_input.py", PHASE2_REVIEWER_INPUT_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_reviewer_batches.py", PHASE2_REVIEWER_BATCH_BUILDER_STUB)
        write_executable(self.root / "tools" / "bin" / "merge_phase2_reviewer_batches.py", PHASE2_REVIEWER_BATCH_MERGER_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_revision_input.py", PHASE2_POSTPROCESS_STUB)
        write_executable(self.root / "tools" / "bin" / "phase2_postprocess.py", PHASE2_POSTPROCESS_STUB)
        write_executable(self.root / "tools" / "bin" / "write_phase2_consensus.py", PHASE2_CONSENSUS_WRITER_STUB)

        fake_codex = self.root / "tools" / "bin" / "fake-codex-timeout.py"
        write_executable(fake_codex, FAKE_CODEX_TIMEOUT)

        slug = "sample-plugin"
        phase1_dir = self.root / "reports" / "phase1"
        phase1_dir.mkdir(parents=True, exist_ok=True)
        (phase1_dir / f"{slug}-ir.json").write_text(
            json.dumps(
                {
                    "metadata": {"plugin_slug": slug},
                    "entry_points": [{"type": "ajax", "callable": "handler", "auth_level": "none"}],
                    "sources": [{"kind": "request"}],
                    "sinks": [{"kind": "sql"}],
                    "guards": [],
                    "anomalies": [],
                    "unresolved_hooks": [],
                    "coverage_gaps": [],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        phase2_dir = self.root / "reports" / "phase2"
        phase2_dir.mkdir(parents=True, exist_ok=True)
        worker_output = phase2_dir / f"{slug}-phase2.worker.r1.json"
        worker_output.write_text(
            json.dumps(
                {
                    "plugin_slug": slug,
                    "findings": [{"finding_id": "finding-1"}],
                    "true_positives": 0,
                    "false_positives": 1,
                    "needs_review": 0,
                    "total_findings_analyzed": 1,
                    "overall_risk": "LOW",
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        (phase2_dir / f"{slug}-phase2.worker.r1.raw.json").write_text(worker_output.read_text(encoding="utf-8"), encoding="utf-8")
        existing_batch_output = phase2_dir / f"{slug}-phase2.review.r1.core.b01.json"
        existing_batch_output.write_text(
            json.dumps(
                {
                    "plugin_slug": "sample-plugin",
                    "review_round": 1,
                    "review_mode": "core",
                    "review_status": "stable",
                    "summary": {
                        "worker_findings_reviewed": 1,
                        "material_issues_found": False,
                        "new_candidate_count": 0,
                        "notes": "stub reviewer batch reused",
                    },
                    "finding_reviews": [
                        {
                            "packet_id": "pkt-1",
                            "finding_id": "finding-1",
                            "parent_finding_id": "finding-1",
                            "assessment": "keep",
                            "reason": "Stub reviewer confirmed the packet can stay as-is.",
                            "required_changes": [],
                            "counter_evidence": [],
                            "missing_evidence": [],
                            "expansion_attempts": [],
                        }
                    ],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        env = os.environ.copy()
        env["CODEX_BIN"] = str(fake_codex)
        env["PHASE2_REVIEWER_BATCH_RETRY_BACKOFF_SECONDS"] = "0"

        result = subprocess.run(
            [
                "bash",
                str(self.root / "tools" / "bin" / "run-phase2.sh"),
                "--slug",
                slug,
                "--resume",
                "--force-deep",
                "--no-clusters",
                "--no-forced-exploration",
            ],
            cwd=self.root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
        )

        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("Reviewer core batch 1/1: b01 reuse validated output", result.stdout)
        self.assertTrue((phase2_dir / f"{slug}-phase2.review.r1.json").exists())

    def test_run_phase2_resume_worker_revision_failure_updates_state_and_resolved_provider_log(self) -> None:
        self._copy_repo_file("tools/bin/run-phase2.sh")
        self._copy_repo_file("tools/bin/report-paths.sh")
        self._copy_repo_file("tools/bin/console-ui.sh")
        self._copy_repo_file("tools/bin/timeout-utils.sh")
        self._copy_repo_file("tools/config/phase2-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-review-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-terminal-review-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-exploration-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-revision-prompt-template.md")
        self._copy_repo_file("contracts/phase2-review-core-output.schema.json")
        self._copy_repo_file("contracts/phase2-review-terminal-core-output.schema.json")
        self._copy_repo_file("contracts/phase2-review-explore-output.schema.json")
        self._copy_repo_file("contracts/phase2-reviewer-input.schema.json")
        self._copy_repo_file("contracts/phase2-review-batch-plan.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-input.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-output.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-pack.schema.json")
        self._copy_repo_file("contracts/phase2-consensus.schema.json")

        write_executable(self.root / "tools" / "bin" / "artifact_freshness.py", ARTIFACT_FRESHNESS_STUB)
        write_executable(self.root / "tools" / "bin" / "cost_telemetry.py", COST_TELEMETRY_STUB)
        write_executable(self.root / "tools" / "bin" / "provider_strategy.py", PROVIDER_STRATEGY_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_reviewer_input.py", PHASE2_REVIEWER_INPUT_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_reviewer_batches.py", PHASE2_REVIEWER_BATCH_BUILDER_STUB)
        write_executable(self.root / "tools" / "bin" / "merge_phase2_reviewer_batches.py", PHASE2_REVIEWER_BATCH_MERGER_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_revision_input.py", PHASE2_REVISION_INPUT_STUB)
        write_executable(self.root / "tools" / "bin" / "phase2_postprocess.py", PHASE2_POSTPROCESS_STUB)
        write_executable(self.root / "tools" / "bin" / "write_phase2_consensus.py", PHASE2_CONSENSUS_WRITER_STUB)
        fake_codex = self.root / "tools" / "bin" / "fake-codex-terminal-review.py"
        write_executable(fake_codex, FAKE_CODEX_REVIEW_WRITER)

        fake_codex = self.root / "tools" / "bin" / "fake-codex-timeout.py"
        write_executable(fake_codex, FAKE_CODEX_TIMEOUT)

        slug = "sample-plugin"
        phase1_dir = self.root / "reports" / "phase1"
        phase1_dir.mkdir(parents=True, exist_ok=True)
        (phase1_dir / f"{slug}-ir.json").write_text(
            json.dumps(
                {
                    "metadata": {"plugin_slug": slug},
                    "entry_points": [{"type": "ajax", "callable": "handler", "auth_level": "none"}],
                    "sources": [{"kind": "request"}],
                    "sinks": [{"kind": "sql"}],
                    "guards": [],
                    "anomalies": [],
                    "unresolved_hooks": [],
                    "coverage_gaps": [],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        phase2_dir = self.root / "reports" / "phase2"
        phase2_dir.mkdir(parents=True, exist_ok=True)
        worker_output = phase2_dir / f"{slug}-phase2.worker.r1.json"
        worker_output.write_text(
            json.dumps(
                {
                    "plugin_slug": slug,
                    "findings": [{"finding_id": "finding-1"}],
                    "true_positives": 0,
                    "false_positives": 1,
                    "needs_review": 0,
                    "total_findings_analyzed": 1,
                    "overall_risk": "LOW",
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        (phase2_dir / f"{slug}-phase2.worker.r1.raw.json").write_text(worker_output.read_text(encoding="utf-8"), encoding="utf-8")
        (phase2_dir / f"{slug}-phase2.review.r1.json").write_text(
            json.dumps(
                {
                    "plugin_slug": slug,
                    "review_round": 1,
                    "review_status": "needs_revision",
                    "summary": {
                        "worker_findings_reviewed": 1,
                        "material_issues_found": True,
                        "new_candidate_count": 0,
                        "notes": "stub review requires revision",
                    },
                    "finding_reviews": [
                        {
                            "packet_id": "pkt-1",
                            "finding_id": "finding-1",
                            "parent_finding_id": "finding-1",
                            "assessment": "change",
                            "reason": "stub reviewer requests a revision",
                            "required_changes": ["adjust verdict"],
                            "counter_evidence": [],
                            "missing_evidence": [],
                            "expansion_attempts": [],
                        }
                    ],
                    "phase2_runtime": {
                        "reviewer_provider": "codex",
                        "reviewer_model": "gpt-5.4",
                        "review_mode": "core",
                        "round": 1,
                    },
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        env = os.environ.copy()
        env["CODEX_BIN"] = str(fake_codex)
        env["PHASE2_WORKER_PROVIDER"] = "claude"

        result = subprocess.run(
            [
                "bash",
                str(self.root / "tools" / "bin" / "run-phase2.sh"),
                "--slug",
                slug,
                "--resume",
                "--force-deep",
                "--no-clusters",
                "--no-forced-exploration",
            ],
            cwd=self.root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
        )

        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)

        state = json.loads((phase2_dir / f"{slug}-phase2.state.json").read_text(encoding="utf-8"))
        self.assertEqual(state["stage"], "worker")
        self.assertEqual(state["status"], "failed")
        self.assertEqual(state["round"], 2)
        self.assertEqual(state["provider"], "codex")
        self.assertEqual(state["details"]["mode"], "revision")
        self.assertEqual(state["details"]["stop_reason"], "worker_revision_failed")

        err_log = (self.root / "reports" / "logs" / slug / "phase2" / "run.err").read_text(encoding="utf-8")
        self.assertIn("phase2 resolved providers worker_provider=codex reviewer_provider=codex", err_log)
        self.assertNotIn("phase2 envelope start slug=sample-plugin worker_provider=claude", err_log)

    def test_run_phase2_applies_terminal_closure_when_unresolved_core_feedback_remains(self) -> None:
        self._copy_repo_file("tools/bin/run-phase2.sh")
        self._copy_repo_file("tools/bin/report-paths.sh")
        self._copy_repo_file("tools/bin/console-ui.sh")
        self._copy_repo_file("tools/bin/timeout-utils.sh")
        self._copy_repo_file("tools/bin/phase2_terminal_closure.py")
        self._copy_repo_file("tools/config/phase2-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-review-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-terminal-review-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-exploration-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-revision-prompt-template.md")
        self._copy_repo_file("contracts/phase2-finding.schema.json")
        self._copy_repo_file("contracts/phase2-review-core-output.schema.json")
        self._copy_repo_file("contracts/phase2-review-terminal-core-output.schema.json")
        self._copy_repo_file("contracts/phase2-review-explore-output.schema.json")
        self._copy_repo_file("contracts/phase2-reviewer-input.schema.json")
        self._copy_repo_file("contracts/phase2-review-batch-plan.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-input.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-output.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-pack.schema.json")
        self._copy_repo_file("contracts/phase2-consensus.schema.json")

        write_executable(self.root / "tools" / "bin" / "artifact_freshness.py", ARTIFACT_FRESHNESS_STUB)
        write_executable(self.root / "tools" / "bin" / "cost_telemetry.py", COST_TELEMETRY_STUB)
        write_executable(self.root / "tools" / "bin" / "provider_strategy.py", PROVIDER_STRATEGY_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_reviewer_input.py", PHASE2_REVIEWER_INPUT_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_reviewer_batches.py", PHASE2_REVIEWER_BATCH_BUILDER_STUB)
        write_executable(self.root / "tools" / "bin" / "merge_phase2_reviewer_batches.py", PHASE2_REVIEWER_BATCH_MERGER_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_revision_input.py", PHASE2_REVISION_INPUT_STUB)
        write_executable(self.root / "tools" / "bin" / "phase2_postprocess.py", PHASE2_POSTPROCESS_STUB)
        write_executable(self.root / "tools" / "bin" / "write_phase2_consensus.py", PHASE2_CONSENSUS_WRITER_STUB)
        fake_codex = self.root / "tools" / "bin" / "fake-codex-terminal-review.py"
        write_executable(fake_codex, FAKE_CODEX_REVIEW_WRITER)

        slug = "sample-plugin"
        phase1_dir = self.root / "reports" / "phase1"
        phase1_dir.mkdir(parents=True, exist_ok=True)
        (phase1_dir / f"{slug}-ir.json").write_text(
            json.dumps(
                {
                    "metadata": {"plugin_slug": slug},
                    "entry_points": [{"type": "ajax", "callable": "handler", "auth_level": "none"}],
                    "sources": [{"kind": "request"}],
                    "sinks": [{"kind": "sql"}],
                    "guards": [],
                    "anomalies": [{"id": "anom-1", "severity": "high", "description": "stub anomaly"}],
                    "unresolved_hooks": [{"file": "src/example.php", "line": 10, "function": "add_action"}],
                    "coverage_gaps": [],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        phase2_dir = self.root / "reports" / "phase2"
        phase2_dir.mkdir(parents=True, exist_ok=True)
        worker_output = phase2_dir / f"{slug}-phase2.worker.r3.json"
        worker_payload = {
            "plugin_slug": slug,
            "analysis_summary": "stub worker round 3",
            "overall_risk": "review",
            "true_positives": 0,
            "false_positives": 0,
            "needs_review": 1,
            "total_findings_analyzed": 1,
            "findings": [
                {
                    "finding_id": "finding-1",
                    "verdict": "REVIEW",
                    "severity": "medium",
                    "auth_required": "subscriber",
                    "vuln_type": "broken_access_control",
                    "title": "stub finding",
                    "file_path": "src/example.php",
                    "line_number": 10,
                    "source_file_path": "src/example.php",
                    "source_line_number": 10,
                    "sink_file_path": "src/example.php",
                    "sink_line_number": 20,
                    "review_reason": "worker still needs exploit proof",
                    "patchstack_eligible": False,
                }
            ],
            "negative_findings": [],
        }
        worker_output.write_text(json.dumps(worker_payload, indent=2) + "\n", encoding="utf-8")
        (phase2_dir / f"{slug}-phase2.worker.r3.raw.json").write_text(worker_output.read_text(encoding="utf-8"), encoding="utf-8")
        (phase2_dir / f"{slug}-phase2.review.r2.json").write_text(
            json.dumps(
                {
                    "plugin_slug": slug,
                    "review_round": 2,
                    "review_mode": "core",
                    "review_status": "needs_revision",
                    "summary": {
                        "worker_findings_reviewed": 1,
                        "material_issues_found": True,
                        "new_candidate_count": 0,
                        "notes": "stub unresolved core feedback remains",
                    },
                    "finding_reviews": [
                        {
                            "packet_id": "pkt-1",
                            "finding_id": "finding-1",
                            "parent_finding_id": "finding-1",
                            "assessment": "needs_more_evidence",
                            "reason": "stub reviewer still needs packet-local proof",
                            "required_changes": ["add evidence"],
                            "counter_evidence": [],
                            "missing_evidence": [],
                            "expansion_attempts": [],
                        }
                    ],
                    "phase2_runtime": {
                        "reviewer_provider": "codex",
                        "reviewer_model": "gpt-5.4",
                        "review_mode": "core",
                        "round": 2,
                    },
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        env = os.environ.copy()
        env["CODEX_BIN"] = str(fake_codex)

        result = subprocess.run(
            [
                "bash",
                str(self.root / "tools" / "bin" / "run-phase2.sh"),
                "--slug",
                slug,
                "--resume",
                "--force-deep",
                "--no-clusters",
            ],
            cwd=self.root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
        )

        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("Resumed worker round 3: 0 TP, 0 FP, 1 REVIEW | Risk: review", result.stdout)
        self.assertIn("Reviewer terminal core round 3: codex", result.stdout)
        self.assertIn("Reviewer terminal core round 3 verdict: stable | finding_reviews=1, missed_findings=0", result.stdout)
        self.assertIn("Terminal closure round 4: apply reviewer closure decisions", result.stdout)
        self.assertIn("Terminal closure 4 results: 0 TP, 1 FP, 0 REVIEW | Risk: none", result.stdout)
        self.assertNotIn("Reviewer explore round 3", result.stdout)
        self.assertFalse((phase2_dir / f"{slug}-phase2.review.r3.explore.input.json").exists())
        self.assertTrue((phase2_dir / f"{slug}-phase2.review.r3.json").exists())

        state = json.loads((phase2_dir / f"{slug}-phase2.state.json").read_text(encoding="utf-8"))
        self.assertEqual(state["stage"], "done")
        self.assertEqual(state["status"], "success")
        self.assertEqual(state["details"]["stop_reason"], "terminal_core_closure_applied")

        local_phase2 = json.loads((phase2_dir / f"{slug}-phase2.local.json").read_text(encoding="utf-8"))
        self.assertEqual(local_phase2["false_positives"], 1)
        self.assertEqual(local_phase2["needs_review"], 0)
        self.assertEqual(local_phase2["findings"][0]["verdict"], "FP")
        self.assertIn("Terminal closure applied after bounded core-review exhaustion.", local_phase2["findings"][0]["fp_reason"])

        err_log = (self.root / "reports" / "logs" / slug / "phase2" / "run.err").read_text(encoding="utf-8")
        self.assertIn("terminal closure done round=4 stop_reason=terminal_core_closure_applied", err_log)
        self.assertIn("phase2 envelope done slug=sample-plugin status=success", err_log)

    def test_run_phase2_resume_skips_terminal_rerun_when_worker_is_already_terminally_closed(self) -> None:
        self._copy_repo_file("tools/bin/run-phase2.sh")
        self._copy_repo_file("tools/bin/report-paths.sh")
        self._copy_repo_file("tools/bin/console-ui.sh")
        self._copy_repo_file("tools/bin/timeout-utils.sh")
        self._copy_repo_file("tools/bin/phase2_terminal_closure.py")
        self._copy_repo_file("tools/config/phase2-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-review-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-terminal-review-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-exploration-prompt-template.md")
        self._copy_repo_file("tools/config/phase2-revision-prompt-template.md")
        self._copy_repo_file("contracts/phase2-finding.schema.json")
        self._copy_repo_file("contracts/phase2-review-core-output.schema.json")
        self._copy_repo_file("contracts/phase2-review-terminal-core-output.schema.json")
        self._copy_repo_file("contracts/phase2-review-explore-output.schema.json")
        self._copy_repo_file("contracts/phase2-reviewer-input.schema.json")
        self._copy_repo_file("contracts/phase2-review-batch-plan.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-input.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-output.schema.json")
        self._copy_repo_file("contracts/phase2-cluster-pack.schema.json")
        self._copy_repo_file("contracts/phase2-consensus.schema.json")

        write_executable(self.root / "tools" / "bin" / "artifact_freshness.py", ARTIFACT_FRESHNESS_STUB)
        write_executable(self.root / "tools" / "bin" / "cost_telemetry.py", COST_TELEMETRY_STUB)
        write_executable(self.root / "tools" / "bin" / "provider_strategy.py", PROVIDER_STRATEGY_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_reviewer_input.py", PHASE2_REVIEWER_INPUT_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_reviewer_batches.py", PHASE2_REVIEWER_BATCH_BUILDER_STUB)
        write_executable(self.root / "tools" / "bin" / "merge_phase2_reviewer_batches.py", PHASE2_REVIEWER_BATCH_MERGER_STUB)
        write_executable(self.root / "tools" / "bin" / "build_phase2_revision_input.py", PHASE2_REVISION_INPUT_STUB)
        write_executable(self.root / "tools" / "bin" / "phase2_postprocess.py", PHASE2_POSTPROCESS_STUB)
        write_executable(self.root / "tools" / "bin" / "write_phase2_consensus.py", PHASE2_CONSENSUS_WRITER_STUB)

        slug = "sample-plugin"
        phase1_dir = self.root / "reports" / "phase1"
        phase1_dir.mkdir(parents=True, exist_ok=True)
        (phase1_dir / f"{slug}-ir.json").write_text(
            json.dumps(
                {
                    "metadata": {"plugin_slug": slug},
                    "entry_points": [
                        {
                            "id": "ep-1",
                            "kind": "ajax",
                            "hook": "wp_ajax_nopriv_example",
                            "callable": "Sample_Plugin::handle",
                            "file_path": "src/example.php",
                            "line_number": 10,
                            "auth": "none",
                        }
                    ],
                    "sources": [
                        {
                            "id": "src-1",
                            "kind": "request",
                            "superglobal": "_GET",
                            "file_path": "src/example.php",
                            "line_number": 12,
                        }
                    ],
                    "sinks": [
                        {
                            "id": "sink-1",
                            "kind": "output",
                            "function": "echo",
                            "file_path": "src/example.php",
                            "line_number": 20,
                        }
                    ],
                    "guards": [],
                    "anomalies": [],
                    "unresolved_hooks": [],
                    "coverage_gaps": [],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        phase2_dir = self.root / "reports" / "phase2"
        phase2_dir.mkdir(parents=True, exist_ok=True)
        worker_output = phase2_dir / f"{slug}-phase2.worker.r6.json"
        worker_output.write_text(
            json.dumps(
                {
                    "plugin_slug": slug,
                    "analysis_summary": "already terminally closed",
                    "overall_risk": "low",
                    "true_positives": 0,
                    "false_positives": 1,
                    "needs_review": 0,
                    "total_findings_analyzed": 1,
                    "phase2_terminal_closure": {
                        "version": "v2-terminal-review-authoritative",
                        "source_review_round": 4,
                        "closed_finding_ids": ["finding-1"],
                    },
                    "findings": [
                        {
                            "finding_id": "finding-1",
                            "verdict": "FP",
                            "severity": "informational",
                            "auth_required": "none",
                            "vuln_type": "broken_access_control",
                            "title": "closed finding",
                            "file_path": "src/example.php",
                            "line_number": 10,
                            "source_file_path": "src/example.php",
                            "source_line_number": 10,
                            "sink_file_path": "src/example.php",
                            "sink_line_number": 20,
                            "patchstack_eligible": False,
                        }
                    ],
                    "negative_findings": [],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        (phase2_dir / f"{slug}-phase2.worker.r6.raw.json").write_text(worker_output.read_text(encoding="utf-8"), encoding="utf-8")
        (phase2_dir / f"{slug}-phase2.review.r4.json").write_text(
            json.dumps(
                {
                    "plugin_slug": slug,
                    "review_round": 4,
                    "review_mode": "terminal_core",
                    "review_status": "stable",
                    "summary": {
                        "worker_findings_reviewed": 1,
                        "material_issues_found": False,
                        "new_candidate_count": 0,
                        "notes": "terminal core already stable",
                    },
                    "finding_reviews": [
                        {
                            "packet_id": "finding-1",
                            "finding_id": "finding-1",
                            "parent_finding_id": "finding-1",
                            "assessment": "retract",
                            "closure_verdict": "FP",
                            "reason": "already terminally closed",
                            "required_changes": [],
                            "counter_evidence": [],
                            "missing_evidence": [],
                            "expansion_attempts": [],
                        }
                    ],
                    "phase2_runtime": {
                        "reviewer_provider": "codex",
                        "reviewer_model": "gpt-5.4",
                        "review_mode": "terminal_core",
                        "round": 4,
                    },
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        result = subprocess.run(
            [
                "bash",
                str(self.root / "tools" / "bin" / "run-phase2.sh"),
                "--slug",
                slug,
                "--resume",
                "--force-deep",
                "--no-clusters",
            ],
            cwd=self.root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
        )

        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("Resumed worker round 6: 0 TP, 1 FP, 0 REVIEW | Risk: low", result.stdout)
        self.assertIn("already reflects terminal closure; skipping additional terminal_core", result.stdout)
        self.assertNotIn("Reviewer terminal core round 5", result.stdout)
        self.assertNotIn("Terminal closure round 7", result.stdout)

        err_log = (self.root / "reports" / "logs" / slug / "phase2" / "run.err").read_text(encoding="utf-8")
        self.assertIn("resume detected prior terminal closure on worker_round=6", err_log)
        self.assertNotIn("reviewer round start round=5 mode=terminal_core", err_log)


if __name__ == "__main__":
    unittest.main()
