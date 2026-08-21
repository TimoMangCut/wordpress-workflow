#!/usr/bin/env python3
"""Cost-aware provider strategy resolver for Phase 2/Phase 3."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from report_paths import build_report_layout


HIGH_IMPACT_PRIORITY_VULNS = {
    "privilege_escalation",
    "auth_bypass",
    "account_takeover",
    "arbitrary_file_upload",
    "file_deletion",
    "ssrf",
    "local_file_inclusion",
    "remote_file_inclusion",
}

VERY_HIGH_IMPACT_FAMILIES = {
    "authorization",
    "sqli",
    "include",
    "deserialization",
    "ssrf",
    "account",
}

STAGE_PROVIDERS = {
    "A0": {
        "worker": "codex",
        "reviewer_core": "codex",
        "reviewer_explore": "codex",
        "cluster_synth": "codex",
        "cluster_challenger": "codex",
        "phase3_primary": "codex",
        "phase3_skeptic": "disabled",
    },
    "A1": {
        "worker": "codex",
        "reviewer_core": "codex",
        "reviewer_explore": "codex",
        "cluster_synth": "codex",
        "cluster_challenger": "codex",
        "phase3_primary": "codex",
        "phase3_skeptic": "disabled",
    },
    "A2": {
        "worker": "codex",
        "reviewer_core": "codex",
        "reviewer_explore": "claude",
        "cluster_synth": "codex",
        "cluster_challenger": "claude",
        "phase3_primary": "codex",
        "phase3_skeptic": "disabled",
    },
    "A3": {
        "worker": "codex",
        "reviewer_core": "codex",
        "reviewer_explore": "claude",
        "cluster_synth": "codex",
        "cluster_challenger": "claude",
        "phase3_primary": "codex",
        "phase3_skeptic": "claude",
    },
}

TIER_LABELS = {
    "A0": "codex_only_low_signal",
    "A1": "codex_deep_default",
    "A2": "claude_selective_high_value_potential",
    "A3": "claude_escalated_high_value_target",
}

TIER_ORDER = {"A0": 0, "A1": 1, "A2": 2, "A3": 3}
ALLOWED_PROVIDERS = {"codex", "claude"}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def maybe_load_json(path: Path | None) -> dict[str, Any] | None:
    if path is None or not path.exists():
        return None
    try:
        data = load_json(path)
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def sink_breakdown(ir: dict[str, Any]) -> dict[str, int]:
    counts = {
        "sql": 0,
        "file_write": 0,
        "file_delete": 0,
        "file_read": 0,
        "include": 0,
        "remote_request": 0,
        "deserialization": 0,
        "option_update": 0,
        "meta_update": 0,
        "output": 0,
    }
    for sink in ir.get("sinks", []) or []:
        category = str(sink.get("category") or "").lower()
        if category in counts:
            counts[category] += 1
        elif category == "output_return":
            counts["output"] += 1
    return counts


def phase2_metrics(ir: dict[str, Any]) -> dict[str, Any]:
    entry_points = ir.get("entry_points", []) or []
    sinks = ir.get("sinks", []) or []
    sources = ir.get("sources", []) or []
    anomalies = ir.get("anomalies", []) or []
    coverage_gaps = ir.get("coverage_gaps", []) or []
    sensitive_categories = {
        "sql",
        "file_write",
        "file_delete",
        "option_update",
        "meta_update",
        "eval",
        "deserialization",
        "include",
        "remote_request",
    }
    breakdown = sink_breakdown(ir)
    return {
        "entry_points": len(entry_points),
        "anomalies": len(anomalies),
        "coverage_gaps": len(coverage_gaps),
        "unauth_ep": sum(1 for ep in entry_points if ep.get("auth_level") == "none"),
        "sensitive_sinks": sum(1 for sink in sinks if sink.get("category") in sensitive_categories),
        "sql_sinks": breakdown["sql"],
        "rest_json_sources": sum(1 for src in sources if src.get("type") in {"rest_json", "rest_body", "rest_body_params"}),
        "output_sinks": breakdown["output"],
        "source_count": len(sources),
        "sink_count": len(sinks),
        "sensitive_sink_breakdown": breakdown,
    }


def signal_score_for_metrics(metrics: dict[str, Any]) -> int:
    score = 0
    score += int(metrics.get("unauth_ep", 0)) * 4
    score += int(metrics.get("sensitive_sinks", 0)) * 2
    score += int(metrics.get("sql_sinks", 0)) * 3
    score += int(metrics.get("rest_json_sources", 0)) * 2
    score += int(metrics.get("coverage_gaps", 0)) * 3

    entry_points = int(metrics.get("entry_points", 0))
    anomalies = int(metrics.get("anomalies", 0))
    source_count = int(metrics.get("source_count", 0))
    sink_count = int(metrics.get("sink_count", 0))
    output_sinks = int(metrics.get("output_sinks", 0))

    if entry_points >= 5:
        score += 2
    elif entry_points >= 2:
        score += 1
    if anomalies >= 8:
        score += 2
    elif anomalies >= 4:
        score += 1
    if source_count >= 15:
        score += 1
    if sink_count >= 15:
        score += 1
    if output_sinks >= 8:
        score += 1
    return score


def adaptive_profile_for_metrics(metrics: dict[str, Any], signal_score: int) -> str:
    if (
        int(metrics.get("anomalies", 0)) == 0
        and int(metrics.get("unauth_ep", 0)) == 0
        and int(metrics.get("sensitive_sinks", 0)) == 0
        and int(metrics.get("sql_sinks", 0)) == 0
        and int(metrics.get("rest_json_sources", 0)) == 0
        and int(metrics.get("coverage_gaps", 0)) == 0
    ):
        return "quick-triage"

    if (
        int(metrics.get("coverage_gaps", 0)) >= 4
        or int(metrics.get("unauth_ep", 0)) >= 3
        or int(metrics.get("sql_sinks", 0)) >= 2
        or int(metrics.get("sensitive_sinks", 0)) >= 8
        or int(metrics.get("rest_json_sources", 0)) >= 8
        or signal_score >= 18
    ):
        return "deep-extended"

    if (
        int(metrics.get("coverage_gaps", 0)) >= 2
        or int(metrics.get("unauth_ep", 0)) >= 1
        or int(metrics.get("sql_sinks", 0)) >= 1
        or int(metrics.get("sensitive_sinks", 0)) >= 4
        or int(metrics.get("rest_json_sources", 0)) >= 4
        or int(metrics.get("anomalies", 0)) >= 6
        or signal_score >= 10
    ):
        return "deep-elevated"

    return "deep-standard"


def threat_context_signals(threat_context: dict[str, Any] | None) -> dict[str, Any]:
    if not threat_context:
        return {
            "matched_categories": [],
            "priority_vulns": [],
            "high_impact_priority_vulns": [],
        }
    matched_categories = [str(item) for item in threat_context.get("matched_categories", []) if str(item)]
    priority_vulns = [str(item) for item in threat_context.get("priority_vulns", []) if str(item)]
    high_impact = [item for item in priority_vulns if item in HIGH_IMPACT_PRIORITY_VULNS]
    return {
        "matched_categories": matched_categories,
        "priority_vulns": priority_vulns,
        "high_impact_priority_vulns": high_impact,
    }


def phase3_recommendation(stage_providers: dict[str, str]) -> dict[str, Any]:
    providers = ["codex"]
    skeptic = stage_providers.get("phase3_skeptic", "disabled")
    if skeptic == "claude":
        providers = ["codex", "claude"]
    return {
        "primary_provider": stage_providers.get("phase3_primary", "codex"),
        "providers": providers,
        "skeptic_enabled": skeptic != "disabled",
        "skeptic_provider": None if skeptic == "disabled" else skeptic,
    }


def normalize_provider_list(raw: str | list[str] | tuple[str, ...] | None) -> list[str]:
    if raw is None:
        return []
    if isinstance(raw, (list, tuple)):
        items = [str(item).strip().lower() for item in raw]
    else:
        items = [item.strip().lower() for item in str(raw).replace(",", " ").split()]
    providers: list[str] = []
    for item in items:
        if item in ALLOWED_PROVIDERS and item not in providers:
            providers.append(item)
    return providers


def fallback_policy_payload(
    slug: str,
    *,
    worker_provider: str,
    reviewer_core_provider: str,
    reviewer_explore_provider: str,
    cluster_synth_provider: str,
    cluster_challenger_provider: str,
    phase3_primary: str,
    phase3_providers: str | list[str] | tuple[str, ...] | None,
    adaptive_profile: str | None,
    signal_score: int | None,
    reasons: list[str],
    label: str = "resolver_failed_baseline",
) -> dict[str, Any]:
    normalized_phase3 = normalize_provider_list(phase3_providers)
    primary = str(phase3_primary or "").strip().lower()
    if primary not in ALLOWED_PROVIDERS:
        primary = normalized_phase3[0] if normalized_phase3 else "codex"
    if primary not in normalized_phase3:
        normalized_phase3.insert(0, primary)

    skeptic = "disabled"
    for provider in normalized_phase3:
        if provider != primary:
            skeptic = provider
            break

    stage_providers = {
        "worker": worker_provider,
        "reviewer_core": reviewer_core_provider,
        "reviewer_explore": reviewer_explore_provider,
        "cluster_synth": cluster_synth_provider,
        "cluster_challenger": cluster_challenger_provider,
        "phase3_primary": primary,
        "phase3_skeptic": skeptic,
    }
    return {
        "tier_id": "fallback",
        "tier_label": label,
        "high_value_potential": False,
        "adaptive_depth_profile": adaptive_profile or None,
        "signal_score": int(signal_score or 0),
        "metrics": {},
        "threat_context": {
            "matched_categories": [],
            "priority_vulns": [],
            "high_impact_priority_vulns": [],
        },
        "trigger_reasons": [str(item) for item in reasons if str(item)],
        "stage_providers": stage_providers,
        "phase3_recommendation": {
            "primary_provider": primary,
            "providers": normalized_phase3 or [primary],
            "skeptic_enabled": skeptic != "disabled",
            "skeptic_provider": None if skeptic == "disabled" else skeptic,
        },
    }


def base_policy_payload(slug: str, tier_id: str, metrics: dict[str, Any], adaptive_profile: str, signal_score: int, threat: dict[str, Any], reasons: list[str]) -> dict[str, Any]:
    stage_providers = dict(STAGE_PROVIDERS[tier_id])
    return {
        "tier_id": tier_id,
        "tier_label": TIER_LABELS[tier_id],
        "high_value_potential": TIER_ORDER[tier_id] >= TIER_ORDER["A2"],
        "adaptive_depth_profile": adaptive_profile,
        "signal_score": signal_score,
        "metrics": metrics,
        "threat_context": threat,
        "trigger_reasons": reasons,
        "stage_providers": stage_providers,
        "phase3_recommendation": phase3_recommendation(stage_providers),
    }


def resolve_prephase2_policy(slug: str, ir: dict[str, Any], threat_context: dict[str, Any] | None, adaptive_profile: str | None, signal_score: int | None) -> dict[str, Any]:
    metrics = phase2_metrics(ir)
    threat = threat_context_signals(threat_context)
    score = signal_score if signal_score is not None else signal_score_for_metrics(metrics)
    profile = adaptive_profile or adaptive_profile_for_metrics(metrics, score)
    reasons: list[str] = []

    if metrics["unauth_ep"] >= 1 and metrics["sql_sinks"] >= 1:
        reasons.append("unauth_plus_sql")
    if metrics["unauth_ep"] >= 1 and metrics["coverage_gaps"] >= 2:
        reasons.append("unauth_plus_coverage_gap")
    if metrics["sql_sinks"] >= 2:
        reasons.append("multiple_sql_sinks")
    if metrics["coverage_gaps"] >= 4:
        reasons.append("coverage_gap_heavy")
    if metrics["anomalies"] >= 8:
        reasons.append("anomaly_heavy")
    if score >= 18:
        reasons.append("signal_score_high")
    if profile == "deep-extended":
        reasons.append("adaptive_profile_deep_extended")
    if threat["high_impact_priority_vulns"]:
        reasons.append("threat_context_high_impact_priority")
    elif threat["matched_categories"]:
        reasons.append("threat_context_matched_category")

    if (
        threat["high_impact_priority_vulns"]
        and (
            profile == "deep-extended"
            or (metrics["unauth_ep"] >= 1 and metrics["sql_sinks"] >= 1)
            or (metrics["unauth_ep"] >= 1 and metrics["coverage_gaps"] >= 2)
        )
    ):
        tier_id = "A3"
    elif (
        profile == "deep-extended"
        or (metrics["unauth_ep"] >= 1 and metrics["sql_sinks"] >= 1)
        or (metrics["unauth_ep"] >= 1 and metrics["coverage_gaps"] >= 2)
        or metrics["sql_sinks"] >= 2
        or metrics["coverage_gaps"] >= 4
        or metrics["anomalies"] >= 8
        or score >= 18
        or (threat["high_impact_priority_vulns"] and profile in {"deep-elevated", "deep-extended"})
    ):
        tier_id = "A2"
    elif profile == "quick-triage":
        tier_id = "A0"
        if not reasons:
            reasons.append("low_signal_surface")
    else:
        tier_id = "A1"
        if not reasons:
            reasons.append("deep_codex_default")

    policy = base_policy_payload(slug, tier_id, metrics, profile, score, threat, reasons)
    policy["policy_version"] = "provider_strategy_v1"
    policy["decision_stage"] = "pre_phase2"
    return policy


def classify_finding_family(finding: dict[str, Any]) -> str:
    vuln = str(finding.get("vuln_type") or "").strip().lower()
    if any(token in vuln for token in ("sql", "sqli")):
        return "sqli"
    if any(token in vuln for token in ("privilege", "auth_bypass", "authorization", "idor", "bac")):
        return "authorization"
    if any(token in vuln for token in ("upload", "write", "delete", "traversal", "file_read", "download")):
        return "file_ops"
    if any(token in vuln for token in ("include", "lfi", "rfi")):
        return "include"
    if any(token in vuln for token in ("deserial", "object_injection", "serialize")):
        return "deserialization"
    if "ssrf" in vuln or "remote_request" in vuln:
        return "ssrf"
    if any(token in vuln for token in ("account_takeover", "password_reset", "user_impersonation")):
        return "account"
    return "generic"


def finding_signal_summary(worker_doc: dict[str, Any]) -> dict[str, Any]:
    findings = worker_doc.get("findings", []) or []
    high_impact = []
    very_high = []
    stored = 0
    families = set()
    for finding in findings:
        verdict = str(finding.get("verdict") or "").upper()
        if verdict not in {"TP", "REVIEW"}:
            continue
        family = classify_finding_family(finding)
        if family != "generic":
            high_impact.append(finding)
            families.add(family)
        if family in VERY_HIGH_IMPACT_FAMILIES:
            very_high.append(finding)
        vuln = str(finding.get("vuln_type") or "").lower()
        if "stored" in vuln or "second" in vuln or finding.get("storage_key"):
            stored += 1
    return {
        "high_impact_findings_count": len(high_impact),
        "very_high_impact_findings_count": len(very_high),
        "stored_or_second_order_count": stored,
        "high_impact_families": sorted(families),
    }


def review_signal_summary(review_doc: dict[str, Any] | None) -> dict[str, Any]:
    if not review_doc:
        return {
            "review_status": "not_reviewed",
            "finding_reviews_count": 0,
            "missed_findings_count": 0,
            "material_issues_found": False,
        }
    summary = review_doc.get("summary") if isinstance(review_doc.get("summary"), dict) else {}
    finding_reviews = review_doc.get("finding_reviews") if isinstance(review_doc.get("finding_reviews"), list) else []
    missed_findings = review_doc.get("missed_findings") if isinstance(review_doc.get("missed_findings"), list) else []
    material = bool(summary.get("material_issues_found")) or bool(missed_findings)
    for item in finding_reviews:
        if isinstance(item, dict) and item.get("assessment") not in {"keep", "field_fix"}:
            material = True
            break
    return {
        "review_status": str(review_doc.get("review_status") or "needs_revision"),
        "finding_reviews_count": len(finding_reviews),
        "missed_findings_count": len(missed_findings),
        "material_issues_found": material,
    }


def resolve_postreview_policy(policy_doc: dict[str, Any], worker_doc: dict[str, Any], review_doc: dict[str, Any] | None) -> dict[str, Any]:
    final = dict(policy_doc.get("final") or {})
    current_tier = str(final.get("tier_id") or policy_doc.get("pre_phase2", {}).get("tier_id") or "A0")
    worker_signals = finding_signal_summary(worker_doc)
    review_signals = review_signal_summary(review_doc)
    reasons: list[str] = []
    target_tier = current_tier

    review_unstable = review_signals["review_status"] != "stable"
    has_high_impact = worker_signals["high_impact_findings_count"] > 0
    has_very_high_impact = worker_signals["very_high_impact_findings_count"] > 0
    missed = review_signals["missed_findings_count"]
    material = bool(review_signals["material_issues_found"])

    if TIER_ORDER[target_tier] < TIER_ORDER["A2"] and has_high_impact and (review_unstable or material or missed > 0):
        target_tier = "A2"
        reasons.append("postreview_high_impact_ambiguity")

    if TIER_ORDER[target_tier] < TIER_ORDER["A3"] and (
        (has_very_high_impact and (review_unstable or material or missed > 0))
        or (worker_signals["stored_or_second_order_count"] > 0 and review_unstable)
        or (missed > 1 and has_high_impact)
    ):
        target_tier = "A3"
        reasons.append("postreview_high_value_escalation")

    stage_providers = dict(STAGE_PROVIDERS[target_tier])
    final_doc = dict(final)
    final_doc.update(
        {
            "tier_id": target_tier,
            "tier_label": TIER_LABELS[target_tier],
            "high_value_potential": TIER_ORDER[target_tier] >= TIER_ORDER["A2"],
            "stage_providers": stage_providers,
            "phase3_recommendation": phase3_recommendation(stage_providers),
        }
    )
    existing_reasons = [str(item) for item in final_doc.get("trigger_reasons", []) if str(item)]
    final_doc["trigger_reasons"] = sorted(dict.fromkeys(existing_reasons + reasons))

    post_review = {
        "previous_tier_id": current_tier,
        "resolved_tier_id": target_tier,
        "escalated": TIER_ORDER[target_tier] > TIER_ORDER[current_tier],
        "worker_signals": worker_signals,
        "review_signals": review_signals,
        "trigger_reasons": reasons,
    }

    policy_doc["post_review"] = post_review
    policy_doc["final"] = final_doc
    return policy_doc


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def cmd_prephase2(args: argparse.Namespace) -> int:
    reports_dir = Path(args.reports_dir).resolve()
    layout = build_report_layout(reports_dir).ensure()
    ir_path = Path(args.ir).resolve() if args.ir else layout.phase1 / f"{args.slug}-ir.json"
    threat_context_path = Path(args.threat_context).resolve() if args.threat_context else layout.threat_context(args.slug)
    ir = load_json(ir_path)
    threat_context = maybe_load_json(threat_context_path)
    policy = resolve_prephase2_policy(
        args.slug,
        ir,
        threat_context,
        args.adaptive_profile or None,
        int(args.signal_score) if args.signal_score not in (None, "") else None,
    )
    payload = {
        "version": "provider_strategy_v1",
        "generated_at": utc_now(),
        "slug": args.slug,
        "pre_phase2": policy,
        "post_review": None,
        "final": policy,
    }
    output = Path(args.output).resolve()
    write_json(output, payload)
    print(output.as_posix())
    return 0


def cmd_postreview(args: argparse.Namespace) -> int:
    policy_path = Path(args.policy).resolve()
    worker_output = Path(args.worker_output).resolve()
    review_output = Path(args.review_output).resolve() if args.review_output else None
    policy_doc = load_json(policy_path)
    worker_doc = load_json(worker_output)
    review_doc = maybe_load_json(review_output)
    resolved = resolve_postreview_policy(policy_doc, worker_doc, review_doc)
    output = Path(args.output).resolve() if args.output else policy_path
    write_json(output, resolved)
    print(output.as_posix())
    return 0


def cmd_fallback(args: argparse.Namespace) -> int:
    reasons = [part.strip() for part in str(args.reasons or "").split(",") if part.strip()]
    final = fallback_policy_payload(
        args.slug,
        worker_provider=args.worker_provider,
        reviewer_core_provider=args.reviewer_core_provider,
        reviewer_explore_provider=args.reviewer_explore_provider,
        cluster_synth_provider=args.cluster_synth_provider,
        cluster_challenger_provider=args.cluster_challenger_provider,
        phase3_primary=args.phase3_primary,
        phase3_providers=args.phase3_providers,
        adaptive_profile=args.adaptive_profile or None,
        signal_score=int(args.signal_score) if args.signal_score not in (None, "") else None,
        reasons=reasons or ["resolver_failed"],
        label=args.label or "resolver_failed_baseline",
    )
    payload = {
        "version": "provider_strategy_v1",
        "generated_at": utc_now(),
        "slug": args.slug,
        "pre_phase2": final,
        "post_review": None,
        "final": final,
    }
    output = Path(args.output).resolve()
    write_json(output, payload)
    print(output.as_posix())
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Resolve cost-aware provider strategy tiers.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    pre = sub.add_parser("prephase2", help="Resolve the pre-Phase-2 provider tier.")
    pre.add_argument("--slug", required=True)
    pre.add_argument("--reports-dir", required=True)
    pre.add_argument("--ir", default="")
    pre.add_argument("--threat-context", default="")
    pre.add_argument("--adaptive-profile", default="")
    pre.add_argument("--signal-score", default="")
    pre.add_argument("--output", required=True)
    pre.set_defaults(func=cmd_prephase2)

    post = sub.add_parser("postreview", help="Resolve post-review escalation for provider tiers.")
    post.add_argument("--policy", required=True)
    post.add_argument("--worker-output", required=True)
    post.add_argument("--review-output", default="")
    post.add_argument("--output", default="")
    post.set_defaults(func=cmd_postreview)

    fallback = sub.add_parser("fallback", help="Write a fallback provider policy artifact.")
    fallback.add_argument("--slug", required=True)
    fallback.add_argument("--output", required=True)
    fallback.add_argument("--worker-provider", required=True)
    fallback.add_argument("--reviewer-core-provider", required=True)
    fallback.add_argument("--reviewer-explore-provider", required=True)
    fallback.add_argument("--cluster-synth-provider", required=True)
    fallback.add_argument("--cluster-challenger-provider", required=True)
    fallback.add_argument("--phase3-primary", default="codex")
    fallback.add_argument("--phase3-providers", default="codex")
    fallback.add_argument("--adaptive-profile", default="")
    fallback.add_argument("--signal-score", default="0")
    fallback.add_argument("--reasons", default="resolver_failed")
    fallback.add_argument("--label", default="resolver_failed_baseline")
    fallback.set_defaults(func=cmd_fallback)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
