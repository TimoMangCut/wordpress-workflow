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
    context: Path
    logs: Path
    quota_ledger: Path

    def ensure(self) -> "ReportLayout":
        self.root.mkdir(parents=True, exist_ok=True)
        self.phase1.mkdir(parents=True, exist_ok=True)
        self.phase2.mkdir(parents=True, exist_ok=True)
        self.phase3.mkdir(parents=True, exist_ok=True)
        self.context.mkdir(parents=True, exist_ok=True)
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

    def phase2_worker_logs(self, slug: str) -> Path:
        return self.phase2_logs(slug) / "worker"

    def phase2_reviewer_logs(self, slug: str) -> Path:
        return self.phase2_logs(slug) / "reviewer"

    def phase2_chunked_logs(self, slug: str) -> Path:
        return self.phase2_logs(slug) / "chunked"

    def phase2_chunked_agents_logs(self, slug: str) -> Path:
        return self.phase2_chunked_logs(slug) / "agents"

    def phase2_chunked_agent_logs(self, slug: str, agent: str) -> Path:
        return self.phase2_chunked_agents_logs(slug) / agent

    def phase2_cluster_logs(self, slug: str) -> Path:
        return self.phase2_logs(slug) / "cluster"

    def phase3_logs(self, slug: str) -> Path:
        return self.phase_logs(slug, "phase3")

    def phase3_provider_logs(self, slug: str) -> Path:
        return self.phase3_logs(slug) / "providers"

    def threat_context(self, slug: str) -> Path:
        return self.context / f"{slug}-threat-context.json"


def build_report_layout(reports_root: Pathish) -> ReportLayout:
    root = Path(reports_root).resolve()
    return ReportLayout(
        root=root,
        phase1=root / "phase1",
        phase2=root / "phase2",
        phase3=root / "phase3",
        context=root / "context",
        logs=root / "logs",
        quota_ledger=(root / "logs" / "quota-ledger.jsonl"),
    )


def phase1_artifact(layout: ReportLayout, slug: str, suffix: str) -> Path:
    return layout.phase1 / f"{slug}-{suffix}"


def phase2_artifact(layout: ReportLayout, slug: str, suffix: str) -> Path:
    return layout.phase2 / f"{slug}-{suffix}"


def phase3_artifact(layout: ReportLayout, slug: str, suffix: str) -> Path:
    return layout.phase3 / f"{slug}-{suffix}"
