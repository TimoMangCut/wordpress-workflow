import json
import pathlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "bin"))

from phase3_review_contract import normalize_phase3_review_document, validate_phase3_review_file


class Phase3ReviewContractTests(unittest.TestCase):
    def test_normalize_accepts_valid_review_document(self) -> None:
        normalized = normalize_phase3_review_document(
            {
                "plugin_slug": "demo",
                "reviews": [
                    {
                        "finding_id": "f-1",
                        "original_status": "uncertain",
                        "verdict_change": "KEEP",
                        "proposed_final_state": "risk_note",
                    }
                ],
            },
            slug="demo",
        )
        self.assertEqual(normalized["plugin_slug"], "demo")
        self.assertEqual(normalized["reviews"][0]["original_status"], "UNCERTAIN")
        self.assertEqual(normalized["reviews"][0]["verdict_change"], "keep")
        self.assertEqual(normalized["reviews"][0]["proposed_final_state"], "RISK_NOTE")

    def test_normalize_rejects_missing_plugin_slug(self) -> None:
        with self.assertRaisesRegex(ValueError, "plugin_slug"):
            normalize_phase3_review_document({"reviews": []}, slug="demo")

    def test_validate_file_rejects_invalid_verdict_change(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "review.json"
            path.write_text(
                json.dumps(
                    {
                        "plugin_slug": "demo",
                        "reviews": [
                            {
                                "finding_id": "f-1",
                                "original_status": "UNCERTAIN",
                                "verdict_change": "confirm",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "verdict_change"):
                validate_phase3_review_file(path, slug="demo")


if __name__ == "__main__":
    unittest.main()
