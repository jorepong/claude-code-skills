#!/usr/bin/env python3
"""Regression tests for progressive, text-first learn players."""

from __future__ import annotations

import pathlib
import subprocess
import tempfile
import unittest


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent


class PlayerGenerationTests(unittest.TestCase):
    def test_text_only_players_reindex_every_chapter(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "01-first.md").write_text(
                "# 첫 번째 챕터\n\n인라인 수식은 \\(x^2\\)입니다.\n",
                encoding="utf-8",
            )
            (root / "01-first.script.md").write_text(
                "---\ntitle: 첫 번째 챕터\n---\n@p 엑스의 제곱입니다.\n",
                encoding="utf-8",
            )
            (root / "02-chart.md").write_text(
                """# 두 번째 챕터

값의 변화를 봅니다.

```vega-lite
{"data":{"values":[{"x":1,"y":2}]},"mark":"point","encoding":{"x":{"field":"x","type":"quantitative"},"y":{"field":"y","type":"quantitative"}}}
```
""",
                encoding="utf-8",
            )
            (root / "02-chart.script.md").write_text(
                "---\ntitle: 두 번째 챕터\n---\n@p 값의 변화를 봅니다.\n\n@fig 가로축과 세로축의 점을 봅니다.\n",
                encoding="utf-8",
            )

            subprocess.run(
                ["bash", str(SCRIPT_DIR / "build-players.sh"), str(root)],
                check=True,
                capture_output=True,
                text=True,
            )

            first = (root / "01-first.player.html").read_text(encoding="utf-8")
            second = (root / "02-chart.player.html").read_text(encoding="utf-8")
            for player in (first, second):
                self.assertIn("첫 번째 챕터", player)
                self.assertIn("두 번째 챕터", player)
                self.assertIn("katex@0.18.4", player)
                self.assertIn("vega-lite@5", player)
                self.assertIn("음성 준비 중 · 본문은 바로 읽을 수 있습니다", player)
            self.assertIn("const INITIAL = 0;", first)
            self.assertIn("const INITIAL = 1;", second)
            self.assertFalse((root / "audio").exists())


if __name__ == "__main__":
    unittest.main()
