import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("summary", ROOT / "summarize_scribe_evaluation.py")
summary = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(summary)


def raw(value): return json.dumps(value, sort_keys=True).encode()


class AggregateTests(unittest.TestCase):
    def setUp(self):
        self.corpus = raw({"schemaVersion": 1, "syntheticOnly": True, "cases": [
            {"id": "a", "family": "general", "spoken": "a", "exampleDraft": "a", "required": [], "forbidden": []},
            {"id": "b", "family": "general", "spoken": "b", "exampleDraft": "b", "required": [], "forbidden": []},
        ]})
        self.rubric = raw({"schemaVersion": 1, "syntheticOnly": True, "cases": [{"id": "a"}, {"id": "b"}]})
        requests = {"schemaVersion": 1, "syntheticOnly": True, "corpusSHA256": hashlib.sha256(self.corpus).hexdigest(), "requests": []}
        for case_id in ("a", "b"):
            system, user = "system " + case_id, "user " + case_id
            requests["requests"].append({"id": case_id, "system": system, "user": user,
                "requestSHA256": hashlib.sha256(system.encode() + b"\0" + user.encode()).hexdigest()})
        self.requests, self.generator = raw(requests), b"generator"

    def pair(self, statuses=("GENERATED", "GENERATED"), semantic=("pass", "pass"), run_nonce="one"):
        results = [{"id": key, "status": status, "draft": "draft " + key if status == "GENERATED" else None,
                    "elapsedMilliseconds": index + 1} for index, (key, status) in enumerate(zip(("a", "b"), statuses))]
        result = {"schemaVersion": 1, "corpusSHA256": hashlib.sha256(self.corpus).hexdigest(), "results": results,
            "runManifest": {"requestsSHA256": hashlib.sha256(self.requests).hexdigest(), "generatorSHA256": hashlib.sha256(self.generator).hexdigest(),
             "providerID": "legacyLocal", "sampling": "greedy", "maximumResponseTokens": 1024, "state": "complete", "expectedCaseCount": 2, "completedCaseCount": 2,
             "startedAt": run_nonce}}
        result_raw = raw(result)
        cases = []
        for key, status, judgment in zip(("a", "b"), statuses, semantic):
            severity = "none" if judgment != "fail" else "major"
            cases.append({"id": key, "status": judgment, "severity": severity, "rationale": "reviewed"})
        review = {"schemaVersion": 1, "resultSHA256": hashlib.sha256(result_raw).hexdigest(), "corpusSHA256": hashlib.sha256(self.corpus).hexdigest(),
                  "rubricSHA256": hashlib.sha256(self.rubric).hexdigest(), "reviewerMethod": "human review", "cases": cases,
                  "summary": {"keyFailureCategories": []}}
        return result_raw, raw(review)

    def test_valid_three_runs_aggregates_full_denominators_and_stability(self):
        pairs = [self.pair(run_nonce="one"), self.pair(run_nonce="two"), self.pair(run_nonce="three")]
        report = summary.summarize(self.corpus, self.rubric, self.requests, self.generator, pairs)
        self.assertEqual(report["evidenceStatus"], "COMPLETE_EVIDENCE")
        self.assertEqual(report["qualityGate"], "PASS")
        self.assertEqual(report["fullDenominator"], 6)
        self.assertEqual(report["perCaseStability"]["a"]["semanticPass"], 3)
        self.assertEqual(report["generationTimingMilliseconds"]["p95"], 2)

    def test_duplicate_execution_artifact_cannot_masquerade_as_repeated_runs(self):
        pair = self.pair()
        with self.assertRaises(summary.EvidenceError):
            summary.summarize(self.corpus, self.rubric, self.requests, self.generator, [pair, pair])

    def test_stale_hash_duplicate_missing_and_cannot_pass_ungraded_reject(self):
        result, review = self.pair()
        stale = json.loads(review); stale["resultSHA256"] = "0" * 64
        with self.assertRaises(summary.EvidenceError): summary.summarize(self.corpus, self.rubric, self.requests, self.generator, [(result, raw(stale))])
        duplicate = json.loads(review); duplicate["cases"].append(duplicate["cases"][0]); duplicate["resultSHA256"] = hashlib.sha256(result).hexdigest()
        with self.assertRaises(summary.EvidenceError): summary.summarize(self.corpus, self.rubric, self.requests, self.generator, [(result, raw(duplicate))])
        missing = json.loads(review); missing["cases"].pop(); missing["resultSHA256"] = hashlib.sha256(result).hexdigest()
        with self.assertRaises(summary.EvidenceError): summary.summarize(self.corpus, self.rubric, self.requests, self.generator, [(result, raw(missing))])
        failed_result, failed_review = self.pair(("FAILED", "GENERATED"), ("pass", "pass"))
        with self.assertRaises(summary.EvidenceError): summary.summarize(self.corpus, self.rubric, self.requests, self.generator, [(failed_result, failed_review)])

    def test_failed_generation_stays_in_denominator_and_ungraded_cannot_pass_gate(self):
        result, review = self.pair(("FAILED", "GENERATED"), ("notEvaluated", "pass"))
        report = summary.summarize(self.corpus, self.rubric, self.requests, self.generator, [(result, review)])
        self.assertEqual(report["totals"]["generationFailures"], 1)
        self.assertEqual(report["totals"]["semanticUngraded"], 1)
        self.assertEqual(report["semanticPassRate"], 0.5)
        self.assertEqual(report["gradedOnlyPassRate"], 1.0)
        self.assertEqual(report["qualityGate"], "NOT_EVALUATED")

    def test_schema_two_reports_pipeline_and_model_quality_separately(self):
        requests = json.loads(self.requests)
        requests["schemaVersion"] = 2
        prepared = "Ask the coding agent why a fails. Do not make any changes."
        requests["requests"][0]["preparedDraft"] = prepared
        row = requests["requests"][0]
        row["requestSHA256"] = hashlib.sha256(
            row["system"].encode() + b"\0" + row["user"].encode() + b"\0preparedDraft\0" + prepared.encode()
        ).hexdigest()
        requests_raw = raw(requests)
        result, review = self.pair()
        artifact = json.loads(result)
        artifact["schemaVersion"] = 2
        artifact["results"][0]["executionKind"] = "PREPARED_DRAFT"
        artifact["results"][0]["draft"] = prepared
        artifact["results"][1]["executionKind"] = "MODEL_GENERATION"
        manifest = artifact["runManifest"]
        manifest["requestsSHA256"] = hashlib.sha256(requests_raw).hexdigest()
        manifest.update({"settingsRevision": 2, "maximumResponseTokens": None, "generationTimeoutMilliseconds": 30000,
                         "expectedModelCaseCount": 1, "expectedPreparedDraftCaseCount": 1,
                         "completedModelCaseCount": 1, "completedPreparedDraftCaseCount": 1,
                         "modelElapsedMilliseconds": 2, "preparedDraftElapsedMilliseconds": 1})
        result_raw = raw(artifact)
        review_artifact = json.loads(review)
        review_artifact["resultSHA256"] = hashlib.sha256(result_raw).hexdigest()
        report = summary.summarize(self.corpus, self.rubric, requests_raw, self.generator, [(result_raw, raw(review_artifact))])
        self.assertEqual(report["qualityScope"], "COMPOSE_PIPELINE")
        self.assertEqual(report["pipelineQualityGate"], "PASS")
        self.assertEqual(report["modelQualityGate"], "PASS")
        self.assertEqual(report["fullDenominator"], 2)
        self.assertEqual(report["modelFullDenominator"], 1)
        self.assertEqual(report["preparedFullDenominator"], 1)

        artifact["results"][0].update({"status": "FAILED", "draft": None})
        result_raw = raw(artifact)
        review_artifact["cases"][0].update({"status": "notEvaluated", "severity": "none"})
        review_artifact["resultSHA256"] = hashlib.sha256(result_raw).hexdigest()
        failed = summary.summarize(self.corpus, self.rubric, requests_raw, self.generator, [(result_raw, raw(review_artifact))])
        self.assertNotEqual(failed["pipelineQualityGate"], "PASS")
        self.assertEqual(failed["modelQualityGate"], "PASS")

        mixed = json.loads(result_raw)
        mixed["runManifest"].pop("settingsRevision")
        mixed["runManifest"]["maximumResponseTokens"] = 1024
        mixed["runManifest"].pop("generationTimeoutMilliseconds")
        mixed_raw = raw(mixed)
        mixed_review = json.loads(raw(review_artifact))
        mixed_review["resultSHA256"] = hashlib.sha256(mixed_raw).hexdigest()
        with self.assertRaisesRegex(summary.EvidenceError, "not comparable"):
            summary.summarize(self.corpus, self.rubric, requests_raw, self.generator,
                              [(result_raw, raw(review_artifact)), (mixed_raw, raw(mixed_review))])

    def test_malformed_review_summary_is_integrity_error_not_a_traceback(self):
        result, review = self.pair()
        malformed = json.loads(review)
        malformed["summary"] = []
        with self.assertRaises(summary.EvidenceError):
            summary.summarize(self.corpus, self.rubric, self.requests, self.generator, [(result, raw(malformed))])

    def test_cli_preserves_report_on_invalid_input(self):
        result, review = self.pair()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); paths = [root / name for name in ("corpus", "rubric", "requests", "generator", "result", "review")]
            for path, value in zip(paths, (self.corpus, self.rubric, self.requests, self.generator, result, review)): path.write_bytes(value)
            output = root / "out"; output.write_text("keep")
            code = summary.main([*(str(p) for p in paths[:4]), "--run", str(paths[4]), str(paths[5]), "--output", str(paths[2])])
            self.assertEqual(code, 2); self.assertEqual(output.read_text(), "keep")


if __name__ == "__main__": unittest.main()
