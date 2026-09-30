"""Integrity checks for synthetic instruction-following review fixtures.

These checks validate fixture shape and declared literal coverage only. They do
not score a draft or claim that any generated output is semantically verified.
"""

import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "CadenceTests" / "Fixtures" / "AdaptiveScribe"
DEVELOPMENT_PATH = FIXTURES / "instruction-following.json"
RUBRIC_PATH = FIXTURES / "instruction-rubric.json"
HOLDOUT_PATH = FIXTURES / "instruction-holdout.json"


def load(path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


class InstructionRubricFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.development = load(DEVELOPMENT_PATH)
        cls.rubric = load(RUBRIC_PATH)
        cls.holdout = load(HOLDOUT_PATH)

    def test_rubric_covers_each_development_case_once(self):
        source_ids = [case["id"] for case in self.development["cases"]]
        rubric_ids = [case["id"] for case in self.rubric["cases"]]
        self.assertEqual(len(source_ids), len(set(source_ids)))
        self.assertEqual(len(rubric_ids), len(set(rubric_ids)))
        self.assertEqual(set(rubric_ids), set(source_ids))
        self.assertEqual(self.rubric["schemaVersion"], 1)
        self.assertTrue(self.rubric["syntheticOnly"])
        self.assertEqual(self.rubric["sourceCorpus"], DEVELOPMENT_PATH.name)

    def test_rubric_has_reviewable_constraints_for_each_case(self):
        required_dimensions = {
            "instructionExecution",
            "recipientIntent",
            "factualFidelity",
            "draftUsability",
        }
        supported_categories = {
            "short-message",
            "formatted-update",
            "recipient-question",
            "recipient-instruction",
            "literal-note",
            "coding-prompt",
            "missing-source",
        }
        for case in self.rubric["cases"]:
            with self.subTest(case=case["id"]):
                self.assertIn(case["supportedLocalTaskCategory"], supported_categories)
                for key in (
                    "intendedMessage", "writerInstructions", "recipientInstructions",
                    "facts", "negation", "uncertainty", "literals",
                    "allowedParaphraseRules", "unacceptableOutputs",
                ):
                    self.assertIsInstance(case[key], list)
                self.assertTrue(case["intendedMessage"])
                self.assertTrue(case["allowedParaphraseRules"])
                self.assertTrue(case["unacceptableOutputs"])
                self.assertEqual(
                    {dimension["name"] for dimension in case["dimensions"]},
                    required_dimensions,
                )
                self.assertTrue(
                    {dimension["severity"] for dimension in case["dimensions"]}
                    .issubset({"critical", "style"})
                )
                self.assertIn("critical", {dimension["severity"] for dimension in case["dimensions"]})

    def test_development_examples_preserve_declared_literals(self):
        source_cases = {case["id"]: case for case in self.development["cases"]}
        for rubric_case in self.rubric["cases"]:
            source_case = source_cases[rubric_case["id"]]
            with self.subTest(case=rubric_case["id"]):
                for literal in rubric_case["literals"]:
                    self.assertIn(literal, source_case["spoken"])
                    self.assertIn(literal, source_case["exampleDraft"])

    def test_holdout_is_synthetic_disjoint_and_sized_for_first_pass(self):
        self.assertEqual(self.holdout["schemaVersion"], 1)
        self.assertTrue(self.holdout["syntheticOnly"])
        holdout_cases = self.holdout["cases"]
        self.assertGreaterEqual(len(holdout_cases), 12)
        self.assertLessEqual(len(holdout_cases), 20)
        development_ids = {case["id"] for case in self.development["cases"]}
        holdout_ids = [case["id"] for case in holdout_cases]
        self.assertEqual(len(holdout_ids), len(set(holdout_ids)))
        self.assertTrue(development_ids.isdisjoint(holdout_ids))

    def test_holdout_uses_the_corpus_shape_without_copying_exact_examples(self):
        development_pairs = {
            (case["spoken"], case["exampleDraft"])
            for case in self.development["cases"]
        }
        for case in self.holdout["cases"]:
            with self.subTest(case=case["id"]):
                self.assertEqual(
                    set(case),
                    {"id", "family", "spoken", "exampleDraft", "required", "forbidden"},
                )
                self.assertTrue(all(isinstance(case[key], str) and case[key].strip()
                                    for key in ("id", "family", "spoken", "exampleDraft")))
                self.assertTrue(all(isinstance(value, str) and value.strip()
                                    for key in ("required", "forbidden") for value in case[key]))
                self.assertNotIn((case["spoken"], case["exampleDraft"]), development_pairs)

    def test_fixture_text_does_not_present_integrity_checks_as_semantic_verification(self):
        rendered = json.dumps({"rubric": self.rubric, "holdout": self.holdout}).casefold()
        for prohibited_claim in ("semantically verified", "semantic pass", "automatically graded"):
            with self.subTest(claim=prohibited_claim):
                self.assertNotIn(prohibited_claim, rendered)


if __name__ == "__main__":
    unittest.main()
