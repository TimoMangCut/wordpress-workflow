import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class Phase2PromptBoundaryTests(unittest.TestCase):
    def _read(self, relative_path: str) -> str:
        return (ROOT / relative_path).read_text(encoding="utf-8")

    def test_exploration_prompt_is_bounded_to_codex_blind_spots(self) -> None:
        prompt = self._read("tools/config/phase2-exploration-prompt-template.md")
        self.assertIn("bounded second-pass over Codex coverage gaps", prompt)
        self.assertIn("Do not restart whole-plugin hunting from raw IR/AST/SAST signals", prompt)
        self.assertIn("Every extra file open must answer a concrete question tied to an existing lead", prompt)
        self.assertIn("second-order or deferred sink behavior", prompt)

    def test_explore_system_prompt_requires_existing_lead_based_expansion(self) -> None:
        prompt = self._read("tools/config/system-prompt-phase2-review-explore.md")
        self.assertIn("bounded blind spots that the Codex worker and core review may have missed", prompt)
        self.assertIn("You may expand only when testing a concrete blind spot already suggested by the current input", prompt)
        self.assertIn("Do not grep broadly just to hunt for new findings", prompt)

    def test_cluster_challenge_prompt_stays_synth_bounded(self) -> None:
        prompt = self._read("tools/config/phase2-cluster-challenge-prompt-template.md")
        self.assertIn("Treat the synthesis output and cluster pack as the working map of what Codex already covered", prompt)
        self.assertIn("Do not re-audit the whole cluster member path from scratch", prompt)
        self.assertIn("Every out-of-band file open must be justified by an existing synth objection", prompt)
        self.assertIn("Once you have enough evidence to confirm, refute, or narrow the exact synth question, write the JSON immediately", prompt)

    def test_system_prompts_are_now_english_only_for_phase2_phase3_set(self) -> None:
        system_prompts = [
            "tools/config/system-prompt-phase2.md",
            "tools/config/system-prompt-phase2-review.md",
            "tools/config/system-prompt-phase2-review-core.md",
            "tools/config/system-prompt-phase2-review-explore.md",
            "tools/config/system-prompt-phase2-review-terminal.md",
            "tools/config/system-prompt-phase2-revision.md",
            "tools/config/system-prompt-phase3.md",
        ]
        legacy_markers = ["Ban la", "Hay ap dung", "Khong duoc", "Nhiem vu", "Yeu cau output", "Quy tac bat buoc"]
        for relative_path in system_prompts:
            text = self._read(relative_path)
            for marker in legacy_markers:
                self.assertNotIn(marker, text, msg=f"{relative_path} still contains legacy Vietnamese marker: {marker}")

    def test_runtime_fallback_prompt_strings_are_english_only(self) -> None:
        runtime_files = [
            "tools/bin/run-phase2.sh",
            "tools/bin/phase3-validate.py",
            "tools/bin/phase3_llm_review.py",
        ]
        legacy_markers = ["Ban la", "Hay ap dung", "Khong duoc", "Nhiem vu", "Yeu cau output", "Quy tac bat buoc"]
        for relative_path in runtime_files:
            text = self._read(relative_path)
            for marker in legacy_markers:
                self.assertNotIn(marker, text, msg=f"{relative_path} still contains legacy Vietnamese marker: {marker}")
