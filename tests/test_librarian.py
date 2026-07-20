import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE_PATH = Path(__file__).parents[1] / "rig-common-scripts" / "ai-rig-librarian.py"
SPEC = importlib.util.spec_from_file_location("ai_rig_librarian", MODULE_PATH)
lib = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lib)


class LibrarianTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.bundle = root / "understory" / "bundle"
        self.private = root / "librarian" / "agents"
        self.bundle.mkdir(parents=True)
        self.bundle_patch = patch.object(lib, "BUNDLE", self.bundle)
        self.private_patch = patch.object(lib, "PRIVATE", self.private)
        self.published_patch = patch.object(lib, "PUBLISHED", root / "librarian" / "published_ids.jsonl")
        self.bundle_patch.start(); self.private_patch.start(); self.published_patch.start()

    def tearDown(self):
        self.bundle_patch.stop(); self.private_patch.stop(); self.published_patch.stop(); self.temp.cleanup()

    def test_unverified_add_is_private_and_never_reaches_understory(self):
        with patch.object(lib, "upstream", side_effect=AssertionError("bypass")):
            result = lib.add({"content": "forse funziona", "source_agent": "devin",
                              "status": "candidate_success"})
        self.assertIn("Quarantined", result["content"][0]["text"])
        records = (self.private / "devin" / "quarantine.jsonl").read_text().splitlines()
        self.assertEqual(json.loads(records[0])["metadata"]["status"], "candidate_success")

    def test_verified_add_routes_only_to_shared_with_metadata(self):
        captured = {}
        with patch.object(lib, "upstream", side_effect=lambda name, args: captured.update(name=name, args=args) or {"content": []}):
            lib.add({"content": "Usare pytest", "source_agent": "devin",
                     "domain": "software-engineering", "status": "verified_success",
                     "evidence": "24 tests passed", "confidence": .9, "project": "demo"})
        self.assertEqual(captured["name"], "memory_add")
        self.assertEqual(captured["args"]["suggested_path"], "/shared/software-engineering/devin-demo.md")
        self.assertIn("evidence: 24 tests passed", captured["args"]["content"])
        self.assertTrue(lib.already_published(captured["args"]["content"].split("memory_id: ",1)[1].splitlines()[0]))

    def test_duplicate_memory_id_is_not_forwarded_twice(self):
        calls = []
        args = {"content": "lezione", "memory_id": "corr-fixed", "source_agent": "teacher",
                "domain": "gui-automation", "status": "verified_success", "evidence": "objective test",
                "confidence": .9, "project": "hueforge"}
        with patch.object(lib, "upstream", side_effect=lambda name, payload: calls.append(name) or {"content": []}):
            lib.add(args); result = lib.add(args)
        self.assertEqual(calls, ["memory_add"])
        self.assertIn("Already published", result["content"][0]["text"])

    def test_seed_reads_shared_but_not_private(self):
        domain = self.bundle / "shared" / "software-engineering"; domain.mkdir(parents=True)
        (domain / "lesson.md").write_text("---\ndescription: Test Python verificato\n---\n# Lesson")
        (self.private / "devin").mkdir(parents=True)
        (self.private / "devin" / "quarantine.jsonl").write_text('{"secret":"NON MOSTRARE"}\n')
        value = lib.seed()
        self.assertIn("Test Python verificato", value); self.assertNotIn("NON MOSTRARE", value)

    def test_update_requires_approval_and_evidence(self):
        with patch.object(lib, "upstream", side_effect=AssertionError("bypass")):
            result = lib.update({"instruction": "cambia il fatto", "source_agent": "hermes"})
        self.assertIn("quarantined", result["content"][0]["text"])
        self.assertTrue((self.private / "hermes" / "quarantine.jsonl").exists())

    def test_query_adds_shared_only_policy(self):
        captured = {}
        with patch.object(lib, "upstream", side_effect=lambda name, args: captured.update(name=name, args=args) or {}):
            lib.query({"question": "come controllo uno script?"})
        self.assertEqual(captured["name"], "memory_query")
        self.assertIn("only from /shared", captured["args"]["question"])
        self.assertIn("verified_failure is an anti-pattern", captured["args"]["question"])

    def test_seed_and_tools_are_mcp_compatible(self):
        compact = lib.instructions()
        self.assertIn("persistent federated memory", compact)
        self.assertIn("separate facts, hypotheses and unknowns", compact)
        self.assertIn("after two equivalent failures change strategy", compact)
        self.assertIn("publish only verified learning", compact)
        self.assertEqual({tool["name"] for tool in lib.TOOLS},
                         {"memory_query", "memory_add", "memory_update", "memory_status", "memory_maintain"})


if __name__ == "__main__":
    unittest.main()
