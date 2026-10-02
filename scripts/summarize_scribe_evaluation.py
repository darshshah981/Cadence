#!/usr/bin/env python3
"""Aggregate hash-bound synthetic Compose runs and declared semantic reviews.

Semantic reviews are human/agent-assisted evidence, not deterministic proof or
authentication that a model execution occurred. The default 95%/zero-critical
research gate is provisional and is not a universal quality claim.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import sys
import tempfile

SCORER_PATH = Path(__file__).with_name("score_scribe_instructions.py")
SPEC = importlib.util.spec_from_file_location("scribe_scorer", SCORER_PATH)
scorer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scorer)
EvidenceError = scorer.EvidenceError


def decode(raw, label):
    return scorer._decode(raw, label)


def sha(raw): return hashlib.sha256(raw).hexdigest()
def text(value, label): return scorer._text(value, label)
def version(value, label): return scorer._version_one(value, label)


def percentile(values, fraction):
    values = sorted(values)
    return values[math.ceil(len(values) * fraction) - 1]


def fixture_ids(corpus_raw):
    corpus = decode(corpus_raw, "Corpus")
    if not isinstance(corpus, dict): raise EvidenceError("Corpus must be an object.")
    version(corpus.get("schemaVersion"), "corpus")
    if corpus.get("syntheticOnly") is not True: raise EvidenceError("Corpus must declare syntheticOnly true.")
    cases = corpus.get("cases")
    if not isinstance(cases, list) or not cases: raise EvidenceError("Corpus must contain cases.")
    ids = [text(case.get("id") if isinstance(case, dict) else None, "Corpus case ID") for case in cases]
    if len(set(ids)) != len(ids): raise EvidenceError("Corpus contains duplicate IDs.")
    return ids


def validate_rubric(raw, expected_ids):
    rubric = decode(raw, "Rubric")
    if not isinstance(rubric, dict): raise EvidenceError("Rubric must be an object.")
    version(rubric.get("schemaVersion"), "rubric")
    if rubric.get("syntheticOnly") is not True: raise EvidenceError("Rubric must declare syntheticOnly true.")
    cases = rubric.get("cases")
    if not isinstance(cases, list): raise EvidenceError("Rubric must contain cases.")
    ids = [text(case.get("id") if isinstance(case, dict) else None, "Rubric case ID") for case in cases]
    if len(set(ids)) != len(ids) or set(ids) != set(expected_ids): raise EvidenceError("Rubric cases must exactly match corpus cases.")


def validate_review(raw, result_raw, corpus_raw, rubric_raw, generation_by_id, expected_ids):
    review = decode(raw, "Semantic review")
    if not isinstance(review, dict): raise EvidenceError("Semantic review must be an object.")
    version(review.get("schemaVersion"), "semantic review")
    for key, expected in (("resultSHA256", sha(result_raw)), ("corpusSHA256", sha(corpus_raw)), ("rubricSHA256", sha(rubric_raw))):
        if review.get(key) != expected: raise EvidenceError("Semantic review hash does not match supplied evidence.")
    text(review.get("reviewerMethod"), "Semantic reviewer method")
    cases = review.get("cases")
    if not isinstance(cases, list): raise EvidenceError("Semantic review must contain cases.")
    indexed = {}
    for case in cases:
        if not isinstance(case, dict): raise EvidenceError("Semantic review case must be an object.")
        case_id = text(case.get("id"), "Semantic review ID")
        if case_id in indexed or case_id not in expected_ids: raise EvidenceError("Semantic review has duplicate or unknown IDs.")
        status, severity = case.get("status"), case.get("severity")
        if status not in ("pass", "fail", "notEvaluated") or severity not in ("none", "minor", "major", "critical"):
            raise EvidenceError("Semantic review has unsupported status or severity.")
        text(case.get("rationale"), "Semantic review rationale")
        generated = generation_by_id[case_id] == "GENERATED"
        if status == "pass" and (not generated or severity != "none"):
            raise EvidenceError("Only generated cases with severity none can pass semantic review.")
        if status == "fail" and (not generated or severity == "none"):
            raise EvidenceError("Semantic failures require generated output and a non-none severity.")
        if status == "notEvaluated" and severity != "none":
            raise EvidenceError("Unevaluated semantic cases must have severity none.")
        if not generated and status != "notEvaluated":
            raise EvidenceError("Failed generation cannot receive a semantic pass or fail.")
        indexed[case_id] = case
    if set(indexed) != set(expected_ids): raise EvidenceError("Semantic review is missing corpus cases.")
    review_summary = review.get("summary", {})
    if not isinstance(review_summary, dict): raise EvidenceError("Semantic review summary must be an object.")
    categories = review_summary.get("keyFailureCategories", [])
    if not isinstance(categories, list): raise EvidenceError("Semantic review failure categories must be a list.")
    category_counts, categorized_ids = {}, set()
    for category in categories:
        if not isinstance(category, dict): raise EvidenceError("Semantic failure category must be an object.")
        name = text(category.get("category"), "Semantic failure category")
        ids = category.get("caseIDs")
        if not isinstance(ids, list) or not ids or any(not isinstance(case_id, str) for case_id in ids) or len(ids) != len(set(ids)):
            raise EvidenceError("Semantic failure category IDs are invalid.")
        if any(case_id not in expected_ids for case_id in ids): raise EvidenceError("Semantic failure category has unknown case ID.")
        if any(indexed[case_id]["status"] != "fail" or indexed[case_id]["severity"] != "critical" for case_id in ids):
            raise EvidenceError("Critical failure categories must reference critical semantic failures.")
        if categorized_ids.intersection(ids): raise EvidenceError("Critical failure cases must have one category.")
        categorized_ids.update(ids)
        if type(category.get("count")) is not int or category["count"] != len(ids): raise EvidenceError("Semantic failure category count is invalid.")
        text(category.get("detail"), "Semantic failure category detail")
        category_counts[name] = category_counts.get(name, 0) + len(ids)
    critical_ids = {case_id for case_id, case in indexed.items() if case["status"] == "fail" and case["severity"] == "critical"}
    if categorized_ids != critical_ids: raise EvidenceError("Every critical semantic failure requires one category.")
    return indexed, category_counts


def summarize(corpus_raw, rubric_raw, requests_raw, generator_raw, pairs, threshold=.95, max_critical=0):
    if not 0 <= threshold <= 1 or type(max_critical) is not int or max_critical < 0:
        raise EvidenceError("Research gate threshold and critical limit are invalid.")
    expected_ids = fixture_ids(corpus_raw)
    validate_rubric(rubric_raw, expected_ids)
    if not pairs: raise EvidenceError("At least one result and semantic review pair is required.")
    all_case_runs = {case_id: [] for case_id in expected_ids}
    totals = {"generationFailures": 0, "semanticPass": 0, "semanticFail": 0, "semanticUngraded": 0,
              "modelGenerationFailures": 0, "preparedDraftFailures": 0,
              "modelSemanticPass": 0, "modelSemanticFail": 0, "modelSemanticUngraded": 0,
              "preparedSemanticPass": 0, "preparedSemanticFail": 0, "preparedSemanticUngraded": 0}
    critical_categories, timings = {}, []
    seen_results, comparable_settings = set(), None
    request_envelope = decode(requests_raw, "Request export")
    if not isinstance(request_envelope, dict): raise EvidenceError("Request export must be an object.")
    request_schema = request_envelope.get("schemaVersion")
    scorer._version_one_or_two(request_schema, "request export")
    for result_raw, review_raw in pairs:
        result_hash = sha(result_raw)
        if result_hash in seen_results: raise EvidenceError("Repeated runs must use distinct result artifacts.")
        seen_results.add(result_hash)
        report = scorer.score(corpus_raw, result_raw, requests_bytes=requests_raw, generator_bytes=generator_raw)
        if report["generatorProvenance"] != "ARTIFACT_HASHES_MATCH": raise EvidenceError("Run artifacts are not exactly bound.")
        if comparable_settings is None:
            comparable_settings = report["generationSettings"]
        elif report["generationSettings"] != comparable_settings:
            raise EvidenceError("Runs use different generation settings and are not comparable.")
        result = decode(result_raw, "Results")
        generation = {row["id"]: row["status"] for row in result["results"]}
        execution = {row["id"]: row.get("executionKind", "MODEL_GENERATION") for row in result["results"]}
        review, categories = validate_review(review_raw, result_raw, corpus_raw, rubric_raw, generation, expected_ids)
        totals["generationFailures"] += report["summary"]["generationFailures"]
        totals["modelGenerationFailures"] += report["summary"]["modelGenerationFailures"]
        totals["preparedDraftFailures"] += report["summary"]["preparedDraftFailures"]
        timings.extend(row["elapsedMilliseconds"] for row in result["results"])
        for name, count in categories.items(): critical_categories[name] = critical_categories.get(name, 0) + count
        for case_id in expected_ids:
            semantic = review[case_id]["status"]
            if semantic == "pass": totals["semanticPass"] += 1
            elif semantic == "fail": totals["semanticFail"] += 1
            else: totals["semanticUngraded"] += 1
            prefix = "modelSemantic" if execution[case_id] == "MODEL_GENERATION" else "preparedSemantic"
            if semantic == "pass": totals[prefix + "Pass"] += 1
            elif semantic == "fail": totals[prefix + "Fail"] += 1
            else: totals[prefix + "Ungraded"] += 1
            all_case_runs[case_id].append({"generation": generation[case_id], "semantic": semantic,
                                            "severity": review[case_id]["severity"], "executionKind": execution[case_id]})
    full_denominator = len(pairs) * len(expected_ids)
    graded = totals["semanticPass"] + totals["semanticFail"]
    pass_rate = totals["semanticPass"] / full_denominator
    graded_only_pass_rate = totals["semanticPass"] / graded if graded else None
    model_denominator = totals["modelSemanticPass"] + totals["modelSemanticFail"] + totals["modelSemanticUngraded"]
    prepared_denominator = totals["preparedSemanticPass"] + totals["preparedSemanticFail"] + totals["preparedSemanticUngraded"]
    model_pass_rate = totals["modelSemanticPass"] / model_denominator if model_denominator else None
    prepared_pass_rate = totals["preparedSemanticPass"] / prepared_denominator if prepared_denominator else None
    stability = {case_id: {
        "runs": len(rows), "generated": sum(r["generation"] == "GENERATED" for r in rows),
        "semanticPass": sum(r["semantic"] == "pass" for r in rows),
        "semanticFail": sum(r["semantic"] == "fail" for r in rows),
        "semanticUngraded": sum(r["semantic"] == "notEvaluated" for r in rows),
        "modelGenerationRuns": sum(r["executionKind"] == "MODEL_GENERATION" for r in rows),
        "preparedDraftRuns": sum(r["executionKind"] == "PREPARED_DRAFT" for r in rows),
    } for case_id, rows in all_case_runs.items()}
    model_critical = sum(1 for case_id in expected_ids for row in all_case_runs[case_id]
                         if row["executionKind"] == "MODEL_GENERATION" and row["severity"] == "critical")
    # Severity is validated above; category totals are the critical count for the all-row pipeline gate.
    def gate(denominator, failures, ungraded, rate, critical):
        if denominator == 0 or ungraded:
            return "NOT_EVALUATED"
        return "PASS" if failures == 0 and rate >= threshold and critical <= max_critical else "FAIL"
    pipeline_quality = gate(full_denominator, totals["generationFailures"], totals["semanticUngraded"], pass_rate, sum(critical_categories.values()))
    model_quality = gate(model_denominator, totals["modelGenerationFailures"], totals["modelSemanticUngraded"], model_pass_rate, model_critical)
    quality_scope = "MODEL_GENERATION" if request_schema == 1 else "COMPOSE_PIPELINE"
    quality = model_quality if quality_scope == "MODEL_GENERATION" else pipeline_quality
    return {
        "schemaVersion": 1, "evidenceStatus": "COMPLETE_EVIDENCE", "qualityGate": quality, "qualityScope": quality_scope,
        "pipelineQualityGate": pipeline_quality, "modelQualityGate": model_quality,
        "generationSettings": comparable_settings,
        "researchGate": {"semanticPassRateThreshold": threshold, "maximumCriticalFailures": max_critical,
                         "provisional": True, "notUniversalQualityClaim": True},
        "runs": len(pairs), "casesPerRun": len(expected_ids), "fullDenominator": full_denominator,
        "totals": totals, "semanticPassRate": pass_rate, "gradedOnlyPassRate": graded_only_pass_rate,
        "modelFullDenominator": model_denominator, "modelSemanticPassRate": model_pass_rate,
        "preparedFullDenominator": prepared_denominator, "preparedSemanticPassRate": prepared_pass_rate,
        "criticalFailureCategories": critical_categories,
        "generationTimingMilliseconds": {"sampleCount": len(timings), "p50": percentile(timings, .5), "p95": percentile(timings, .95)},
        "perCaseStability": stability,
        "limitations": ["Semantic reviews are declared human or agent-assisted judgments, not deterministic proof.", "Matching artifacts do not authenticate real model execution.", "Prepared drafts are deterministic pipeline evidence and do not improve the model-only quality gate.", "Pipeline scope starts at synthetic compiled requests; it does not verify microphone capture, coordinator missing-source gating, consent UI, native insertion, or the installed app."]
    }


def write_atomic(path, content):
    handle = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False)
    temporary = Path(handle.name)
    try:
        handle.write(content); handle.close(); os.replace(temporary, path)
    finally: temporary.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path); parser.add_argument("rubric", type=Path)
    parser.add_argument("requests", type=Path); parser.add_argument("generator_source", type=Path)
    parser.add_argument("--run", action="append", nargs=2, metavar=("RESULTS", "REVIEW"), required=True)
    parser.add_argument("--output", type=Path); parser.add_argument("--threshold", type=float, default=.95)
    parser.add_argument("--max-critical", type=int, default=0)
    args = parser.parse_args(argv)
    try:
        inputs = [args.corpus, args.rubric, args.requests, args.generator_source] + [Path(x) for pair in args.run for x in pair]
        if args.output and any(args.output.resolve() == item.resolve() or (args.output.exists() and item.exists() and os.path.samefile(args.output, item)) for item in inputs):
            raise EvidenceError("Output must not overwrite an input file.")
        report = summarize(args.corpus.read_bytes(), args.rubric.read_bytes(), args.requests.read_bytes(), args.generator_source.read_bytes(),
                           [(Path(result).read_bytes(), Path(review).read_bytes()) for result, review in args.run], args.threshold, args.max_critical)
        rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
        if args.output: write_atomic(args.output, rendered)
        else: sys.stdout.write(rendered)
        return 0 if report["qualityGate"] == "PASS" else 1
    except (EvidenceError, OSError):
        print("Invalid aggregate evaluation evidence.", file=sys.stderr); return 2

if __name__ == "__main__": raise SystemExit(main())
