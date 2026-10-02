# Compose evaluation reports

The offline scorecard checks the integrity of **synthetic** instruction-evaluation evidence and highlights phrases worth reviewing. It does not call a model, read Cadence settings, inspect apps, or grade semantic quality.

The first roadmap increment is implemented by `scripts/score_scribe_instructions.py`. It uses Python 3.9+ and the standard library. Existing real-model generation remains in `scripts/evaluate_scribe_instructions.sh`; the scorer does not replace that runner.

## Run a report

```sh
python3 scripts/score_scribe_instructions.py \
  CadenceTests/Fixtures/AdaptiveScribe/instruction-following.json \
  Build/ScribeOnDevice/model-results.json \
  --output Build/ScribeOnDevice/scorecard.json
```

The output directory must already exist. Omit `--output` to write the JSON report to stdout. A concise summary goes to stderr. A failed validation leaves an existing report unchanged, so always check the process exit code before consuming an output file. Output cannot overwrite either input.

## Input formats and provenance

The corpus must use `schemaVersion: 1`, declare `syntheticOnly: true`, and contain uniquely identified cases with nonempty `spoken`, `exampleDraft`, and `family` fields plus `required` and `forbidden` phrase arrays.

Older generators wrote a legacy array:

```json
[
  {"id": "formal-greeting", "status": "GENERATED", "draft": "Hello, how are you?"},
  {"id": "another-case", "status": "FAILED", "draft": null}
]
```

Legacy arrays can be inspected, but the report labels them `UNBOUND`. Matching IDs cannot prove that they were generated from the current corpus.

A producer that records the corpus identity **at generation time** can supply this envelope:

```json
{
  "schemaVersion": 1,
  "corpusSHA256": "<64 lowercase hexadecimal characters>",
  "results": [
    {"id": "formal-greeting", "status": "GENERATED", "draft": "Hello, how are you?"}
  ]
}
```

`corpusSHA256` is SHA-256 of the corpus file's exact bytes, including whitespace. A mismatch rejects the evidence. Do not attach today's corpus hash to old outputs to make them pass. The current generator produces this envelope together with a run manifest.

Even `DECLARED_CORPUS_MATCH` establishes only that the supplied declaration matches the supplied corpus. It does not authenticate the provider, prompt, settings, or execution. Without a run manifest, `generatorProvenance` remains `NOT_VERIFIED`.

## Production request and run manifests

The native `ScribeTests.instructionFixturesUseProductionRequestsAndPreserveRequiredLiterals` test exports requests using the real literal normalizer and request policy. Set `TEST_RUNNER_CADENCE_EXPORT_ON_DEVICE_FIXTURES=1` and `TEST_RUNNER_CADENCE_SCRIBE_EVALUATION_DIRECTORY` to an absolute temporary directory when invoking `xcodebuild test`. Schema 1 exports declare synthetic input, exact corpus SHA-256, unique case IDs, and a per-request SHA-256 over `system UTF-8 + NUL + user UTF-8`.

Schema 2 may include a compiler-vetted `preparedDraft` for a narrow recipient-framing path. Its request hash appends `NUL + "preparedDraft" + NUL + preparedDraft UTF-8` only when that field is present. A schema-1 request carrying that field is invalid. A generated `PREPARED_DRAFT` result must reproduce those UTF-8 bytes exactly, without Unicode normalization or paraphrase. Schema-2 results identify every row as `MODEL_GENERATION` or `PREPARED_DRAFT`, and the manifest separately records case counts and integer elapsed milliseconds for each kind. The older all-row timing field continues to allow finite numeric measurements for compatibility. Prepared drafts are deterministic pipeline evidence; they are not model-generation evidence and cannot improve `modelQualityGate`.

Run `scripts/evaluate_scribe_instructions.sh requests.json results.json`. It compiles and calls the production `OnDeviceScribeGeneration` implementation. New runs record settings revision 2: greedy sampling, `maximumResponseTokens: null`, and `generationTimeoutMilliseconds: 30000`, together with request-export and generator-source hashes, OS version, timing, and completeness. The runner reads the cap and timeout from production constants instead of duplicating them. Revision-1 manifests with the legacy 1024-token cap remain readable, but they are distinct evidence settings and cannot be aggregated with revision-2 runs. It checkpoints atomically after each case; interrupted or unavailable runs are not complete baselines. An unavailable model receives an explicit `UNAVAILABLE` result, not a fabricated draft. Three separate runs are used for the initial development baseline; they do not prove behavior on a different OS model.

To verify the saved artifacts as well as their declarations:

```sh
python3 scripts/score_scribe_instructions.py corpus.json results.json \
  --requests requests.json \
  --generator-source OnDeviceScribeGeneration.swift \
  --output scorecard.json
```

Save the exact corpus, request export, and generator source alongside the results before changing the implementation. Both artifact arguments are required together. A valid manifest alone yields `DECLARED_RUN_MANIFEST`; matching supplied artifacts yield `ARTIFACT_HASHES_MATCH`. These hashes establish consistency, not independent authentication that a process ran. All states remain semantically ungraded. The report gives nearest-rank p50 and p95 generation duration including failures; this measures the harness call, not end-to-end shortcut or insertion latency.

Use `scripts/replay_scribe_evaluation.sh requests.json results.json Build/.../replay.json` to replay a complete bound artifact through the current native output and recipient-restriction policies without invoking a model. Add `--generator-source saved-OnDeviceScribeGeneration.swift` when verifying a frozen historical result; that supplied source is hashed as evidence and is never executed. Replay reports hash the current policy source files separately, so historical generator provenance is not confused with current review eligibility.

The development semantic rubric is `instruction-rubric.json`. Review generated results against facts, writing directions, recipient instructions, and unsupported claims separately from substring findings. The disjoint `instruction-holdout.json` corpus is reserved for validation after changes, not prompt tuning. Fixture-integrity tests establish coverage and structure; they do not grade generated meaning.

`scripts/summarize_scribe_evaluation.py` combines repeated runs with explicit semantic-review artifacts. Each review declares hashes of the exact result, corpus, and rubric; every case needs a status, severity, and rationale. Critical failures require a category. Duplicate run artifacts, stale reviews, missing cases, and a semantic pass attached to a failed generation are rejected. The headline pass rate uses every case-run, including failed or ungraded cases.

```sh
python3 scripts/summarize_scribe_evaluation.py \
  corpus.json instruction-rubric.json requests.json OnDeviceScribeGeneration.swift \
  --run run-1.json semantic-review-run-1.json \
  --run run-2.json semantic-review-run-2.json \
  --run run-3.json semantic-review-run-3.json \
  --output aggregate.json
```

The provisional research gate requires at least 95% semantic passes and zero critical failures, with no ungraded cases or generation failures. Schema-2 aggregates report `pipelineQualityGate` over every requested case and `modelQualityGate` over `MODEL_GENERATION` rows only; `qualityGate` is the pipeline gate with `qualityScope: COMPOSE_PIPELINE`. Schema-1 retains `qualityScope: MODEL_GENERATION`. Evidence completeness and quality are separate report fields. Exit 0 means this declared gate passes, 1 means it fails or is ungraded, and 2 means invalid evidence. Agent-assisted review is a judgment source with limitations, not a deterministic semantic test. Keep severity calibration unchanged while comparing runs; record a proposed rubric change separately and regrade the comparison set consistently if adopting it.

Every corpus ID must appear exactly once. Unknown IDs, missing cases, duplicate IDs or JSON keys, invalid schemas/statuses, blank generated drafts, and failed rows containing a draft are rejected. A `FAILED` row can omit `draft` or use `null`; it remains in the denominator.

## Interpret the result

| Field | Meaning |
|---|---|
| `evidenceStatus: BOUND_COMPLETE` | All expected cases are present and the corpus declaration matches. This is not a model-quality pass. |
| `evidenceStatus: UNBOUND` | A legacy array was inspected without source-corpus binding. |
| `generationFailures` | Failed generations, including cases for which no draft was produced. |
| `casesWithPhraseWarnings` | Generated drafts missing a required phrase or containing a forbidden phrase. |
| `casesWithoutPhraseWarnings` | Generated drafts with no mechanical phrase finding; they may still be poor drafts. |
| `semanticQuality: UNGRADED` | No judgment of meaning, tone, factual fidelity, or usefulness has been made. |

Phrase checks use case-insensitive substring matching. They intentionally remain advisory. An acceptable paraphrase can omit a required phrase; an incorrect or contradictory draft can include every required phrase. The report preserves those distinctions and never turns them into a semantic percentage.

Reports omit full drafts and spoken input, but include synthetic fixture IDs, families, and matched/missing phrases. They are development evidence, not a privacy-safe format for exporting real user conversations. Keep source requests and outputs synthetic.

| Exit code | Meaning |
|---|---|
| `0` | Bound, complete evidence with no generation failures or phrase warnings. Semantic quality is still ungraded. |
| `1` | A report was produced, but evidence is unbound, generation failed, or phrase review is needed. |
| `2` | Invalid/incomplete evidence, invalid CLI arguments, or an input/output error. No new report was written. |

## Verify the scorer

```sh
python3 -B -m unittest discover -s scripts/tests -p 'test_score_scribe_instructions.py' -v
```

Tests cover evidence identity and completeness, schema errors, generation failures, prompt-direction leakage, acceptable paraphrases, deterministic reports, input protection, and CLI behavior. A repository-corpus test uses the fixture **example drafts**, explicitly without claiming real model generation or semantic acceptance.

This increment changes development tooling only. It does not change prompts, providers, recording, waveform timing, insertion, permissions, or the installed app.
