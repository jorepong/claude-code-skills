import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import prepare_narration


class PrepareNarrationTest(unittest.TestCase):
    def test_animation_markers_split_tts_but_keep_one_paragraph(self):
        source = """---
title: test
---
@p 먼저 설명합니다.

@fig [[stage:intro]] 화면을 봅니다. [[stage:move-chip]] 칩이 이동합니다.
"""
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            script = root / "01-test.script.md"
            script.write_text(source, encoding="utf-8")
            manifest = prepare_narration.prepare(script, root / "out")

            self.assertEqual(len(manifest["paragraphs"]), 2)
            fig = manifest["paragraphs"][1]
            self.assertEqual(fig["tag"], "fig")
            self.assertEqual(
                [segment["stage"] for segment in fig["segments"]],
                ["intro", "move-chip"],
            )
            self.assertNotIn("[[stage:", fig["text"])

    def test_markers_are_rejected_outside_fig(self):
        source = "@p [[stage:intro]] 잘못된 자리입니다.\n"
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            script = root / "01-test.script.md"
            script.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "@fig"):
                prepare_narration.prepare(script, root / "out")

    def test_duplicate_stage_is_rejected(self):
        source = "@fig [[stage:a]] 첫째. [[stage:a]] 둘째.\n"
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            script = root / "01-test.script.md"
            script.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "중복"):
                prepare_narration.prepare(script, root / "out")

    def test_malformed_stage_is_rejected(self):
        source = "@fig [[stage:한글-id]] 잘못된 마커입니다.\n"
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            script = root / "01-test.script.md"
            script.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "형식"):
                prepare_narration.prepare(script, root / "out")

    def test_legacy_animation_marker_remains_supported(self):
        source = "@fig [[anim:intro]] 기존 스크립트입니다.\n"
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            script = root / "01-test.script.md"
            script.write_text(source, encoding="utf-8")
            manifest = prepare_narration.prepare(script, root / "out")
            self.assertEqual(manifest["paragraphs"][0]["segments"][0]["stage"], "intro")

    def test_spoken_arabic_digits_are_rejected(self):
        source = "@p 이 작업을 3번 반복하고 3-way 핸드셰이크를 시작합니다.\n"
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            script = root / "01-test.script.md"
            script.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "세 번.*삼 번.*쓰리 웨이"):
                prepare_narration.prepare(script, root / "out")

    def test_spelled_out_number_pronunciations_are_accepted(self):
        source = "@p 이 작업을 세 번 반복하고 쓰리 웨이 핸드셰이크를 시작합니다.\n"
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            script = root / "01-test.script.md"
            script.write_text(source, encoding="utf-8")
            manifest = prepare_narration.prepare(script, root / "out")
            self.assertEqual(
                manifest["paragraphs"][0]["text"],
                "이 작업을 세 번 반복하고 쓰리 웨이 핸드셰이크를 시작합니다.",
            )


if __name__ == "__main__":
    unittest.main()
