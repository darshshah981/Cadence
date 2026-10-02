#!/usr/bin/env python3
"""Offline integrity checks and advisory phrase scoring for synthetic Compose runs.

This does not grade semantic quality or verify that a particular model ran.
Only Python's standard library is required; no provider or app state is accessed.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile


class EvidenceError(ValueError):
    """The supplied synthetic evidence is malformed or does not match."""


def _unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise EvidenceError("JSON contains duplicate object keys.")
        value[key] = item
    return value


def _decode(raw, label):
    try:
        return json.loads(raw, object_pairs_hook=_unique_object)
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise EvidenceError(f"{label} is not valid JSON.") from None


def _version_one(value, label):
    if type(value) is not int or value != 1:
        raise EvidenceError(f"Unsupported {label} schema version; expected 1.")


def _version_one_or_two(value, label):
    if type(value) is not int or value not in (1, 2):
        raise EvidenceError(f"Unsupported {label} schema version; expected 1 or 2.")


def _text(value, label):
    if not isinstance(value, str) or not value.strip():
        raise EvidenceError(f"{label} must be a nonempty string.")
    return value


def _phrases(value, label):
    if not isinstance(value, list):
        raise EvidenceError(f"{label} must be a list of nonempty strings.")
    return [_text(phrase, label) for phrase in value]


def _sha256(value, label):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise EvidenceError(f"{label} must be a lowercase SHA-256 hash.")
    return value


def _generation_settings(manifest):
    revision = 1 if "settingsRevision" not in manifest else manifest.get("settingsRevision")
    if type(revision) is not int or revision not in (1, 2):
        raise EvidenceError("Run generation settings revision is unsupported.")
    if revision == 1:
        if manifest.get("maximumResponseTokens") != 1024 or "generationTimeoutMilliseconds" in manifest:
            raise EvidenceError("Generation settings revision 1 must use the legacy 1024-token cap only.")
        return {"settingsRevision": 1, "maximumResponseTokens": 1024,
                "generationTimeoutMilliseconds": None}
    if ("maximumResponseTokens" not in manifest or manifest.get("maximumResponseTokens") is not None
            or type(manifest.get("generationTimeoutMilliseconds")) is not int
            or manifest["generationTimeoutMilliseconds"] != 30000):
        raise EvidenceError("Generation settings revision 2 requires nil response cap and a 30000-ms timeout.")
    return {"settingsRevision": 2, "maximumResponseTokens": None,
            "generationTimeoutMilliseconds": 30000}


def _timing(rows):
    durations = sorted(row["elapsedMilliseconds"] for row in rows)
    if not durations:
        return {"sampleCount": 0, "p50Milliseconds": None, "p95Milliseconds": None,
                "includesFailedGenerations": False}
    return {"sampleCount": len(durations), "p50Milliseconds": durations[math.ceil(len(durations) * .5) - 1],
            "p95Milliseconds": durations[math.ceil(len(durations) * .95) - 1],
            "includesFailedGenerations": True}


def _run_provenance(envelope, corpus_hash, fixtures, results, result_schema, execution_by_id, requests_bytes, generator_bytes):
    manifest = envelope.get("runManifest") if isinstance(envelope, dict) else None
    if manifest is None:
        if requests_bytes is not None or generator_bytes is not None:
            raise EvidenceError("Artifact verification requires a run manifest.")
        return "NOT_VERIFIED", None, None
    if not isinstance(manifest, dict):
        raise EvidenceError("Run manifest must be an object.")
    for field in ("requestsSHA256", "generatorSHA256"):
        _sha256(manifest.get(field), f"Run {field}")
    if manifest.get("state") != "complete":
        raise EvidenceError("Run is not complete; it cannot establish a baseline.")
    for field, expected in (("expectedCaseCount", len(fixtures)), ("completedCaseCount", len(results))):
        if type(manifest.get(field)) is not int or manifest[field] != expected:
            raise EvidenceError("Run case counts do not match the supplied evidence.")
    if manifest.get("providerID") != "legacyLocal" or manifest.get("sampling") != "greedy":
        raise EvidenceError("Unsupported generation settings in the run manifest.")
    generation_settings = _generation_settings(manifest)
    for result in results:
        elapsed = result.get("elapsedMilliseconds")
        if type(elapsed) not in (int, float) or not math.isfinite(elapsed) or elapsed < 0:
            raise EvidenceError("Run results must include finite nonnegative elapsed milliseconds.")
    timing = _timing(results)
    if result_schema == 2:
        if any(type(row["elapsedMilliseconds"]) is not int for row in results):
            raise EvidenceError("Schema 2 execution timing must use integer milliseconds.")
        model_rows = [row for row in results if execution_by_id[row["id"]] == "MODEL_GENERATION"]
        prepared_rows = [row for row in results if execution_by_id[row["id"]] == "PREPARED_DRAFT"]
        split_fields = {
            "expectedModelCaseCount": len(model_rows), "expectedPreparedDraftCaseCount": len(prepared_rows),
            "completedModelCaseCount": len(model_rows), "completedPreparedDraftCaseCount": len(prepared_rows),
            "modelElapsedMilliseconds": sum(row["elapsedMilliseconds"] for row in model_rows),
            "preparedDraftElapsedMilliseconds": sum(row["elapsedMilliseconds"] for row in prepared_rows),
        }
        for field, expected in split_fields.items():
            if type(manifest.get(field)) is not int or manifest[field] != expected:
                raise EvidenceError("Run execution-kind counts or timing do not match results.")
        timing = {"all": timing, "modelGeneration": _timing(model_rows), "preparedDraft": _timing(prepared_rows)}
    if requests_bytes is None and generator_bytes is None:
        return "DECLARED_RUN_MANIFEST", timing, generation_settings
    if requests_bytes is None or generator_bytes is None:
        raise EvidenceError("Verify requests and generator source together.")
    if hashlib.sha256(requests_bytes).hexdigest() != manifest["requestsSHA256"]:
        raise EvidenceError("Run request hash does not match the supplied request export.")
    if hashlib.sha256(generator_bytes).hexdigest() != manifest["generatorSHA256"]:
        raise EvidenceError("Run generator hash does not match the supplied source.")
    exported = _decode(requests_bytes, "Request export")
    if not isinstance(exported, dict):
        raise EvidenceError("Request export must be a versioned envelope.")
    request_schema = exported.get("schemaVersion")
    _version_one_or_two(request_schema, "request export")
    if exported.get("syntheticOnly") is not True or exported.get("corpusSHA256") != corpus_hash:
        raise EvidenceError("Request export is not bound to the supplied synthetic corpus.")
    requests = exported.get("requests")
    if not isinstance(requests, list):
        raise EvidenceError("Request export must contain a requests list.")
    seen, request_execution, request_prepared = set(), {}, {}
    for request in requests:
        if not isinstance(request, dict):
            raise EvidenceError("Each exported request must be an object.")
        request_id = _text(request.get("id"), "Exported request ID")
        if request_id in seen or request_id not in fixtures:
            raise EvidenceError("Request export has duplicate or unknown IDs.")
        seen.add(request_id)
        system, user = _text(request.get("system"), "Exported system message"), _text(request.get("user"), "Exported user message")
        has_prepared = "preparedDraft" in request
        if request_schema == 1 and has_prepared:
            raise EvidenceError("Schema 1 requests must not carry preparedDraft.")
        prepared = request.get("preparedDraft") if has_prepared else None
        if has_prepared and (not isinstance(prepared, str) or not prepared):
            raise EvidenceError("preparedDraft must be a nonempty string when supplied.")
        request_execution[request_id] = "PREPARED_DRAFT" if prepared is not None else "MODEL_GENERATION"
        request_prepared[request_id] = prepared
        bytes_to_hash = system.encode("utf-8") + b"\x00" + user.encode("utf-8")
        if request_schema == 2 and prepared is not None:
            bytes_to_hash += b"\x00preparedDraft\x00" + prepared.encode("utf-8")
        expected_hash = hashlib.sha256(bytes_to_hash).hexdigest()
        if request.get("requestSHA256") != expected_hash:
            raise EvidenceError("Exported request content does not match its hash.")
    if seen != set(fixtures):
        raise EvidenceError("Request export is missing corpus cases.")
    if request_schema != result_schema:
        raise EvidenceError("Request and result schema versions must match.")
    if result_schema == 2:
        result_by_id = {result["id"]: result for result in results}
        for case_id, kind in execution_by_id.items():
            if request_execution[case_id] != kind:
                raise EvidenceError("Result executionKind does not match its request method.")
            if kind == "PREPARED_DRAFT" and result_by_id[case_id]["status"] == "GENERATED":
                if result_by_id[case_id]["draft"].encode("utf-8") != request_prepared[case_id].encode("utf-8"):
                    raise EvidenceError("Prepared-draft result bytes do not match the bound request.")
    return "ARTIFACT_HASHES_MATCH", timing, generation_settings


def score(corpus_bytes, results_bytes, *, requests_bytes=None, generator_bytes=None):
    """Return a deterministic report; reject malformed or incomplete case sets."""
    corpus = _decode(corpus_bytes, "Corpus")
    if not isinstance(corpus, dict):
        raise EvidenceError("Corpus must be an object.")
    _version_one(corpus.get("schemaVersion"), "corpus")
    if corpus.get("syntheticOnly") is not True:
        raise EvidenceError("Corpus must explicitly declare syntheticOnly: true.")
    cases = corpus.get("cases")
    if not isinstance(cases, list) or not cases:
        raise EvidenceError("Corpus must contain a nonempty cases list.")

    fixtures = {}
    for case in cases:
        if not isinstance(case, dict):
            raise EvidenceError("Each fixture must be an object.")
        case_id = _text(case.get("id"), "Fixture ID")
        if case_id in fixtures:
            raise EvidenceError("Corpus contains duplicate fixture IDs.")
        # The complete-selection corpus predates advisory phrase annotations.
        # Accept its explicit source/voice shape without rewriting frozen
        # evidence or treating absent phrase checks as semantic certification.
        if "source" in case:
            _text(case["source"], "Fixture selected source")
            if not any(key in case for key in ("family", "required", "forbidden")):
                case = dict(case, family="selectedRewrite", required=[], forbidden=[])
        _text(case.get("family"), "Fixture family")
        _text(case.get("spoken"), "Fixture spoken input")
        _text(case.get("exampleDraft"), "Fixture example draft")
        _phrases(case.get("required"), "Required phrases")
        _phrases(case.get("forbidden"), "Forbidden phrases")
        fixtures[case_id] = case

    corpus_hash = hashlib.sha256(corpus_bytes).hexdigest()
    results = _decode(results_bytes, "Results")
    envelope = results
    binding = "UNBOUND_LEGACY"
    result_schema = None
    if isinstance(results, dict):
        result_schema = results.get("schemaVersion")
        _version_one_or_two(result_schema, "results")
        declared_hash = results.get("corpusSHA256")
        if not isinstance(declared_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", declared_hash):
            raise EvidenceError("Results must declare a lowercase SHA-256 corpus hash.")
        if declared_hash != corpus_hash:
            raise EvidenceError("Results corpus hash does not match the supplied corpus.")
        results = results.get("results")
        binding = "DECLARED_CORPUS_MATCH"
    if not isinstance(results, list):
        raise EvidenceError("Results must be an array or a versioned results envelope.")

    indexed, execution_by_id = {}, {}
    failure_categories = {"timedOut", "busy", "cancelled", "modelError"}
    for result in results:
        if not isinstance(result, dict):
            raise EvidenceError("Each result must be an object.")
        case_id = _text(result.get("id"), "Result ID")
        if case_id in indexed:
            raise EvidenceError("Results contain duplicate IDs.")
        if case_id not in fixtures:
            raise EvidenceError("Results contain an unknown fixture ID.")
        has_execution_kind = "executionKind" in result
        if result_schema == 1 and has_execution_kind:
            raise EvidenceError("Schema 1 results must not carry executionKind.")
        if result_schema == 2:
            execution_kind = result.get("executionKind")
            if execution_kind not in ("MODEL_GENERATION", "PREPARED_DRAFT"):
                raise EvidenceError("Schema 2 results require a supported executionKind.")
            execution_by_id[case_id] = execution_kind
        else:
            execution_by_id[case_id] = "MODEL_GENERATION"
        status = result.get("status")
        if status not in ("GENERATED", "FAILED"):
            raise EvidenceError("Result status must be GENERATED or FAILED.")
        if status == "GENERATED":
            _text(result.get("draft"), "Generated draft")
            if "failureCategory" in result:
                raise EvidenceError("A GENERATED result must not carry a failure category.")
        elif result.get("draft") is not None:
            raise EvidenceError("A FAILED result must not contain a draft.")
        elif "failureCategory" in result and result["failureCategory"] not in failure_categories:
            raise EvidenceError("A FAILED result has an unsupported failure category.")
        indexed[case_id] = result
    if set(indexed) != set(fixtures):
        raise EvidenceError("Results are incomplete; one or more fixture IDs are missing.")

    provenance, timing, generation_settings = _run_provenance(
        envelope, corpus_hash, fixtures, results, result_schema, execution_by_id, requests_bytes, generator_bytes
    )

    findings = []
    for case_id, fixture in fixtures.items():
        result = indexed[case_id]
        generated = result["status"] == "GENERATED"
        draft = result["draft"].casefold() if generated else ""
        missing = [p for p in fixture["required"] if p.casefold() not in draft] if generated else []
        forbidden = [p for p in fixture["forbidden"] if p.casefold() in draft] if generated else []
        mechanical_status = "NOT_EVALUATED"
        if generated:
            mechanical_status = "WARNINGS" if missing or forbidden else "NO_PHRASE_WARNINGS"
        findings.append({
            "id": case_id,
            "family": fixture["family"],
            "generationStatus": result["status"],
            "generationFailureCategory": result.get("failureCategory") if not generated else None,
            "executionKind": execution_by_id[case_id],
            "advisoryPhraseCheckCount": len(fixture["required"]) + len(fixture["forbidden"]),
            "mechanicalStatus": mechanical_status,
            "missingRequiredPhrases": missing,
            "matchedForbiddenPhrases": forbidden,
            "semanticQuality": "UNGRADED",
        })

    failed = sum(f["generationStatus"] == "FAILED" for f in findings)
    model_findings = [row for row in findings if row["executionKind"] == "MODEL_GENERATION"]
    prepared_findings = [row for row in findings if row["executionKind"] == "PREPARED_DRAFT"]
    warnings = sum(f["mechanicalStatus"] == "WARNINGS" for f in findings)
    categorized_failures = {name: sum(row["generationFailureCategory"] == name for row in findings)
                            for name in sorted(failure_categories)}
    categorized_failures["unspecified"] = sum(
        row["generationStatus"] == "FAILED" and row["generationFailureCategory"] is None for row in findings
    )
    evidence_status = "BOUND_COMPLETE" if binding == "DECLARED_CORPUS_MATCH" else "UNBOUND"
    return {
        "schemaVersion": 1,
        "corpusSHA256": corpus_hash,
        "resultsSHA256": hashlib.sha256(results_bytes).hexdigest(),
        "evidenceStatus": evidence_status,
        "corpusBinding": binding,
        "generatorProvenance": provenance,
        "generationSettings": generation_settings,
        "generationTiming": timing,
        "semanticQuality": "UNGRADED",
        "summary": {
            "expectedCases": len(fixtures),
            "receivedCases": len(indexed),
            "generated": len(indexed) - failed,
            "generationFailures": failed,
            "generationFailureCategories": categorized_failures,
            "modelGenerationCases": len(model_findings),
            "preparedDraftCases": len(prepared_findings),
            "modelGenerationFailures": sum(row["generationStatus"] == "FAILED" for row in model_findings),
            "preparedDraftFailures": sum(row["generationStatus"] == "FAILED" for row in prepared_findings),
            "casesWithPhraseWarnings": warnings,
            "casesWithoutPhraseWarnings": len(indexed) - failed - warnings,
            "semanticCasesGraded": 0,
        },
        "cases": findings,
        "limitations": [
            "Phrase checks are advisory case-insensitive substring checks, not semantic grades.",
            "A missing required phrase may be an acceptable paraphrase; no warning does not prove fidelity.",
            "Corpus binding verifies a supplied hash declaration, not which generator or provider ran.",
            "Matching artifact hashes bind supplied source and requests; they do not authenticate execution.",
            "Legacy arrays have no corpus declaration and cannot establish a bound baseline.",
            "This report contains no generated drafts or spoken input; keep source evidence synthetic.",
        ],
    }


def report_exit_code(report):
    summary = report["summary"]
    needs_attention = (
        report["evidenceStatus"] != "BOUND_COMPLETE"
        or summary["generationFailures"] > 0
        or summary["casesWithPhraseWarnings"] > 0
    )
    return 1 if needs_attention else 0


def _write_report(path, content):
    # Replace only after the complete report has been written successfully.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(content)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("results", type=Path)
    parser.add_argument("--output", type=Path, help="Write JSON atomically; otherwise print it to stdout.")
    parser.add_argument("--requests", type=Path, help="Verify the exact production request export recorded by the runner.")
    parser.add_argument("--generator-source", type=Path, help="Verify the generator source recorded by the runner; use with --requests.")
    args = parser.parse_args(argv)
    try:
        if args.output is not None:
            for source in (args.corpus, args.results, args.requests, args.generator_source):
                if source is None:
                    continue
                if args.output.resolve() == source.resolve() or (
                    args.output.exists() and source.exists() and os.path.samefile(args.output, source)
                ):
                    raise EvidenceError("Output must not overwrite an input file.")
        report = score(
            args.corpus.read_bytes(), args.results.read_bytes(),
            requests_bytes=args.requests.read_bytes() if args.requests else None,
            generator_bytes=args.generator_source.read_bytes() if args.generator_source else None,
        )
        rendered = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        if args.output is None:
            sys.stdout.write(rendered)
        else:
            _write_report(args.output, rendered)
        summary = report["summary"]
        print(
            f"{report['evidenceStatus']}: {summary['receivedCases']}/{summary['expectedCases']} cases; "
            f"{summary['generationFailures']} generation failures; "
            f"{summary['casesWithPhraseWarnings']} phrase warnings; semantic quality UNGRADED.",
            file=sys.stderr,
        )
        return report_exit_code(report)
    except EvidenceError as error:
        print(f"Invalid evaluation evidence: {error}", file=sys.stderr)
        return 2
    except OSError:
        # Avoid printing path or operating-system error details from user inputs.
        print("Unable to read evidence or write the report. Check paths and permissions.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
