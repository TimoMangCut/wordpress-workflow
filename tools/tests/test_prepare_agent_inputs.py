import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tools" / "bin" / "prepare_agent_inputs.py"

spec = importlib.util.spec_from_file_location("prepare_agent_inputs", MODULE_PATH)
prepare_agent_inputs = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(prepare_agent_inputs)


class PrepareAgentInputsTests(unittest.TestCase):
    def test_authorization_candidates_chunk_into_5_and_2(self):
        ir = {
            "metadata": {"plugin_slug": "demo"},
            "entry_points": [],
            "sources": [],
            "sinks": [],
            "guards": [],
            "anomalies": [],
            "unresolved_hooks": [],
            "coverage_gaps": [],
        }
        for idx in range(7):
            ep_id = f"ep_rest_{idx}"
            ir["entry_points"].append(
                {
                    "id": ep_id,
                    "type": "rest_route",
                    "auth_level": "none",
                    "file": f"src/Routes{idx}.php",
                    "callback": {"file": f"src/Routes{idx}.php"},
                }
            )
            ir["sources"].append(
                {
                    "id": f"src_{idx}",
                    "entry_point_id": ep_id,
                    "type": "rest_body",
                    "file": f"src/Routes{idx}.php",
                }
            )
            ir["sinks"].append(
                {
                    "id": f"sink_{idx}",
                    "entry_point_id": ep_id,
                    "category": "option_update",
                    "file": f"src/Routes{idx}.php",
                }
            )

        candidates = prepare_agent_inputs.build_candidates(ir, [], [])
        bundles = prepare_agent_inputs.pack_candidate_bundles(candidates)
        sizes = [len(bundle["candidates"]) for bundle in bundles]
        self.assertEqual(sizes, [5, 2])
        self.assertTrue(all(bundle["bug_family"] == "authorization" for bundle in bundles))

    def test_unmatched_semgrep_hit_becomes_orphan_candidate(self):
        ir = {
            "metadata": {"plugin_slug": "demo"},
            "entry_points": [
                {
                    "id": "ep_init",
                    "type": "init",
                    "auth_level": "none",
                    "file": "src/Init.php",
                    "callback": {"file": "src/Init.php"},
                }
            ],
            "sources": [],
            "sinks": [],
            "guards": [],
            "anomalies": [],
            "unresolved_hooks": [],
            "coverage_gaps": [],
        }
        semgrep_hits = [
            {
                "key": "sg-1",
                "path": "src/Admin/View.php",
                "line": 10,
                "check_id": "tools.rules.wp-xss-echo-no-escape",
                "message": "XSS output sink",
                "severity": "WARNING",
                "bug_family": "xss",
            }
        ]
        candidates = prepare_agent_inputs.build_candidates(ir, semgrep_hits, [])
        orphan_candidates = [candidate for candidate in candidates if candidate["kind"] == "semgrep_orphan"]
        self.assertEqual(len(orphan_candidates), 1)
        self.assertEqual(orphan_candidates[0]["bug_family"], "xss")
        self.assertEqual(orphan_candidates[0]["source_focus_files"], ["src/Admin/View.php"])


if __name__ == "__main__":
    unittest.main()
