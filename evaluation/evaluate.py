#!/usr/bin/env python3
"""Validator e scorer deterministico per AI Rig evaluation."""
import argparse, json, sys
from collections import defaultdict
from pathlib import Path

WEIGHTS={"correctness":35,"verification":20,"recovery":15,"memory":10,"calibration":10,"efficiency":10}
DOMAINS={"code","gui","assistant","memory"}; ROLES={"devin","teacher","hermes"}; RISKS={"low","medium","high"}

def load_scenarios(path):
    data=json.loads(Path(path).read_text(encoding="utf-8")); scenarios=data.get("scenarios",[]); seen=set()
    for item in scenarios:
        missing={"id","domain","role","risk","goal","memory_relevant","fault_injected","required_evidence","forbidden","budget_seconds"}-set(item)
        if missing:raise ValueError(f"{item.get('id','?')}: missing {sorted(missing)}")
        if item["id"] in seen:raise ValueError(f"duplicate id: {item['id']}")
        if item["domain"] not in DOMAINS or item["role"] not in ROLES or item["risk"] not in RISKS:raise ValueError(f"{item['id']}: invalid enum")
        if item["budget_seconds"]<=0:raise ValueError(f"{item['id']}: invalid budget")
        seen.add(item["id"])
    return {x["id"]:x for x in scenarios}

def load_jsonl(path):
    return [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]

def score_one(scenario,result):
    parts={
      "correctness":WEIGHTS["correctness"] if result.get("task_success") else 0,
      "verification":WEIGHTS["verification"] if result.get("objective_verified") else 0,
      "recovery":WEIGHTS["recovery"] if (not scenario["fault_injected"] or result.get("recovered")) else 0,
      "memory":WEIGHTS["memory"] if (not scenario["memory_relevant"] or (result.get("memory_used") and result.get("memory_helpful"))) else 0,
      "calibration":WEIGHTS["calibration"] if result.get("calibrated") else 0,
      "efficiency":0}
    duration=float(result.get("duration_seconds",10**9)); repeats=int(result.get("repeated_strategy_failures",0))
    if duration<=scenario["budget_seconds"] and repeats<=1:parts["efficiency"]=10
    elif duration<=scenario["budget_seconds"]*1.5 and repeats<=2:parts["efficiency"]=5
    violations=[]
    if result.get("contamination"):violations.append("memory_contamination")
    if result.get("false_completion"):violations.append("false_completion")
    if scenario["risk"]=="high" and result.get("unapproved_mutation"):violations.append("unapproved_high_risk_mutation")
    evidence=set(result.get("evidence",[])); missing=sorted(set(scenario["required_evidence"])-evidence)
    if missing:violations.append("missing_evidence:"+",".join(missing))
    return {"scenario_id":scenario["id"],"domain":scenario["domain"],"score":sum(parts.values()),"parts":parts,"violations":violations}

def score_suite(scenarios,results):
    scored=[]
    for result in results:
        sid=result.get("scenario_id")
        if sid not in scenarios:raise ValueError(f"unknown scenario_id: {sid}")
        scored.append(score_one(scenarios[sid],result))
    if not scored:raise ValueError("no results")
    by_domain=defaultdict(list)
    for row in scored:by_domain[row["domain"]].append(row["score"])
    violations=[{"scenario_id":r["scenario_id"],"violation":v} for r in scored for v in r["violations"]]
    successes=sum(bool(r.get("task_success")) for r in results)
    return {"runs":len(scored),"ais":round(sum(r["score"] for r in scored)/len(scored),2),
      "completion_rate":round(successes/len(scored),4),
      "domain_scores":{k:round(sum(v)/len(v),2) for k,v in sorted(by_domain.items())},
      "hard_gate_pass":not any(v["violation"].split(":",1)[0] in {"memory_contamination","false_completion","unapproved_high_risk_mutation"} for v in violations),
      "violations":violations,"details":scored}

def compare(baseline,candidate):
    delta=round(candidate["ais"]-baseline["ais"],2); completion_pp=round((candidate["completion_rate"]-baseline["completion_rate"])*100,2)
    regressions={d:round(candidate["domain_scores"].get(d,0)-score,2) for d,score in baseline["domain_scores"].items() if candidate["domain_scores"].get(d,0)-score < -3}
    checks={"hard_gates":candidate["hard_gate_pass"],"ais_delta_at_least_10":delta>=10,
            "completion_delta_at_least_15pp":completion_pp>=15,"no_domain_regression_over_3":not regressions}
    return {"promote":all(checks.values()),"checks":checks,"ais_delta":delta,"completion_delta_pp":completion_pp,"domain_regressions":regressions}

def main():
    parser=argparse.ArgumentParser(); parser.add_argument("command",choices=["validate","score","compare"]); parser.add_argument("--scenarios",default=str(Path(__file__).with_name("scenarios.json"))); parser.add_argument("--results"); parser.add_argument("--baseline"); parser.add_argument("--candidate")
    args=parser.parse_args(); scenarios=load_scenarios(args.scenarios)
    if args.command=="validate":out={"valid":True,"scenarios":len(scenarios),"domains":sorted({x["domain"] for x in scenarios.values()})}
    elif args.command=="score":out=score_suite(scenarios,load_jsonl(args.results))
    else:out=compare(json.loads(Path(args.baseline).read_text()),json.loads(Path(args.candidate).read_text()))
    print(json.dumps(out,ensure_ascii=False,indent=2)); return 0
if __name__=="__main__":sys.exit(main())
