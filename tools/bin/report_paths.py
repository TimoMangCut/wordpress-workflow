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
    logs: Path
    quota_ledger: Path

    def ensure(self) -> "ReportLayout":
        self.root.mkdir(parents=True, exist_ok=True)
        self.phase1.mkdir(parents=True, exist_ok=True)
        self.phase2.mkdir(parents=True, exist_ok=True)
        self.phase3.mkdir(parents=True, exist_ok=True)
        self.logs.mkdir(parents=True, exist_ok=True)
        return self


def build_report_layout(reports_root: Pathish) -> ReportLayout:
    root = Path(reports_root).resolve()
    return ReportLayout(
        root=root,
        phase1=root / "phase1",
        phase2=root / "phase2",
        phase3=root / "phase3",
        logs=root / "logs",
        quota_ledger=(root / "logs" / "quota-ledger.jsonl"),
    )


def phase1_artifact(layout: ReportLayout, slug: str, suffix: str) -> Path:
    return layout.phase1 / f"{slug}-{suffix}"


def phase2_artifact(layout: ReportLayout, slug: str, suffix: str) -> Path:
    return layout.phase2 / f"{slug}-{suffix}"


def phase3_artifact(layout: ReportLayout, slug: str, suffix: str) -> Path:
    return layout.phase3 / f"{slug}-{suffix}"
