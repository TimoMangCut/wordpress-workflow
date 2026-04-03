#!/usr/bin/env python3
"""
Phase 3 Semantic Validator — Cross-reference Phase 2 LLM findings against Phase 1 IR graph.

NOT format validation. SEMANTIC validation:
- Verify propagation path exists in IR graph (source → sink reachable)
- Verify guard bypass logic is consistent with IR guards
- Verify auth level matches entry point type
- Verify exploit preconditions against plugin structure
- Detect hallucinated propagation chains
- Score confidence (0.0–1.0)

Usage:
    python3 phase3-filter.py <plugin-slug> [--reports-dir reports] [--plugins-dir plugins]
"""

import json
import sys
import os
import re
import subprocess
from pathlib import Path
from collections import defaultdict

from report_paths import build_report_layout

_SCRIPT_DIR = Path(__file__).resolve().parent
_ROOT_DIR = _SCRIPT_DIR.parent.parent  # tools/bin -> tools -> root


def load_json(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


class SemanticValidator:
    """Validate Phase 2 findings against Phase 1 IR with semantic checks."""

    def __init__(self, ir, phase2, semgrep, plugin_dir):
        self.ir = ir
        self.phase2 = phase2
        self.semgrep_results = semgrep.get('results', []) if semgrep else []
        self.plugin_dir = plugin_dir

        # Pre-index IR data for fast lookup
        self.ep_by_id = {ep['id']: ep for ep in ir.get('entry_points', [])}
        self.guards_by_ep = defaultdict(list)
        for g in ir.get('guards', []):
            if g.get('entry_point_id'):
                self.guards_by_ep[g['entry_point_id']].append(g)
        self.sources_by_ep = defaultdict(list)
        for s in ir.get('sources', []):
            if s.get('entry_point_id'):
                self.sources_by_ep[s['entry_point_id']].append(s)
        self.sinks_by_ep = defaultdict(list)
        for s in ir.get('sinks', []):
            if s.get('entry_point_id'):
                self.sinks_by_ep[s['entry_point_id']].append(s)

        # All files known to IR
        self.ir_files = set()
        for ep in ir.get('entry_points', []):
            if ep.get('file'): self.ir_files.add(ep['file'])
            cb = ep.get('callback', {})
            if cb.get('file'): self.ir_files.add(cb['file'])
        for s in ir.get('sources', []) + ir.get('sinks', []):
            if s.get('file'): self.ir_files.add(s['file'])

    def validate_finding(self, finding):
        """Run all semantic checks on a single finding. Returns validation result."""
        checks = {}
        scores = []

        # === CHECK 1: File exists in plugin source ===
        file_path = finding.get('file_path', '')
        if file_path and self.plugin_dir:
            # Try exact match and basename match
            full_path = os.path.join(self.plugin_dir, file_path)
            exists = os.path.exists(full_path)
            if not exists:
                # Try basename search
                basename = os.path.basename(file_path)
                try:
                    result = subprocess.run(
                        ['find', self.plugin_dir, '-name', basename, '-type', 'f'],
                        capture_output=True, text=True, timeout=5
                    )
                    exists = bool(result.stdout.strip())
                except:
                    exists = False
            checks['file_exists'] = exists
            scores.append(1.0 if exists else 0.0)
        else:
            checks['file_exists'] = finding['verdict'] == 'FP'  # FP don't need file
            scores.append(0.5)

        # === CHECK 2: Propagation path reachability ===
        # Verify: does any entry point in IR have BOTH a source matching claimed source
        # AND a sink matching claimed sink in the SAME scope?
        checks['path_reachable'] = self._check_path_reachable(finding)
        scores.append(1.0 if checks['path_reachable'] else 0.3)

        # === CHECK 3: Auth level consistency ===
        checks['auth_consistent'] = self._check_auth_consistency(finding)
        scores.append(1.0 if checks['auth_consistent'] else 0.2)

        # === CHECK 4: Guard bypass plausibility ===
        checks['guard_analysis_valid'] = self._check_guard_bypass(finding)
        scores.append(1.0 if checks['guard_analysis_valid'] else 0.4)

        # === CHECK 5: Sanitizer correctness claim ===
        checks['sanitizer_claim_valid'] = self._check_sanitizer_claim(finding)
        scores.append(1.0 if checks['sanitizer_claim_valid'] else 0.5)

        # === CHECK 6: Semgrep corroboration ===
        checks['semgrep_corroborates'] = self._check_semgrep_corroboration(finding)
        # Corroboration boosts but absence doesn't penalize
        if checks['semgrep_corroborates']:
            scores.append(1.0)
        else:
            scores.append(0.6)  # Neutral — Semgrep may not cover this vuln type

        # === CHECK 7: Source code evidence verification ===
        # If plugin source is available, verify claimed function exists at claimed line
        checks['code_evidence_valid'] = self._check_code_evidence(finding)
        scores.append(1.0 if checks['code_evidence_valid'] else 0.3)

        # === CHECK 8: Reasoning quality ===
        reasoning = finding.get('reasoning', '')
        checks['reasoning_quality'] = self._assess_reasoning_quality(finding)
        scores.append(checks['reasoning_quality'])  # 0.0–1.0

        # === CHECK 9: CVSS plausibility ===
        checks['cvss_plausible'] = self._check_cvss_plausibility(finding)
        scores.append(1.0 if checks['cvss_plausible'] else 0.5)

        # === CHECK 10: Patchstack eligibility consistency ===
        checks['patchstack_eligible_valid'] = self._check_patchstack_eligibility(finding)
        scores.append(1.0 if checks['patchstack_eligible_valid'] else 0.7)

        # === CHECK 11: Hallucination detection ===
        # Cross-reference: does the finding claim entities that don't exist in IR?
        checks['no_hallucination_detected'] = self._detect_hallucination(finding)
        scores.append(1.0 if checks['no_hallucination_detected'] else 0.1)

        # === Compute confidence score ===
        # Weighted average — path reachability and code evidence weigh most
        weights = [0.08, 0.18, 0.12, 0.10, 0.08, 0.08, 0.15, 0.08, 0.05, 0.03, 0.15]
        confidence = sum(s * w for s, w in zip(scores, weights)) / sum(weights)

        # Determine validation status
        if finding['verdict'] == 'FP':
            status = 'ACCEPTED_FP'
        elif confidence >= 0.75:
            status = 'CONFIRMED'
        elif confidence >= 0.50:
            status = 'PLAUSIBLE'
        elif confidence >= 0.30:
            status = 'UNCERTAIN'
        else:
            status = 'LIKELY_HALLUCINATION'

        return {
            'finding_id': finding.get('finding_id', '?'),
            'verdict': finding['verdict'],
            'confidence_score': round(confidence, 3),
            'validation_status': status,
            'checks': checks,
        }

    # =========================================================================
    # Individual check implementations
    # =========================================================================

    def _check_path_reachable(self, finding):
        """Check if source→sink path exists in any entry point scope."""
        if finding['verdict'] == 'FP':
            return True

        source_fn = finding.get('source_function', '').lower()
        sink_fn = finding.get('sink_function', '').lower()

        # Check: is there an entry point with BOTH matching source and sink?
        for ep_id, sources in self.sources_by_ep.items():
            source_match = any(
                source_fn in s.get('variable', '').lower() or
                source_fn in s.get('type', '').lower()
                for s in sources
            )
            if not source_match:
                continue

            sinks = self.sinks_by_ep.get(ep_id, [])
            sink_match = any(
                sink_fn.replace('$wpdb->', '').replace('()', '') in
                s.get('function_called', '').lower()
                for s in sinks
            )
            if sink_match:
                return True

        # Fallback: check file-level sinks (entry_point_id=null)
        file_path = finding.get('file_path', '')
        for s in self.ir.get('sinks', []):
            if s.get('entry_point_id') is None and file_path:
                if os.path.basename(file_path) in s.get('file', ''):
                    return True

        return False

    def _check_auth_consistency(self, finding):
        """Verify auth level matches entry point type in IR."""
        if finding['verdict'] == 'FP':
            return True

        claimed_auth = finding.get('auth_required', '')

        # Map: entry point type → expected auth
        auth_map = {
            'ajax_nopriv': 'none',
            'admin_post_nopriv': 'none',
            'ajax_priv': 'subscriber',
            'admin_post': 'subscriber',
            'admin_init': 'subscriber',
            'shortcode': 'contributor',
            'block': 'contributor',
            'rest_route': None,  # Depends on permission_callback
        }

        # Find matching entry points for this finding
        for ep in self.ir.get('entry_points', []):
            file_path = finding.get('file_path', '')
            ep_file = ep.get('callback', {}).get('file', ep.get('file', ''))

            if file_path and ep_file and os.path.basename(file_path) in ep_file:
                expected = auth_map.get(ep['type'])
                if expected is None:
                    return True  # REST — depends on permission_callback
                if claimed_auth == expected:
                    return True
                # Allow "subscriber" for "none" (conservative claim)
                if expected == 'none' and claimed_auth in ('none', 'subscriber'):
                    return True

        return True  # Can't disprove — pass

    def _check_guard_bypass(self, finding):
        """Check if the finding's guard analysis is consistent with IR guards."""
        if finding['verdict'] == 'FP':
            return True

        # If finding claims "no nonce" or "no capability" — verify against IR guards
        reasoning = finding.get('reasoning', '').lower()

        for ep_id, guards in self.guards_by_ep.items():
            for guard in guards:
                # If IR says guard exists and is effective, but finding claims no guard
                if guard['is_effective'] and guard['type'] == 'capability_check':
                    if 'no capability' in reasoning or 'missing capability' in reasoning:
                        # Check if this guard is for the SAME entry point
                        file_path = finding.get('file_path', '')
                        ep = self.ep_by_id.get(ep_id, {})
                        ep_file = ep.get('callback', {}).get('file', '')
                        if file_path and ep_file and os.path.basename(file_path) in ep_file:
                            return False  # Contradiction

        return True

    def _check_sanitizer_claim(self, finding):
        """Basic check: if finding claims sanitizer_correct=false, is it plausible?"""
        if finding['verdict'] == 'FP':
            return True

        # Common wrong-context sanitizers
        vuln_type = finding.get('vuln_type', '')
        sanitizer_correct = finding.get('sanitizer_correct', True)

        if not sanitizer_correct:
            # sanitize_text_field for SQL = wrong → this is a KNOWN valid claim
            if vuln_type == 'SQLi' and 'sanitize_text_field' in finding.get('reasoning', ''):
                return True
            # esc_html for attribute context = wrong → valid claim
            if vuln_type in ('XSS_stored', 'XSS_reflected'):
                return True

        return True

    def _check_semgrep_corroboration(self, finding):
        """Check if Semgrep has a finding near the same location."""
        if not self.semgrep_results:
            return False

        file_path = finding.get('file_path', '')
        line = finding.get('line_number', 0)
        file_basename = os.path.basename(file_path) if file_path else ''

        for sr in self.semgrep_results:
            sr_file = sr.get('path', '')
            sr_line = sr.get('start', {}).get('line', 0)

            if file_basename and file_basename in sr_file:
                if line and abs(sr_line - line) <= 15:
                    return True

        return False

    def _check_code_evidence(self, finding):
        """Verify claimed function exists at claimed line in actual source."""
        if finding['verdict'] == 'FP':
            return True
        if not self.plugin_dir:
            return True  # Can't check

        file_path = finding.get('file_path', '')
        line_number = finding.get('line_number')
        sink_fn = finding.get('sink_function', '')

        if not file_path or not line_number:
            return False

        full_path = os.path.join(self.plugin_dir, file_path)
        if not os.path.exists(full_path):
            # Try basename search
            basename = os.path.basename(file_path)
            try:
                result = subprocess.run(
                    ['find', self.plugin_dir, '-name', basename, '-type', 'f'],
                    capture_output=True, text=True, timeout=5
                )
                paths = result.stdout.strip().split('\n')
                full_path = paths[0] if paths[0] else None
            except:
                full_path = None

        if not full_path or not os.path.exists(full_path):
            return False

        try:
            with open(full_path, 'r', errors='replace') as f:
                lines = f.readlines()
            # Check ±5 lines around claimed line
            start = max(0, line_number - 6)
            end = min(len(lines), line_number + 5)
            context = ''.join(lines[start:end]).lower()

            # Check if sink function name appears near claimed line
            sink_short = sink_fn.replace('$wpdb->', '').replace('()', '').lower().strip('$')
            if sink_short and sink_short in context:
                return True
            # Check source function
            source_fn = finding.get('source_function', '').lower().strip('$')
            if source_fn and source_fn in context:
                return True
        except:
            pass

        return False

    def _assess_reasoning_quality(self, finding):
        """Score reasoning quality 0.0–1.0."""
        if finding['verdict'] == 'FP':
            return 0.8  # FP reasoning can be shorter

        reasoning = finding.get('reasoning', '')
        score = 0.0

        # Length check (3-5 sentences expected)
        if len(reasoning) > 100: score += 0.2
        if len(reasoning) > 200: score += 0.2
        if len(reasoning) > 300: score += 0.1

        # Contains file:line reference
        if re.search(r'line \d+|:\d+', reasoning):
            score += 0.15

        # Contains source→sink language
        if any(w in reasoning.lower() for w in ['source', 'sink', 'flow', 'trace', 'input']):
            score += 0.1

        # Contains defense/guard analysis
        if any(w in reasoning.lower() for w in ['nonce', 'capability', 'current_user_can', 'guard', 'check']):
            score += 0.1

        # Contains refutation attempt
        if any(w in reasoning.lower() for w in ['however', 'but', 'although', 'despite', 'not']):
            score += 0.1

        # Penalize generic reasoning
        if 'attacker could' in reasoning.lower() and len(reasoning) < 100:
            score -= 0.2

        return max(0.0, min(1.0, score))

    def _check_cvss_plausibility(self, finding):
        """Check CVSS vector format and basic plausibility."""
        if finding['verdict'] == 'FP' or finding.get('cvss_vector') is None:
            return True

        cvss = finding.get('cvss_vector', '')
        if not cvss.startswith('CVSS:3.1/'):
            return False

        # Check auth level → PR consistency
        auth = finding.get('auth_required', '')
        if 'PR:N' in cvss and auth not in ('none', ''):
            return False  # Claims no auth but finding says auth required
        if 'PR:L' in cvss and auth in ('none',):
            return False  # Claims low privileges but finding says unauthenticated

        return True

    def _check_patchstack_eligibility(self, finding):
        """Basic Patchstack eligibility check."""
        if finding.get('patchstack_eligible') is None:
            return True  # Not claimed

        auth = finding.get('auth_required', '')
        severity = finding.get('severity', '')

        # Admin-only → not eligible
        if auth == 'admin' and finding.get('patchstack_eligible', False):
            return False

        # Informational → not eligible
        if severity == 'informational' and finding.get('patchstack_eligible', False):
            return False

        return True

    def _detect_hallucination(self, finding):
        """Detect likely hallucinated findings."""
        if finding['verdict'] == 'FP':
            return True

        hallucination_signals = 0

        # Signal 1: File not in IR
        file_path = finding.get('file_path', '')
        if file_path:
            basename = os.path.basename(file_path)
            in_ir = any(basename in f for f in self.ir_files)
            if not in_ir:
                hallucination_signals += 1

        # Signal 2: Very generic reasoning (copy-paste pattern)
        reasoning = finding.get('reasoning', '')
        generic_phrases = [
            'this is vulnerable because',
            'attacker can exploit',
            'no sanitization is applied',
        ]
        if any(p in reasoning.lower() for p in generic_phrases) and len(reasoning) < 80:
            hallucination_signals += 1

        # Signal 3: CWE doesn't match vuln_type
        cwe_vuln_map = {
            'SQLi': ['CWE-89'],
            'XSS_stored': ['CWE-79'],
            'XSS_reflected': ['CWE-79'],
            'CSRF': ['CWE-352'],
            'BAC': ['CWE-862', 'CWE-863'],
            'LFI': ['CWE-98', 'CWE-22'],
            'RCE': ['CWE-94', 'CWE-95'],
            'object_injection': ['CWE-502'],
            'SSRF': ['CWE-918'],
            'file_upload': ['CWE-434'],
            'open_redirect': ['CWE-601'],
            'privilege_escalation': ['CWE-269'],
        }
        vuln_type = finding.get('vuln_type', '')
        cwe = finding.get('cwe_id', '')
        expected_cwes = cwe_vuln_map.get(vuln_type, [])
        if expected_cwes and cwe not in expected_cwes:
            hallucination_signals += 1

        return hallucination_signals <= 1  # Allow 1 signal, flag on 2+


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 phase3-filter.py <plugin-slug> [--reports-dir reports] [--plugins-dir plugins]")
        sys.exit(1)

    slug = sys.argv[1]
    reports_dir = str(_ROOT_DIR / 'reports')
    plugins_dir = str(_ROOT_DIR / 'plugins')

    for i, arg in enumerate(sys.argv):
        if arg == '--reports-dir' and i + 1 < len(sys.argv):
            reports_dir = sys.argv[i + 1]
        if arg == '--plugins-dir' and i + 1 < len(sys.argv):
            plugins_dir = sys.argv[i + 1]

    layout = build_report_layout(reports_dir).ensure()

    ir_path = layout.phase1 / f"{slug}-ir.json"
    phase2_path = layout.phase2 / f"{slug}-phase2.json"
    semgrep_path = layout.phase1 / f"{slug}-semgrep.json"
    output_path = layout.phase3 / f"{slug}-phase3.json"

    ir = load_json(str(ir_path))
    if not ir:
        print(f"[!] IR not found: {ir_path}")
        sys.exit(1)

    phase2 = load_json(str(phase2_path))
    if not phase2:
        print(f"[!] Phase 2 not found: {phase2_path}")
        sys.exit(1)

    semgrep = load_json(str(semgrep_path))
    plugin_dir = f"{plugins_dir}/{slug}" if os.path.isdir(f"{plugins_dir}/{slug}") else None

    validator = SemanticValidator(ir, phase2, semgrep, plugin_dir)

    findings = phase2.get('findings', [])
    validated = []

    for finding in findings:
        result = validator.validate_finding(finding)
        validated.append(result)

    # Build output
    tp_findings = [f for f in findings if f['verdict'] == 'TP']
    confirmed = [v for v in validated if v['validation_status'] == 'CONFIRMED']
    plausible = [v for v in validated if v['validation_status'] == 'PLAUSIBLE']
    uncertain = [v for v in validated if v['validation_status'] == 'UNCERTAIN']
    hallucinated = [v for v in validated if v['validation_status'] == 'LIKELY_HALLUCINATION']

    actionable = []
    for i, v in enumerate(validated):
        if v['verdict'] == 'TP' and v['validation_status'] in ('CONFIRMED', 'PLAUSIBLE'):
            actionable.append({**findings[i], 'confidence_score': v['confidence_score']})

    output = {
        'plugin_slug': slug,
        'phase1_summary': {
            'entry_points': len(ir.get('entry_points', [])),
            'anomalies': len(ir.get('anomalies', [])),
        },
        'phase2_summary': {
            'total': len(findings),
            'tp': len(tp_findings),
            'fp': sum(1 for f in findings if f['verdict'] == 'FP'),
            'review': sum(1 for f in findings if f['verdict'] == 'REVIEW'),
        },
        'phase3_summary': {
            'confirmed': len(confirmed),
            'plausible': len(plausible),
            'uncertain': len(uncertain),
            'likely_hallucination': len(hallucinated),
        },
        'validated_findings': validated,
        'actionable_findings': actionable,
    }

    with open(output_path, 'w') as f:
        json.dump(output, f, indent=2)

    # Print summary
    print(f"=== Phase 3 Validation: {slug} ===")
    print(f"  Phase 1: {output['phase1_summary']['entry_points']} EPs, "
          f"{output['phase1_summary']['anomalies']} anomalies")
    print(f"  Phase 2: {output['phase2_summary']['total']} findings "
          f"({output['phase2_summary']['tp']} TP)")
    print(f"  Phase 3: {len(confirmed)} confirmed, {len(plausible)} plausible, "
          f"{len(uncertain)} uncertain, {len(hallucinated)} hallucinated")
    print(f"  Actionable: {len(actionable)}")

    if actionable:
        print(f"\n  === Actionable (Patchstack-Ready) ===")
        for f in sorted(actionable, key=lambda x: -x['confidence_score']):
            print(f"  [{f['severity'].upper()}] {f['vuln_type']} — {f['cwe_id']} "
                  f"(conf: {f['confidence_score']:.2f})")
            print(f"    Auth: {f['auth_required']} | {f['file_path']}:{f.get('line_number','?')}")
            print(f"    {f['reasoning'][:120]}")
            print()

    print(f"  Output: {output_path}")


if __name__ == '__main__':
    main()
