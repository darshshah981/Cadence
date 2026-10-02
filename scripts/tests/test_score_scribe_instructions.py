"""Behavioral checks for the offline synthetic Compose evaluation report."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "score_scribe_instructions.py"
SPEC = importlib.util.spec_from_file_location("score_scribe_instructions", MODULE_PATH)
scorer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scorer)


def encoded(value):
    return json.dumps(value).encode("utf-8")


class ScoreScribeInstructionsTests(unittest.TestCase):
    def setUp(self):
        self.corpus = {
            "schemaVersion": 1,
            "syntheticOnly": True,
            "cases": [{
                "id": "greeting", "family": "general",
                "spoken": "Hey, how's it going? Write this formally.",
                "exampleDraft": "Hello, how are you?",
                "required": ["Hello"], "forbidden": ["write this formally"],
            }],
        }
        self.results = [{"id": "greeting", "status": "GENERATED", "draft": "Hello, how are you?"}]

    def envelope(self, results=None, corpus_bytes=None):
        return {
            "schemaVersion": 1,
            "corpusSHA256": hashlib.sha256(corpus_bytes or encoded(self.corpus)).hexdigest(),
            "results": self.results if results is None else results,
        }

    def report(self):
        return scorer.score(encoded(self.corpus), encoded(self.envelope()))

    def request_export(self, requests=None, corpus_bytes=None):
        requests = requests or [{
            "id": "greeting", "system": "Synthetic system", "user": "Synthetic user",
        }]
        bound = []
        for request in requests:
            request = dict(request)
            request["requestSHA256"] = hashlib.sha256(
                request["system"].encode("utf-8") + b"\x00" + request["user"].encode("utf-8")
            ).hexdigest()
            bound.append(request)
        return encoded({
            "schemaVersion": 1,
            "syntheticOnly": True,
            "corpusSHA256": hashlib.sha256(corpus_bytes or encoded(self.corpus)).hexdigest(),
            "requests": bound,
        })

    def manifested_envelope(self, *, requests_bytes=None, generator_bytes=b"synthetic generator", results=None):
        requests_bytes = requests_bytes or self.request_export()
        complete_results = [dict(row, elapsedMilliseconds=17) for row in (results or self.results)]
        envelope = self.envelope(complete_results)
        envelope["runManifest"] = {
            "requestsSHA256": hashlib.sha256(requests_bytes).hexdigest(),
            "generatorSHA256": hashlib.sha256(generator_bytes).hexdigest(),
            "providerID": "legacyLocal",
            "sampling": "greedy",
            "maximumResponseTokens": 1024,
            "state": "complete",
            "expectedCaseCount": 1,
            "completedCaseCount": len(complete_results),
        }
        return envelope, requests_bytes, generator_bytes

    def test_bound_complete_run_is_mechanically_clear_but_semantically_ungraded(self):
        report = self.report()
        self.assertEqual(report["evidenceStatus"], "BOUND_COMPLETE")
        self.assertEqual(report["summary"]["expectedCases"], 1)
        self.assertEqual(report["summary"]["semanticCasesGraded"], 0)
        self.assertEqual(report["semanticQuality"], "UNGRADED")
        self.assertEqual(report["generatorProvenance"], "NOT_VERIFIED")
        self.assertEqual(scorer.report_exit_code(report), 0)

    def test_legacy_array_remains_unbound_even_with_all_cases(self):
        report = scorer.score(encoded(self.corpus), encoded(self.results))
        self.assertEqual(report["evidenceStatus"], "UNBOUND")
        self.assertEqual(scorer.report_exit_code(report), 1)

    def test_selected_source_without_advisory_annotations_keeps_original_binding(self):
        fixture = self.corpus["cases"][0]
        fixture["source"] = "Hey, how is it going?"
        for key in ("family", "required", "forbidden"): del fixture[key]
        corpus_bytes = encoded(self.corpus)
        envelope, requests, generator = self.manifested_envelope()
        report = scorer.score(corpus_bytes, encoded(envelope), requests_bytes=requests, generator_bytes=generator)
        self.assertEqual(report["corpusSHA256"], hashlib.sha256(corpus_bytes).hexdigest())
        self.assertEqual(report["generatorProvenance"], "ARTIFACT_HASHES_MATCH")
        self.assertEqual(report["cases"][0]["family"], "selectedRewrite")
        self.assertEqual(report["cases"][0]["advisoryPhraseCheckCount"], 0)
        self.assertEqual(report["semanticQuality"], "UNGRADED")

    def test_selected_shape_does_not_mask_partial_or_invalid_annotations(self):
        fixture = self.corpus["cases"][0]
        fixture["source"] = "A source."
        del fixture["required"]
        with self.assertRaises(scorer.EvidenceError): self.report()
        fixture["required"] = []
        fixture["source"] = " "
        with self.assertRaises(scorer.EvidenceError): self.report()

    def test_direct_fixture_cannot_omit_its_advisory_annotations(self):
        for key in ("family", "required", "forbidden"): del self.corpus["cases"][0][key]
        with self.assertRaises(scorer.EvidenceError): self.report()

    def test_changed_corpus_with_same_ids_rejects_stale_results(self):
        envelope = self.envelope()
        self.corpus["cases"][0]["spoken"] = "A different request."
        with self.assertRaisesRegex(scorer.EvidenceError, "hash does not match"):
            scorer.score(encoded(self.corpus), encoded(envelope))

    def test_missing_duplicate_and_unknown_result_ids_are_rejected(self):
        for results in ([], self.results * 2, [{"id": "unknown", "status": "FAILED"}]):
            with self.subTest(results=results), self.assertRaises(scorer.EvidenceError):
                scorer.score(encoded(self.corpus), encoded(self.envelope(results)))

    def test_failed_generation_stays_in_denominator_and_is_not_phrase_scored(self):
        self.results[0] = {"id": "greeting", "status": "FAILED", "draft": None}
        report = self.report()
        self.assertEqual(report["summary"]["expectedCases"], 1)
        self.assertEqual(report["summary"]["generationFailures"], 1)
        self.assertEqual(report["summary"]["casesWithoutPhraseWarnings"], 0)
        self.assertEqual(report["cases"][0]["mechanicalStatus"], "NOT_EVALUATED")
        self.assertEqual(scorer.report_exit_code(report), 1)

    def test_content_free_failure_categories_are_validated_and_preserved(self):
        self.results[0] = {"id": "greeting", "status": "FAILED", "draft": None,
                           "failureCategory": "timedOut"}
        report = self.report()
        self.assertEqual(report["cases"][0]["generationFailureCategory"], "timedOut")
        self.assertEqual(report["summary"]["generationFailureCategories"]["timedOut"], 1)
        self.assertEqual(report["summary"]["generationFailureCategories"]["unspecified"], 0)
        for invalid in [None, "prompt contents", "unavailable", 0]:
            self.results[0]["failureCategory"] = invalid
            with self.subTest(invalid=invalid), self.assertRaises(scorer.EvidenceError):
                self.report()
        self.results[0] = {"id": "greeting", "status": "GENERATED", "draft": "Hello",
                           "failureCategory": "busy"}
        with self.assertRaises(scorer.EvidenceError):
            self.report()

    def test_direction_leak_produces_advisory_finding(self):
        self.results[0]["draft"] = "HELLO. WRITE THIS FORMALLY."
        report = self.report()
        self.assertEqual(report["cases"][0]["matchedForbiddenPhrases"], ["write this formally"])
        self.assertEqual(report["cases"][0]["missingRequiredPhrases"], [])
        self.assertEqual(report["cases"][0]["semanticQuality"], "UNGRADED")
        self.assertEqual(scorer.report_exit_code(report), 1)

    def test_acceptable_paraphrase_is_not_declared_semantically_wrong(self):
        self.results[0]["draft"] = "Good morning, how are you?"
        report = self.report()
        self.assertEqual(report["cases"][0]["missingRequiredPhrases"], ["Hello"])
        self.assertEqual(report["cases"][0]["mechanicalStatus"], "WARNINGS")
        self.assertEqual(report["semanticQuality"], "UNGRADED")

    def test_empty_generated_draft_and_invalid_statuses_are_rejected(self):
        for result in (
            {"id": "greeting", "status": "GENERATED", "draft": "  "},
            {"id": "greeting", "status": "GENERATED"},
            {"id": "greeting", "status": "FAILED", "draft": "Partial output"},
            {"id": "greeting", "status": "SUCCESS", "draft": "Hello"},
            {"id": "greeting", "draft": "Hello"},
        ):
            with self.subTest(result=result), self.assertRaises(scorer.EvidenceError):
                scorer.score(encoded(self.corpus), encoded(self.envelope([result])))

    def test_corpus_requires_supported_schema_and_synthetic_declaration(self):
        for field, value in (("schemaVersion", 2), ("schemaVersion", True), ("syntheticOnly", False)):
            with self.subTest(field=field, value=value):
                corpus = {**self.corpus, field: value}
                with self.assertRaises(scorer.EvidenceError):
                    scorer.score(encoded(corpus), encoded(self.results))

    def test_result_envelope_requires_schema_and_exact_hash(self):
        for field, value in (("schemaVersion", 2), ("schemaVersion", True), ("corpusSHA256", ""), ("results", {})):
            with self.subTest(field=field), self.assertRaises(scorer.EvidenceError):
                scorer.score(encoded(self.corpus), encoded({**self.envelope(), field: value}))

    def test_duplicate_fixture_ids_and_malformed_phrase_lists_are_rejected(self):
        self.corpus["cases"] *= 2
        with self.assertRaises(scorer.EvidenceError):
            self.report()
        self.corpus["cases"] = self.corpus["cases"][:1]
        for phrases in (None, "hello", [""], [7]):
            self.corpus["cases"][0]["required"] = phrases
            with self.subTest(phrases=phrases), self.assertRaises(scorer.EvidenceError):
                self.report()

    def test_invalid_json_and_duplicate_json_keys_are_rejected_without_echoing_content(self):
        for raw in (b'{"private":', b'{"private":"CANARY", "private":"CANARY"}', b'\xff'):
            with self.subTest(raw=raw), self.assertRaises(scorer.EvidenceError) as error:
                scorer.score(raw, encoded(self.results))
            self.assertNotIn("CANARY", str(error.exception))

    def test_report_is_repeatable_and_omits_drafts_and_spoken_content(self):
        self.results[0]["draft"] += " SYNTHETIC_DRAFT_CANARY"
        first, second = self.report(), self.report()
        self.assertEqual(first, second)
        rendered = json.dumps(first)
        self.assertNotIn("SYNTHETIC_DRAFT_CANARY", rendered)
        self.assertNotIn(self.corpus["cases"][0]["spoken"], rendered)

    def test_existing_production_corpus_examples_are_not_a_model_quality_pass(self):
        corpus_path = MODULE_PATH.parent.parent / "CadenceTests/Fixtures/AdaptiveScribe/instruction-following.json"
        raw = corpus_path.read_bytes()
        corpus = json.loads(raw)
        results = [{"id": f["id"], "status": "GENERATED", "draft": f["exampleDraft"]} for f in corpus["cases"]]
        report = scorer.score(raw, encoded(self.envelope(results, raw)))
        self.assertEqual(report["summary"]["expectedCases"], len(corpus["cases"]))
        self.assertEqual(report["summary"]["semanticCasesGraded"], 0)
        self.assertTrue(all(c["semanticQuality"] == "UNGRADED" for c in report["cases"]))

    def test_run_manifest_declares_timing_and_exact_artifact_provenance(self):
        envelope, requests_bytes, generator_bytes = self.manifested_envelope()
        declared = scorer.score(encoded(self.corpus), encoded(envelope))
        self.assertEqual(declared["generatorProvenance"], "DECLARED_RUN_MANIFEST")
        self.assertEqual(declared["generationTiming"], {
            "sampleCount": 1, "p50Milliseconds": 17, "p95Milliseconds": 17,
            "includesFailedGenerations": True,
        })
        verified = scorer.score(
            encoded(self.corpus), encoded(envelope), requests_bytes=requests_bytes,
            generator_bytes=generator_bytes,
        )
        self.assertEqual(verified["generatorProvenance"], "ARTIFACT_HASHES_MATCH")

    def test_run_manifest_rejects_changed_request_or_generator_artifact(self):
        envelope, requests_bytes, generator_bytes = self.manifested_envelope()
        for changed_requests, changed_generator in (
            (requests_bytes + b" ", generator_bytes),
            (requests_bytes, generator_bytes + b" changed"),
        ):
            with self.subTest(changed_requests=changed_requests != requests_bytes):
                with self.assertRaisesRegex(scorer.EvidenceError, "hash does not match"):
                    scorer.score(encoded(self.corpus), encoded(envelope),
                                 requests_bytes=changed_requests, generator_bytes=changed_generator)

    def test_run_manifest_rejects_corrupt_or_incomplete_request_export(self):
        for mutation in ("corrupt-hash", "missing-id", "unknown-id"):
            exported = json.loads(self.request_export())
            if mutation == "corrupt-hash":
                exported["requests"][0]["requestSHA256"] = "0" * 64
            elif mutation == "missing-id":
                exported["requests"] = []
            else:
                exported["requests"][0]["id"] = "unknown"
            requests_bytes = encoded(exported)
            envelope, _, generator_bytes = self.manifested_envelope(requests_bytes=requests_bytes)
            with self.subTest(mutation=mutation), self.assertRaises(scorer.EvidenceError):
                scorer.score(encoded(self.corpus), encoded(envelope), requests_bytes=requests_bytes,
                             generator_bytes=generator_bytes)

    def test_run_manifest_rejects_partial_unavailable_and_invalid_metadata(self):
        envelope, requests_bytes, generator_bytes = self.manifested_envelope()
        invalid_manifests = [
            {"state": "running"},
            {"state": "unavailable"},
            {"expectedCaseCount": 2},
            {"completedCaseCount": 0},
            {"providerID": "cloud"},
            {"sampling": "random"},
            {"maximumResponseTokens": 512},
        ]
        for mutation in invalid_manifests:
            changed = json.loads(json.dumps(envelope))
            changed["runManifest"].update(mutation)
            with self.subTest(mutation=mutation), self.assertRaises(scorer.EvidenceError):
                scorer.score(encoded(self.corpus), encoded(changed), requests_bytes=requests_bytes,
                             generator_bytes=generator_bytes)
        unavailable = json.loads(json.dumps(envelope))
        unavailable["results"][0]["status"] = "UNAVAILABLE"
        unavailable["results"][0]["draft"] = None
        with self.assertRaisesRegex(scorer.EvidenceError, "status"):
            scorer.score(encoded(self.corpus), encoded(unavailable), requests_bytes=requests_bytes,
                         generator_bytes=generator_bytes)
        for invalid_elapsed in (-1, float("inf"), "17"):
            changed = json.loads(json.dumps(envelope))
            changed["results"][0]["elapsedMilliseconds"] = invalid_elapsed
            with self.subTest(elapsed=invalid_elapsed), self.assertRaises(scorer.EvidenceError):
                scorer.score(encoded(self.corpus), encoded(changed), requests_bytes=requests_bytes,
                             generator_bytes=generator_bytes)

    def test_schema_two_binds_prepared_draft_and_separates_execution_evidence(self):
        prepared = "Ask the coding agent why the café login fails. Do not make any changes."
        exported = json.loads(self.request_export())
        exported["schemaVersion"] = 2
        request = exported["requests"][0]
        request["preparedDraft"] = prepared
        request["requestSHA256"] = hashlib.sha256(
            request["system"].encode() + b"\0" + request["user"].encode()
            + b"\0preparedDraft\0" + prepared.encode()
        ).hexdigest()
        requests_bytes = encoded(exported)
        result = self.envelope([{
            "id": "greeting", "status": "GENERATED", "draft": prepared,
            "elapsedMilliseconds": 4, "executionKind": "PREPARED_DRAFT",
        }])
        result["schemaVersion"] = 2
        generator_bytes = b"synthetic generator"
        result["runManifest"] = {
            "requestsSHA256": hashlib.sha256(requests_bytes).hexdigest(),
            "generatorSHA256": hashlib.sha256(generator_bytes).hexdigest(),
            "providerID": "legacyLocal", "sampling": "greedy",
            "settingsRevision": 2, "maximumResponseTokens": None, "generationTimeoutMilliseconds": 30000,
            "state": "complete", "expectedCaseCount": 1, "completedCaseCount": 1,
            "expectedModelCaseCount": 0, "expectedPreparedDraftCaseCount": 1,
            "completedModelCaseCount": 0, "completedPreparedDraftCaseCount": 1,
            "modelElapsedMilliseconds": 0, "preparedDraftElapsedMilliseconds": 4,
        }
        report = scorer.score(encoded(self.corpus), encoded(result), requests_bytes=requests_bytes, generator_bytes=generator_bytes)
        self.assertEqual(report["cases"][0]["executionKind"], "PREPARED_DRAFT")
        self.assertEqual(report["summary"]["preparedDraftCases"], 1)
        self.assertEqual(report["generationTiming"]["preparedDraft"]["sampleCount"], 1)

        for draft in ("Ask the coding agent why the login fails. Do not make any changes.",
                      "Ask the coding agent why the cafe\u0301 login fails. Do not make any changes."):
            changed = json.loads(encoded(result))
            changed["results"][0]["draft"] = draft
            with self.subTest(draft=draft), self.assertRaisesRegex(scorer.EvidenceError, "Prepared-draft result bytes"):
                scorer.score(encoded(self.corpus), encoded(changed), requests_bytes=requests_bytes, generator_bytes=generator_bytes)
        changed = json.loads(encoded(result))
        changed["results"][0]["elapsedMilliseconds"] = 4.0
        changed["runManifest"]["preparedDraftElapsedMilliseconds"] = 4.0
        with self.assertRaisesRegex(scorer.EvidenceError, "integer milliseconds"):
            scorer.score(encoded(self.corpus), encoded(changed), requests_bytes=requests_bytes, generator_bytes=generator_bytes)

        for mutation in (
            ("requestHash",), ("method",), ("splitCount",), ("settingsMix",), ("schemaOnePrepared",),
        ):
            changed_export, changed_result = json.loads(requests_bytes), json.loads(encoded(result))
            if mutation[0] == "requestHash":
                changed_export["requests"][0]["requestSHA256"] = "0" * 64
            elif mutation[0] == "method":
                changed_result["results"][0]["executionKind"] = "MODEL_GENERATION"
            elif mutation[0] == "splitCount":
                changed_result["runManifest"]["expectedPreparedDraftCaseCount"] = 0
            elif mutation[0] == "settingsMix":
                changed_result["runManifest"]["maximumResponseTokens"] = 1024
            else:
                changed_export["schemaVersion"] = 1
            changed_requests = encoded(changed_export)
            changed_result["runManifest"]["requestsSHA256"] = hashlib.sha256(changed_requests).hexdigest()
            with self.subTest(mutation=mutation), self.assertRaises(scorer.EvidenceError):
                scorer.score(encoded(self.corpus), encoded(changed_result), requests_bytes=changed_requests,
                             generator_bytes=generator_bytes)

    def test_cli_requires_artifact_pair_and_protects_all_inputs_from_overwrite(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            corpus, results = root / "corpus.json", root / "results.json"
            requests, generator, output = root / "requests.json", root / "generator.swift", root / "report.json"
            corpus.write_bytes(encoded(self.corpus))
            envelope, request_bytes, generator_bytes = self.manifested_envelope()
            results.write_bytes(encoded(envelope))
            requests.write_bytes(request_bytes)
            generator.write_bytes(generator_bytes)
            output.write_text("preserve")
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(scorer.main([str(corpus), str(results), "--requests", str(requests), "--output", str(output)]), 2)
            self.assertEqual(output.read_text(), "preserve")
            for protected in (corpus, results, requests, generator):
                with self.subTest(protected=protected.name), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(scorer.main([
                        str(corpus), str(results), "--requests", str(requests),
                        "--generator-source", str(generator), "--output", str(protected),
                    ]), 2)

    def test_cli_writes_report_and_handles_invalid_evidence_without_overwriting_report(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            corpus, results, output = root / "corpus.json", root / "results.json", root / "report.json"
            corpus.write_bytes(encoded(self.corpus))
            results.write_bytes(encoded(self.envelope()))
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(scorer.main([str(corpus), str(results), "--output", str(output)]), 0)
            saved = output.read_bytes()
            results.write_text("not JSON")
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(scorer.main([str(corpus), str(results), "--output", str(output)]), 2)
            self.assertEqual(output.read_bytes(), saved)

    def test_cli_prevents_overwriting_input_including_hardlinks(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            corpus, results = root / "corpus.json", root / "results.json"
            corpus.write_bytes(encoded(self.corpus))
            results.write_bytes(encoded(self.envelope()))
            alias = root / "alias.json"
            os.link(corpus, alias)
            for output in (corpus, results, alias):
                with self.subTest(output=output), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(scorer.main([str(corpus), str(results), "--output", str(output)]), 2)
            self.assertEqual(corpus.read_bytes(), encoded(self.corpus))

    def test_cli_stdout_and_missing_file_outcomes(self):
        with tempfile.TemporaryDirectory() as folder:
            corpus, results = Path(folder) / "corpus.json", Path(folder) / "results.json"
            corpus.write_bytes(encoded(self.corpus))
            results.write_bytes(encoded(self.results))
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(scorer.main([str(corpus), str(results)]), 1)
            self.assertEqual(json.loads(stdout.getvalue())["evidenceStatus"], "UNBOUND")
            results.unlink()
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                self.assertEqual(scorer.main([str(corpus), str(results)]), 2)
            self.assertNotIn(str(folder), stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
