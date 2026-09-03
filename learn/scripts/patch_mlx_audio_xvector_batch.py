#!/usr/bin/env python3
"""Enable correct shared-reference x-vector batching in mlx-audio 0.5.0.

The 0.5.0 Qwen3-TTS implementation exposes ``ref_audio`` on
``batch_generate`` but rejects audio-only references, routes them through a
continuous path that drops the reference, and omits ``ref_audio`` from the
generic batched prefill. It also recomputes the same speaker embedding once per
sequence. The generic batch loop also replaces the final trailing text
embedding with padding one step too early, causing the batch token stream to
diverge from ``generate()`` even at batch size one. These narrowly checked
edits activate the x-vector batch path, cache a shared reference embedding,
and preserve every trailing text embedding. The patch is idempotent and
refuses unknown source layouts instead of modifying them speculatively.
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys


def replace_once(source: str, old: str, new: str, label: str) -> tuple[str, bool]:
    if new in source:
        return source, False
    count = source.count(old)
    if count != 1:
        raise RuntimeError(
            f"mlx-audio x-vector patch cannot locate {label}: expected 1, got {count}"
        )
    return source.replace(old, new, 1), True


def main() -> None:
    spec = importlib.util.find_spec("mlx_audio.tts.models.qwen3_tts.qwen3_tts")
    if spec is None or spec.origin is None:
        raise SystemExit("mlx-audio Qwen3-TTS implementation not found")

    path = pathlib.Path(spec.origin)
    source = path.read_text(encoding="utf-8")
    changed = False

    edits = [
        (
            "        if ref_audio is None or ref_text is None:\n"
            "            raise ValueError(\n"
            "                \"Qwen3-TTS batch reference cloning requires both ref_audio and ref_text\"\n"
            "            )",
            "        if ref_audio is None:\n"
            "            raise ValueError(\n"
            "                \"Qwen3-TTS batch reference cloning requires ref_audio\"\n"
            "            )",
            "audio-only reference normalization",
        ),
        (
            "                    language=language,\n"
            "                    speaker=speaker,\n"
            "                    instruct=instruct,",
            "                    language=language,\n"
            "                    speaker=speaker,\n"
            "                    ref_audio=ref_audio,\n"
            "                    instruct=instruct,",
            "x-vector prefill forwarding",
        ),
        (
            "        if not stream and not use_icl:\n",
            "        if not stream and not use_icl and ref_audio is None:\n",
            "reference-preserving batch route",
        ),
        (
            "                pad_when_index_clamped=True,\n",
            "                pad_when_index_clamped=False,\n",
            "final trailing text embedding preservation",
        ),
        (
            "        self._icl_cache = {}\n",
            "        self._icl_cache = {}\n"
            "        self._speaker_embedding_cache = []\n",
            "speaker embedding cache initialization",
        ),
        (
            "        if self.speaker_encoder is None:\n"
            "            raise ValueError(\"Speaker encoder not available for this model type\")\n\n"
            "        # Compute mel spectrogram\n",
            "        if self.speaker_encoder is None:\n"
            "            raise ValueError(\"Speaker encoder not available for this model type\")\n\n"
            "        for cached_audio, cached_sr, cached_embedding in self._speaker_embedding_cache:\n"
            "            if audio is cached_audio and sr == cached_sr:\n"
            "                return cached_embedding\n\n"
            "        # Compute mel spectrogram\n",
            "speaker embedding cache lookup",
        ),
        (
            "        mx.eval(speaker_embedding)\n\n"
            "        return speaker_embedding\n\n"
            "    def _prepare_generation_inputs(\n",
            "        mx.eval(speaker_embedding)\n\n"
            "        self._speaker_embedding_cache.append((audio, sr, speaker_embedding))\n"
            "        if len(self._speaker_embedding_cache) > 4:\n"
            "            self._speaker_embedding_cache.pop(0)\n\n"
            "        return speaker_embedding\n\n"
            "    def _prepare_generation_inputs(\n",
            "speaker embedding cache store",
        ),
    ]

    for old, new, label in edits:
        source, edit_changed = replace_once(source, old, new, label)
        changed = changed or edit_changed

    if changed:
        path.write_text(source, encoding="utf-8")
        print(f"Patched mlx-audio x-vector batching: {path}", file=sys.stderr)


if __name__ == "__main__":
    main()
