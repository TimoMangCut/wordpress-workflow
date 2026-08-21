#!/usr/bin/env python3
"""Shared reports directory layout helpers."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Union

Pathish = Union[str, Path]


@dataclass(frozen=True)
class ReportLayout:
    root: Path
    phase1: Path
    phase2: Path
    phase3: Path
    final: Path
    context: Path
    cost: Path
    logs: Path
    quota_ledger: Path

    def ensure(self) -> "ReportLayout":
        self.root.mkdir(parents=True, exist_ok=True)
        self.phase1.mkdir(parents=True, exist_ok=True)
        self.phase2.mkdir(parents=True, exist_ok=True)
        self.phase3.mkdir(parents=True, exist_ok=True)
        self.final.mkdir(parents=True, exist_ok=True)
        self.context.mkdir(parents=True, exist_ok=True)
        self.cost.mkdir(parents=True, exist_ok=True)
        self.logs.mkdir(parents=True, exist_ok=True)
        return self

    def slug_logs(self, slug: str) -> Path:
        return self.logs / slug

    def phase_logs(self, slug: str, phase: str) -> Path:
        return self.slug_logs(slug) / phase

    def phase1_logs(self, slug: str) -> Path:
        return self.phase_logs(slug, "phase1")

    def phase2_logs(self, slug: str) -> Path:
        return self.phase_logs(slug, "phase2")

    def phase2_prep(self, slug: str) -> Path:
        return self.phase2 / "prep" / slug

    def phase2_prep_candidate_bundles(self, slug: str) -> Path:
        return self.phase2_prep(slug) / "candidate-bundles"

    def phase2_prep_legacy_slices(self, slug: str) -> Path:
        return self.phase2_prep(slug) / "legacy-slices"

    def phase2_dispatch(self, slug: str) -> Path:
        return self.phase2_prep(slug) / "dispatch.json"

    def phase2_dispatch_manifest(self, slug: str) -> Path:
        return self.phase2_prep(slug) / "dispatch.manifest.json"

    def phase2_candidate_inventory(self, slug: str) -> Path:
        return self.phase2_prep(slug) / "candidate-inventory.json"

    def phase2_candidate_bundle(self, slug: str, agent: str) -> Path:
        return self.phase2_prep_candidate_bundles(slug) / f"{agent}.input.json"

    def phase2_legacy_ir_slice(self, slug: str, group_name: str) -> Path:
        return self.phase2_prep_legacy_slices(slug) / f"{slug}-ir-slice-{group_name}.json"

    def phase2_legacy_semgrep_slice(self, slug: str, group_name: str) -> Path:
        return self.phase2_prep_legacy_slices(slug) / f"{slug}-semgrep-filtered-{group_name}.json"

    def phase2_agents(self, slug: str) -> Path:
        return self.phase2 / "agents" / slug

    def phase2_agent_attempts(self, slug: str) -> Path:
        return self.phase2_agents(slug) / "attempts"

    def phase2_agent_output(self, slug: str, agent: str) -> Path:
        return self.phase2_agents(slug) / f"{agent}.output.json"

    def phase2_agent_attempt_output(self, slug: str, agent: str, attempt: int) -> Path:
        return self.phase2_agent_attempts(slug) / f"{agent}.attempt-{attempt:02d}.output.json"

    def phase2_agent_attempt_normalized_output(self, slug: str, agent: str, attempt: int) -> Path:
        return self.phase2_agent_attempts(slug) / f"{agent}.attempt-{attempt:02d}.normalized.json"

    def phase2_agent_review(self, slug: str, agent: str, round_number: int = 1) -> Path:
        return self.phase2_agents(slug) / f"{agent}.review.r{round_number}.json"

    def phase2_agent_revision(self, slug: str, agent: str, round_number: int = 1) -> Path:
        return self.phase2_agents(slug) / f"{agent}.revision.r{round_number}.json"

    def phase2_agent_revision_normalized(self, slug: str, agent: str, round_number: int = 1) -> Path:
        return self.phase2_agents(slug) / f"{agent}.revision.r{round_number}.normalized.json"

    def phase2_agent_worker_snapshot(self, slug: str, agent: str) -> Path:
        return self.phase2_agents(slug) / f"{agent}.worker.initial.json"

    def phase2_merge_ready(self, slug: str) -> Path:
        return self.phase2_agents(slug) / "merge-ready"

    def phase2_merged_archive(self, slug: str) -> Path:
        return self.phase2 / f"{slug}-phase2.merged.json"

    def phase2_local_output(self, slug: str) -> Path:
        return self.phase2 / f"{slug}-phase2.local.json"

    def phase2_state(self, slug: str) -> Path:
        return self.phase2 / f"{slug}-phase2.state.json"

    def phase2_provider_policy(self, slug: str) -> Path:
        return self.phase2 / f"{slug}-provider-policy.json"

    def phase2_worker_logs(self, slug: str) -> Path:
        return self.phase2_logs(slug) / "worker"

    def phase2_reviewer_logs(self, slug: str) -> Path:
        return self.phase2_logs(slug) / "reviewer"

    def phase2_chunked_logs(self, slug: str) -> Path:
        return self.phase2_logs(slug) / "chunked"

    def phase2_chunked_run_errlog(self, slug: str) -> Path:
        return self.phase2_chunked_logs(slug) / "run.err"

    def phase2_chunked_run_live_log(self, slug: str) -> Path:
        return self.phase2_chunked_logs(slug) / "run.live.log"

    def phase2_chunked_run_summary(self, slug: str) -> Path:
        return self.phase2_chunked_logs(slug) / "run.summary.json"

    def phase2_chunked_agents_logs(self, slug: str) -> Path:
        return self.phase2_chunked_logs(slug) / "agents"

    def phase2_chunked_agent_logs(self, slug: str, agent: str) -> Path:
        return self.phase2_chunked_agents_logs(slug) / agent

    def phase2_chunked_agent_attempt_logs(self, slug: str, agent: str, attempt: int) -> Path:
        return self.phase2_chunked_agent_logs(slug, agent) / f"attempt-{attempt:02d}"

    def phase2_chunked_agent_stderr_log(self, slug: str, agent: str, attempt: int) -> Path:
        return self.phase2_chunked_agent_attempt_logs(slug, agent, attempt) / "stderr.err"

    def phase2_chunked_agent_assistant_live_log(self, slug: str, agent: str, attempt: int) -> Path:
        return self.phase2_chunked_agent_attempt_logs(slug, agent, attempt) / "assistant.live.log"

    def phase2_chunked_agent_provider_raw_log(self, slug: str, agent: str, attempt: int) -> Path:
        return self.phase2_chunked_agent_attempt_logs(slug, agent, attempt) / "provider.raw.log"

    def phase2_chunked_agent_last_message(self, slug: str, agent: str, attempt: int) -> Path:
        return self.phase2_chunked_agent_attempt_logs(slug, agent, attempt) / "last-message.txt"

    def phase2_cluster_logs(self, slug: str) -> Path:
        return self.phase2_logs(slug) / "cluster"

    def phase2_cluster_stage_raw_log(self, slug: str, cluster_id: str, stage: str) -> Path:
        return self.phase2_cluster_logs(slug) / f"{cluster_id}.{stage}.raw.log"

    def phase3_logs(self, slug: str) -> Path:
        return self.phase_logs(slug, "phase3")

    def phase3_provider_logs(self, slug: str) -> Path:
        return self.phase3_logs(slug) / "providers"

    def phase3_provider_raw_log(self, slug: str, provider: str) -> Path:
        return self.phase3_provider_logs(slug) / f"{provider}.raw.log"

    def final_report(self, slug: str, idx: int) -> Path:
        return self.final / f"{idx}-{slug}.md"

    def threat_context(self, slug: str) -> Path:
        return self.context / f"{slug}-threat-context.json"

    def cost_slug_dir(self, slug: str) -> Path:
        return self.cost / slug

    def cost_run_summary(self, slug: str, run_id: str) -> Path:
        return self.cost_slug_dir(slug) / f"{run_id}.cost.json"

    def cost_tracking_snapshot(self, slug: str, run_id: str, label: str) -> Path:
        return self.cost_slug_dir(slug) / f"{run_id}.tracking.{label}.json"


def build_report_layout(reports_root: Pathish) -> ReportLayout:
    root = Path(reports_root).resolve()
    return ReportLayout(
        root=root,
        phase1=root / "phase1",
        phase2=root / "phase2",
        phase3=root / "phase3",
        final=root / "final",
        context=root / "context",
        cost=root / "cost",
        logs=root / "logs",
        quota_ledger=(root / "logs" / "quota-ledger.jsonl"),
    )


def phase1_artifact(layout: ReportLayout, slug: str, suffix: str) -> Path:
    return layout.phase1 / f"{slug}-{suffix}"


def phase2_artifact(layout: ReportLayout, slug: str, suffix: str) -> Path:
    return layout.phase2 / f"{slug}-{suffix}"


def phase3_artifact(layout: ReportLayout, slug: str, suffix: str) -> Path:
    return layout.phase3 / f"{slug}-{suffix}"
