import json
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]


class CognitivePolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.policy = json.loads((ROOT / "config" / "cognitive-policy.json").read_text())

    def test_complete_reasoning_loop(self):
        self.assertEqual(self.policy["loop"],
                         ["recall", "frame", "plan", "act", "verify", "reflect", "publish"])

    def test_self_report_never_counts_as_evidence(self):
        self.assertTrue(self.policy["rules"]["self_report_is_not_evidence"])
        self.assertTrue(self.policy["rules"]["verify_before_claiming_completion"])

    def test_depth_and_anti_loop_are_bounded(self):
        depth = self.policy["adaptive_depth"]
        self.assertLess(depth["low"]["max_plan_steps"], depth["medium"]["max_plan_steps"])
        self.assertLess(depth["medium"]["max_plan_steps"], depth["high"]["max_plan_steps"])
        self.assertEqual(self.policy["anti_loop"]["same_strategy_failures_before_change"], 2)
        self.assertTrue(self.policy["anti_loop"]["require_new_evidence_for_retry"])

    def test_hermes_is_connected_only_through_librarian(self):
        rendered = (ROOT / "rig-roles" / "hermes" / "scripts" / "40-hermes-extras.sh").read_text()
        self.assertIn('url: "http://localhost:3810/mcp"', rendered)
        self.assertNotIn("@verygoodplugins/mcp-automem", rendered)


if __name__ == "__main__":
    unittest.main()
