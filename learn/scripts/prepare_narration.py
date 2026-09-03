#!/usr/bin/env python3
"""Prepare narration paragraphs and optional dynamic-visual stage TTS segments.

The script keeps the player contract of one script paragraph per document block,
while allowing an @fig paragraph to contain silent ``[[stage:stage-id]]`` markers.
Each marker starts a separately rendered TTS segment so narrate.sh can retain the
real audio offset of the corresponding visual stage. ``[[anim:...]]`` remains a
backward-compatible alias for existing scripts.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys


TAG_RE = re.compile(r"^@(p|fig|code|table|note|gate)\s+")
STAGE_RE = re.compile(r"\[\[(?:stage|anim):([A-Za-z][A-Za-z0-9_-]*)\]\]")
ANY_STAGE_TOKEN_RE = re.compile(r"\[\[(?:stage|anim):")
ARABIC_DIGIT_RE = re.compile(r"[0-9]")


def strip_front_matter(text: str) -> str:
    match = re.match(r"^---[ \t]*\n.*?\n---[ \t]*\n?", text, re.DOTALL)
    return text[match.end() :] if match else text


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def validate_spoken_text(text: str, paragraph_number: int) -> None:
    match = ARABIC_DIGIT_RE.search(text)
    if not match:
        return
    start = max(0, match.start() - 18)
    end = min(len(text), match.end() + 24)
    excerpt = text[start:end]
    raise ValueError(
        f"문단 {paragraph_number}: TTS에 전달되는 문장에 아라비아 숫자가 남아 있습니다 "
        f"({excerpt!r}). 숫자는 문맥에 맞는 실제 발음으로 풀어 쓰세요. "
        "예: 횟수 3번→세 번, 항목 3번→삼 번, 3-way→쓰리 웨이."
    )


def split_stages(text: str, tag: str, paragraph_number: int) -> list[dict[str, str | None]]:
    marker_count = len(ANY_STAGE_TOKEN_RE.findall(text))
    valid = STAGE_RE.findall(text)
    if marker_count != len(valid):
        raise ValueError(
            f"문단 {paragraph_number}: 동적 시각의 단계 마커는 "
            "[[stage:영문-stage-id]] 형식이어야 합니다."
        )
    if not valid:
        return [{"stage": None, "text": normalize(text)}]
    if tag != "fig":
        raise ValueError(
            f"문단 {paragraph_number}: [[stage:...]] 마커는 @fig 문단에서만 쓸 수 있습니다."
        )
    if len(valid) != len(set(valid)):
        raise ValueError(f"문단 {paragraph_number}: 동적 시각의 stage-id가 중복됩니다.")

    matches = list(STAGE_RE.finditer(text))
    segments: list[dict[str, str | None]] = []
    prelude = normalize(text[: matches[0].start()])
    if prelude:
        segments.append({"stage": None, "text": prelude})
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        spoken = normalize(text[match.end() : end])
        if not spoken:
            raise ValueError(
                f"문단 {paragraph_number}: [[stage:{match.group(1)}]] 뒤에 낭독 문장이 없습니다."
            )
        segments.append({"stage": match.group(1), "text": spoken})
    return segments


def prepare(script_path: pathlib.Path, output_dir: pathlib.Path) -> dict[str, object]:
    body = strip_front_matter(script_path.read_text(encoding="utf-8"))
    raw_paragraphs = [p.strip() for p in re.split(r"\n[ \t]*\n", body) if p.strip()]
    paragraphs: list[dict[str, object]] = []
    paragraphs_root = output_dir / "paragraphs"
    paragraphs_root.mkdir(parents=True, exist_ok=True)

    for number, raw in enumerate(raw_paragraphs, start=1):
        tag_match = TAG_RE.match(raw)
        tag = tag_match.group(1) if tag_match else "p"
        text = raw[tag_match.end() :] if tag_match else raw
        segments = split_stages(text, tag, number)
        if not any(segment["text"] for segment in segments):
            continue

        paragraph_dir = paragraphs_root / f"p{number:03d}"
        paragraph_dir.mkdir(parents=True, exist_ok=True)
        (paragraph_dir / "tag.txt").write_text(tag, encoding="utf-8")
        segment_rows: list[str] = []
        cleaned_parts: list[str] = []
        manifest_segments: list[dict[str, object]] = []
        for segment_number, segment in enumerate(segments, start=1):
            filename = f"s{segment_number:03d}.tts.txt"
            spoken = str(segment["text"])
            validate_spoken_text(spoken, number)
            (paragraph_dir / filename).write_text(spoken, encoding="utf-8")
            stage = str(segment["stage"]) if segment["stage"] else "-"
            segment_rows.append(f"{stage}\t{filename}")
            cleaned_parts.append(spoken)
            manifest_segments.append(
                {"stage": None if stage == "-" else stage, "file": filename, "text": spoken}
            )
        (paragraph_dir / "segments.tsv").write_text(
            "\n".join(segment_rows) + "\n", encoding="utf-8"
        )
        cleaned = " ".join(cleaned_parts)
        (paragraph_dir / "text.txt").write_text(cleaned, encoding="utf-8")
        paragraphs.append(
            {
                "index": number,
                "tag": tag,
                "text": cleaned,
                "segments": manifest_segments,
            }
        )

    manifest = {"script": script_path.name, "paragraphs": paragraphs}
    (output_dir / "paragraphs.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return manifest


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: prepare_narration.py <script.md> <output-dir>")
    script_path = pathlib.Path(sys.argv[1]).resolve()
    output_dir = pathlib.Path(sys.argv[2]).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    try:
        manifest = prepare(script_path, output_dir)
    except ValueError as exc:
        raise SystemExit(f"낭독 스크립트 파싱 실패: {exc}") from exc
    if not manifest["paragraphs"]:
        raise SystemExit(f"낭독할 문단이 없습니다: {script_path}")


if __name__ == "__main__":
    main()
