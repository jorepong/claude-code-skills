#!/usr/bin/env python3
"""Focused regression tests for the learn skill's Qwen renderer."""

from __future__ import annotations

import os
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import qwen_batch


class FakeTokenizer:
    def encode(self, text: str) -> list[str]:
        return list(text)


class FakeModel:
    tokenizer = FakeTokenizer()


class FakeWatchdog:
    def reset(self, *_args, **_kwargs) -> None:
        pass

    def finish(self) -> set[int]:
        return set()


class FailingBatchModel(FakeModel):
    sample_rate = 24000
    _learn_token_run_watchdog = FakeWatchdog()

    def batch_generate(self, **_kwargs):
        raise RuntimeError("one sequence failed")


class QwenBatchTests(unittest.TestCase):
    def test_generation_uses_only_authored_text(self) -> None:
        job = qwen_batch.PartJob(pathlib.Path("unused.wav"), "테스트입니다.")
        with patch.dict(
            os.environ,
            {
                "LEARN_QWEN_ENDING_CONTEXT": "1",
                "LEARN_QWEN_ENDING_CONTEXT_TEXT": "이상입니다.",
                "LEARN_QWEN_TEXT_SUFFIX": "\n(...)",
            },
            clear=True,
        ):
            self.assertEqual(qwen_batch.generation_text(job), "테스트입니다.")

    def test_split_preserves_complete_sentences(self) -> None:
        text = "첫 문장입니다. 두 번째 문장도 온전합니다. 마지막입니다."
        chunks = qwen_batch.split_text(text, 24)
        self.assertEqual(" ".join(chunks), text)
        self.assertTrue(all(chunk.endswith(".") for chunk in chunks))
        self.assertTrue(all(len(chunk) <= 24 for chunk in chunks))

    def test_default_chunk_limit_keeps_a_normal_paragraph_together(self) -> None:
        text = (
            "첫 번째 단계에서는 입력과 출력의 관계를 구체적인 예시와 함께 살펴봅니다. "
            "두 번째 단계에서는 중간 상태가 어떤 순서로 변하는지 차근차근 따라가 봅니다. "
            "마지막 단계에서는 같은 원리가 실제 사례에서 어떤 차이를 만드는지 앞의 흐름과 연결해 이해합니다."
        )
        self.assertGreater(len(text), 100)
        self.assertLess(len(text), qwen_batch.DEFAULT_CHUNK_CHARS)
        self.assertEqual(
            qwen_batch.split_text(text, qwen_batch.DEFAULT_CHUNK_CHARS), [text]
        )

    def test_oversized_sentence_prefers_clause_boundaries(self) -> None:
        text = "첫째 절은 여기까지이고, 둘째 절은 더 길게 이어지며, 셋째 절로 끝납니다."
        chunks = qwen_batch.split_text(text, 24)
        self.assertGreater(len(chunks), 1)
        self.assertTrue(all(len(chunk) <= 24 for chunk in chunks))
        self.assertEqual(" ".join(chunks), text)

    def test_batch_budget_uses_predicted_audio_tokens(self) -> None:
        jobs = [
            qwen_batch.PartJob(pathlib.Path(f"{index}.wav"), "가" * length)
            for index, length in enumerate((5, 8, 20, 22), start=1)
        ]
        batches = qwen_batch.plan_batches(FakeModel(), jobs, 4, 50, 1.0)
        for batch in batches:
            largest = max(
                qwen_batch.estimated_audio_tokens(FakeModel(), job, 1.0)
                for job in batch
            )
            self.assertLessEqual(len(batch) * largest, 50)

    def test_text_files_are_grouped_in_chapter_order(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            files = [
                root / "02" / "paragraphs" / "p001" / "s001.tts.txt",
                root / "01" / "paragraphs" / "p002" / "s001.tts.txt",
                root / "01" / "paragraphs" / "p001" / "s001.tts.txt",
            ]
            groups = qwen_batch.group_text_files_by_section(root, files)
            self.assertEqual([name for name, _files in groups], ["01", "02"])
            self.assertEqual(
                [path.parent.name for path in groups[0][1]], ["p001", "p002"]
            )

    def test_sampling_defaults_match_upstream_qwen_defaults(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(qwen_batch.sampling_settings(), (50, 1.0, 1.05))

    def test_top_p_rejects_values_above_one(self) -> None:
        with patch.dict(os.environ, {"LEARN_QWEN_TOP_P": "1.1"}, clear=True):
            with self.assertRaises(SystemExit):
                qwen_batch.sampling_settings()

    def test_exhausted_part_gets_a_silent_placeholder(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = pathlib.Path(directory) / "failed.wav"
            job = qwen_batch.PartJob(destination, "이 조각만 격리합니다.")
            qwen_batch.write_failure_placeholder(job, 1000, "test", seconds=0.35)
            sample_rate, audio = qwen_batch.read_wav(destination)
            self.assertEqual(sample_rate, 1000)
            self.assertEqual(len(audio), 350)
            self.assertTrue(np.all(audio == 0))

    def test_single_sequence_engine_error_becomes_a_local_retry(self) -> None:
        job = qwen_batch.PartJob(pathlib.Path("failed.wav"), "이 문장만 실패합니다.")
        retries = qwen_batch.render_batch(
            FailingBatchModel(), [job], None, 120, 120, 4.0
        )
        self.assertEqual(len(retries), 1)
        self.assertIs(retries[0].job, job)
        self.assertIn("engine-error:RuntimeError", retries[0].reason)

    def test_exhausted_recovery_isolates_only_that_part(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            destination = root / "parts" / "failed.wav"
            retry = qwen_batch.PartRetry(
                qwen_batch.PartJob(destination, "이 문장만 누락됩니다."),
                "non-speech",
            )
            with patch.object(
                qwen_batch,
                "recover_part",
                side_effect=RuntimeError("retries exhausted"),
            ):
                failure = qwen_batch.recover_or_isolate(
                    FailingBatchModel(), retry, None, 1200, 120, 4.0, root
                )
            self.assertTrue(destination.is_file())
            self.assertEqual(failure["part"], "parts/failed.wav")
            self.assertEqual(failure["text"], "이 문장만 누락됩니다.")
            self.assertIn("retries exhausted", failure["reason"])

    def test_silent_audio_is_rejected_before_write(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = pathlib.Path(directory) / "silent.wav"
            job = qwen_batch.PartJob(destination, "무음이면 실패합니다.")
            audio = np.zeros(24000, dtype=np.float32)
            with patch.dict(os.environ, {"LEARN_QWEN_SILENCE_CAP": "0"}):
                rejection = qwen_batch.write_generated_part(job, 24000, audio)
            self.assertEqual(rejection, "non-speech")
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
