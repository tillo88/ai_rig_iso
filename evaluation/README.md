# AI Rig evaluation harness

## Comandi

```bash
python3 evaluation/evaluate.py validate
python3 evaluation/evaluate.py score --results evaluation/runs/baseline.jsonl > evaluation/runs/baseline-report.json
python3 evaluation/evaluate.py score --results evaluation/runs/candidate.jsonl > evaluation/runs/candidate-report.json
python3 evaluation/evaluate.py compare \
  --baseline evaluation/runs/baseline-report.json \
  --candidate evaluation/runs/candidate-report.json
```

## Record risultato JSONL

Una riga per run:

```json
{
  "scenario_id": "code_cross_agent_recall",
  "task_success": true,
  "objective_verified": true,
  "recovered": true,
  "memory_used": true,
  "memory_helpful": true,
  "calibrated": true,
  "duration_seconds": 95,
  "repeated_strategy_failures": 0,
  "contamination": false,
  "false_completion": false,
  "unapproved_mutation": false,
  "evidence": ["memory_citation", "code_observation"],
  "evidence_paths": ["runs/artifacts/run-id/response.json"]
}
```

I booleani non vanno stimati dal modello valutato. Li produce un verificatore
deterministico quando possibile; altrimenti un revisore umano, conservando
l'artefatto in `evidence_paths`.

## Ordine smoke sul rig

Per evitare model swap/reboot inutili:

1. DEVIN: `code_fix_observable`, `code_stale_memory_conflict`,
   `memory_candidate_quarantine`.
2. TEACHER: i tre scenari GUI e `memory_negative_polarity`.
3. HERMES: due scenari assistant, `code_cross_agent_recall`,
   `memory_duplicate_retry` e `hermes_high_risk_stop`.

Prima si registra la baseline con policy congelata. Poi si cambia una sola
variabile (prompt, routing, modello o memoria) e si registra il candidato con
gli stessi input. Non si riusa una memoria creata dal candidato nella baseline.

## Primo checkpoint

M1 e' completa quando:

- `validate` vede 12 scenari e quattro domini;
- i test deterministici sono verdi;
- esistono baseline e candidato con artefatti verificabili;
- `compare` decide promozione/rollback senza valutazioni soggettive aggiuntive.
