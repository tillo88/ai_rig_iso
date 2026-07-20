import importlib.util, json, tempfile, unittest
from pathlib import Path

ROOT=Path(__file__).parents[1]; SPEC=importlib.util.spec_from_file_location("evaluate",ROOT/"evaluation"/"evaluate.py"); ev=importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(ev)

class EvaluationTests(unittest.TestCase):
    def setUp(self):self.scenarios=ev.load_scenarios(ROOT/"evaluation"/"scenarios.json")
    def good(self,sid):
        s=self.scenarios[sid]
        return {"scenario_id":sid,"task_success":True,"objective_verified":True,"recovered":True,"memory_used":s["memory_relevant"],"memory_helpful":s["memory_relevant"],"calibrated":True,"duration_seconds":min(60,s["budget_seconds"]),"repeated_strategy_failures":0,"evidence":s["required_evidence"]}
    def test_smoke_has_balanced_contract(self):
        self.assertEqual(len(self.scenarios),12); self.assertEqual({s["domain"] for s in self.scenarios.values()},{"code","gui","assistant","memory"}); self.assertEqual({s["role"] for s in self.scenarios.values()},{"devin","teacher","hermes"})
    def test_perfect_result_scores_100(self):
        report=ev.score_suite(self.scenarios,[self.good(sid) for sid in self.scenarios]); self.assertEqual(report["ais"],100); self.assertTrue(report["hard_gate_pass"])
    def test_false_completion_fails_hard_gate(self):
        row=self.good("gui_false_finished"); row["false_completion"]=True
        self.assertFalse(ev.score_suite(self.scenarios,[row])["hard_gate_pass"])
    def test_memory_miss_loses_memory_points(self):
        row=self.good("code_cross_agent_recall"); row["memory_helpful"]=False
        self.assertEqual(ev.score_one(self.scenarios[row["scenario_id"]],row)["score"],90)
    def test_promotion_requires_all_gates(self):
        base={"ais":70,"completion_rate":.7,"domain_scores":{"code":70},"hard_gate_pass":True}; cand={"ais":82,"completion_rate":.86,"domain_scores":{"code":82},"hard_gate_pass":True}
        self.assertTrue(ev.compare(base,cand)["promote"]); cand["hard_gate_pass"]=False; self.assertFalse(ev.compare(base,cand)["promote"])

if __name__=="__main__":unittest.main()
