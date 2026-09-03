#!/usr/bin/env python3
"""Render paragraphs with length-aware shared-reference x-vector batching.

The caller prepares ``*.tts.txt`` segment files in a temporary directory.
Long segments are split only inside the renderer, similar lengths are batched
together, and the generated pieces are joined back into sibling
``*.tts.wav`` files. A narration paragraph may contain several segments when
it has animation-stage markers; narrate.sh joins them into one paragraph WAV
to preserve the player's one-paragraph/one-highlight contract.
"""

from __future__ import annotations

import os
import pathlib
import re
import sys
import time
import math
import json
from dataclasses import dataclass

import mlx.core as mx
import mlx.nn as nn
import numpy as np
from huggingface_hub import snapshot_download
from mlx_audio.tts.generate import load_model
from mlx_audio.utils import load_audio
from mlx.utils import tree_unflatten
from scipy.io.wavfile import read as read_wav
from scipy.io.wavfile import write as write_wav


# Qwen normally leaves about 0.5 s at the front and almost no silence at the
# tail. Sampling can occasionally delay EOS with several seconds of silence.
# Keep ordinary timing untouched and only cap clearly anomalous edges.
SILENCE_DBFS = -50.0
SILENCE_FRAME_SECONDS = 0.02
SILENCE_HOP_SECONDS = 0.01
MAX_LEADING_SILENCE_SECONDS = 0.8
KEEP_LEADING_SILENCE_SECONDS = 0.5
MAX_TRAILING_SILENCE_SECONDS = 0.8
KEEP_TRAILING_SILENCE_SECONDS = 0.2
MAX_INTERNAL_SILENCE_SECONDS = 1.25
KEEP_INTERNAL_SILENCE_SECONDS = 0.45
MAX_ELLIPSIS_TRAILING_SILENCE_SECONDS = 2.0
KEEP_ELLIPSIS_TRAILING_SILENCE_SECONDS = 1.0
DEFAULT_CHUNK_CHARS = 240

@dataclass(frozen=True)
class PartJob:
    destination: pathlib.Path
    text: str


@dataclass(frozen=True)
class ParagraphJob:
    destination: pathlib.Path
    text: str
    parts: tuple[PartJob, ...]


@dataclass(frozen=True)
class PartRetry:
    job: PartJob
    reason: str


def silence_cap_enabled() -> bool:
    return os.environ.get("LEARN_QWEN_SILENCE_CAP", "1").lower() not in {
        "0",
        "false",
        "no",
        "off",
    }


def generation_text(job: PartJob) -> str:
    """Return only authored narration; never append a hidden helper sentence."""
    return job.text.rstrip()


class TokenRunWatchdog:
    """Stop one batched sequence when its main codec token gets stuck."""

    def __init__(self, model, max_run: int):
        self.model = model
        self.max_run = max_run
        self.original_sample = model._sample_token_batch
        self.active = False
        self.last_tokens: list[int | None] = []
        self.run_lengths: list[int] = []
        self.done: list[bool] = []
        self.eos_defer_tokens = 0
        self.eos_deferred: list[bool] = []
        self.defer_remaining: list[int] = []
        self.triggered: set[int] = set()
        model._sample_token_batch = self.sample

    def reset(
        self,
        batch_size: int,
        eos_defer_tokens: int = 0,
    ) -> None:
        self.active = True
        self.last_tokens = [None] * batch_size
        self.run_lengths = [0] * batch_size
        self.done = [False] * batch_size
        self.eos_defer_tokens = eos_defer_tokens
        self.eos_deferred = [False] * batch_size
        self.defer_remaining = [0] * batch_size
        self.triggered = set()

    def finish(self) -> set[int]:
        triggered = set(self.triggered)
        self.active = False
        return triggered

    def sample(self, logits, *args, **kwargs):
        eos_token_id = kwargs.get("eos_token_id")
        # Code-predictor calls have no EOS token. Only inspect the first/main
        # codebook, whose long exact runs separated every healthy probe from
        # the observed silence attractor (normal <=2, failure=92).
        if self.active and eos_token_id is not None:
            defer_hold = [
                not self.done[index] and self.defer_remaining[index] > 0
                for index in range(len(self.done))
            ]
            if any(defer_hold):
                row_shape = (len(defer_hold),) + (1,) * (logits.ndim - 1)
                column_shape = (1,) * (logits.ndim - 1) + (logits.shape[-1],)
                rows = mx.reshape(mx.array(defer_hold), row_shape)
                columns = mx.reshape(mx.arange(logits.shape[-1]), column_shape)
                columns = columns == eos_token_id
                logits = mx.where(
                    rows & columns,
                    mx.array(-float("inf"), dtype=logits.dtype),
                    logits,
                )
        else:
            defer_hold = []

        sampled = self.original_sample(logits, *args, **kwargs)
        if not self.active or eos_token_id is None:
            return sampled

        mx.eval(sampled)
        values = sampled[:, 0].tolist()
        newly_deferred = [
            not self.done[index]
            and value == eos_token_id
            and self.eos_defer_tokens > 0
            and not self.eos_deferred[index]
            for index, value in enumerate(values)
        ]
        if any(newly_deferred):
            row_shape = (len(newly_deferred),) + (1,) * (logits.ndim - 1)
            column_shape = (1,) * (logits.ndim - 1) + (logits.shape[-1],)
            rows = mx.reshape(mx.array(newly_deferred), row_shape)
            columns = mx.reshape(mx.arange(logits.shape[-1]), column_shape)
            columns = columns == eos_token_id
            retry_logits = mx.where(
                rows & columns,
                mx.array(-float("inf"), dtype=logits.dtype),
                logits,
            )
            replacement = self.original_sample(retry_logits, *args, **kwargs)
            select_shape = (len(newly_deferred),) + (1,) * (sampled.ndim - 1)
            sampled = mx.where(
                mx.reshape(mx.array(newly_deferred), select_shape),
                replacement,
                sampled,
            )
            mx.eval(sampled)
            values = sampled[:, 0].tolist()
            for index, deferred in enumerate(newly_deferred):
                if deferred:
                    self.eos_deferred[index] = True
                    self.defer_remaining[index] = self.eos_defer_tokens - 1

        changed = False
        for index, value in enumerate(values):
            if self.done[index]:
                continue
            if value == eos_token_id:
                self.done[index] = True
                continue
            if defer_hold[index] and self.defer_remaining[index] > 0:
                self.defer_remaining[index] -= 1
            if value == self.last_tokens[index]:
                self.run_lengths[index] += 1
            else:
                self.last_tokens[index] = value
                self.run_lengths[index] = 1
            if self.run_lengths[index] >= self.max_run:
                self.triggered.add(index)
                self.done[index] = True
                values[index] = eos_token_id
                changed = True

        if changed:
            sampled = mx.array(values, dtype=sampled.dtype)[:, None]
        return sampled


def stabilize_batched_model(
    model, max_token_run: int, use_fp32: bool = True
) -> TokenRunWatchdog:
    """Use deterministic FP32 GEMMs and boundary-safe non-streaming decode."""
    replacements = []
    if use_fp32:
        for name, module in model.talker.named_modules():
            if not isinstance(module, nn.QuantizedLinear):
                continue
            weight = mx.dequantize(
                module.weight,
                module.scales,
                module.biases,
                group_size=module.group_size,
                bits=module.bits,
                mode=module.mode,
                dtype=mx.float32,
            )
            output_dims, input_dims = weight.shape
            linear = nn.Linear(input_dims, output_dims, bias="bias" in module)
            linear.weight = weight
            if "bias" in module:
                linear.bias = module.bias.astype(mx.float32)
            replacements.append((name, linear))

        if replacements:
            model.talker.update_modules(tree_unflatten(replacements))
        model.talker.set_dtype(mx.float32)
        mx.eval(model.talker.parameters())

    def full_decode(generated_codes, *args, **kwargs):
        if not generated_codes:
            return mx.zeros((0,), dtype=mx.float32)
        codes = mx.stack(generated_codes, axis=1)
        audio, lengths = model.speech_tokenizer.decode(codes)
        audio = audio[0]
        valid_length = int(lengths[0])
        if 0 < valid_length < audio.shape[0]:
            audio = audio[:valid_length]
        mx.eval(audio)
        return audio

    # mlx-audio's batch helper decodes 15-token windows with only five tokens
    # of context. Joining those independent vocoder passes can create an
    # audible phase jump. The ordinary tokenizer decode uses a 300-token
    # window and 25-token context, so ordinary narration parts decode whole.
    model._decode_generated_codes = full_decode
    watchdog = TokenRunWatchdog(model, max_token_run)
    print(
        "qwen_batch: stabilized batch model "
        f"(fp32_linear_layers={len(replacements) if use_fp32 else 'off'}, "
        f"full_decode=on, max_token_run={max_token_run})",
        file=sys.stderr,
    )
    return watchdog


def speech_edge_silence(
    audio: np.ndarray,
    sample_rate: int,
) -> tuple[int, int] | None:
    """Return leading/trailing silent samples, or None for non-speech audio."""
    source = np.asarray(audio)
    waveform = source.astype(np.float64)
    if np.issubdtype(source.dtype, np.integer):
        info = np.iinfo(source.dtype)
        waveform /= max(abs(info.min), info.max)
    if waveform.ndim > 1:
        waveform = waveform.mean(axis=1)
    if waveform.size == 0:
        return None

    frame = max(1, round(sample_rate * SILENCE_FRAME_SECONDS))
    hop = max(1, round(sample_rate * SILENCE_HOP_SECONDS))
    if waveform.size < frame:
        return None

    # Window RMS via a cumulative sum avoids materializing a large frame matrix.
    squared = waveform * waveform
    cumulative = np.concatenate(([0.0], np.cumsum(squared)))
    starts = np.arange(0, waveform.size - frame + 1, hop)
    rms = np.sqrt((cumulative[starts + frame] - cumulative[starts]) / frame)
    active = np.flatnonzero(rms >= 10.0 ** (SILENCE_DBFS / 20.0))
    if active.size == 0:
        return None

    first_active = int(starts[active[0]])
    last_active_end = int(starts[active[-1]] + frame)
    return first_active, max(0, waveform.size - last_active_end)


def internal_silence_runs(
    audio: np.ndarray,
    sample_rate: int,
) -> list[tuple[int, int]]:
    """Find low-energy runs fully surrounded by speech."""
    source = np.asarray(audio)
    waveform = source.astype(np.float64)
    if np.issubdtype(source.dtype, np.integer):
        info = np.iinfo(source.dtype)
        waveform /= max(abs(info.min), info.max)
    if waveform.ndim > 1:
        waveform = waveform.mean(axis=1)

    frame = max(1, round(sample_rate * SILENCE_FRAME_SECONDS))
    hop = max(1, round(sample_rate * SILENCE_HOP_SECONDS))
    if waveform.size < frame:
        return []

    squared = waveform * waveform
    cumulative = np.concatenate(([0.0], np.cumsum(squared)))
    starts = np.arange(0, waveform.size - frame + 1, hop)
    rms = np.sqrt((cumulative[starts + frame] - cumulative[starts]) / frame)
    silent = rms < 10.0 ** (SILENCE_DBFS / 20.0)
    if silent.size < 3 or np.all(silent):
        return []

    changes = np.diff(np.concatenate(([False], silent, [False])).astype(np.int8))
    run_starts = np.flatnonzero(changes == 1)
    run_ends = np.flatnonzero(changes == -1)
    runs: list[tuple[int, int]] = []
    for first, after_last in zip(run_starts, run_ends):
        # Edge silence has a separate cadence policy below.
        if first == 0 or after_last == silent.size:
            continue
        start_sample = int(starts[first])
        end_sample = int(starts[after_last - 1] + frame)
        runs.append((start_sample, min(len(audio), end_sample)))
    return runs


def cap_excessive_silence(
    audio: np.ndarray,
    sample_rate: int,
    text: str,
) -> tuple[np.ndarray, list[tuple[str, float, float]]]:
    """Cap anomalous generated silence without changing normal pauses.

    Returns the possibly shortened waveform and one report per adjusted run.
    """
    edges = speech_edge_silence(audio, sample_rate)
    if edges is None:
        return audio, []

    leading, trailing = edges
    leading_seconds = leading / sample_rate
    trailing_seconds = trailing / sample_rate
    cuts: list[tuple[int, int, str, float, float]] = []

    if leading_seconds > MAX_LEADING_SILENCE_SECONDS:
        cut_end = max(0, leading - round(KEEP_LEADING_SILENCE_SECONDS * sample_rate))
        cuts.append((0, cut_end, "lead", leading_seconds, KEEP_LEADING_SILENCE_SECONDS))

    has_ellipsis = bool(re.search(r"(?:\.{2,}|…)[\s\"'’”)]*$", text))
    trailing_limit = (
        MAX_ELLIPSIS_TRAILING_SILENCE_SECONDS
        if has_ellipsis
        else MAX_TRAILING_SILENCE_SECONDS
    )
    trailing_keep = (
        KEEP_ELLIPSIS_TRAILING_SILENCE_SECONDS
        if has_ellipsis
        else KEEP_TRAILING_SILENCE_SECONDS
    )
    if trailing_seconds > trailing_limit:
        last_active_end = len(audio) - trailing
        cut_start = min(
            len(audio), last_active_end + round(trailing_keep * sample_rate)
        )
        cuts.append(
            (cut_start, len(audio), "tail", trailing_seconds, trailing_keep)
        )

    # Explicit ellipses carry an authored thinking pause. Do not infer where it
    # lands acoustically; preserve internal timing for that small class of part.
    if not re.search(r"(?:\.{2,}|…)", text):
        for start, end in internal_silence_runs(audio, sample_rate):
            duration = (end - start) / sample_rate
            if duration <= MAX_INTERNAL_SILENCE_SECONDS:
                continue
            keep_samples = round(KEEP_INTERNAL_SILENCE_SECONDS * sample_rate)
            left_keep = keep_samples // 2
            right_keep = keep_samples - left_keep
            cuts.append(
                (
                    start + left_keep,
                    end - right_keep,
                    "internal",
                    duration,
                    KEEP_INTERNAL_SILENCE_SECONDS,
                )
            )

    cuts = sorted(cut for cut in cuts if cut[1] > cut[0])
    if not cuts:
        return audio, []

    pieces: list[np.ndarray] = []
    cursor = 0
    reports: list[tuple[str, float, float]] = []
    for start, end, kind, before, after in cuts:
        if start < cursor:
            continue
        pieces.append(np.asarray(audio)[cursor:start])
        cursor = end
        reports.append((kind, before, after))
    pieces.append(np.asarray(audio)[cursor:])
    return np.concatenate(pieces), reports


def speech_activity(
    audio: np.ndarray, sample_rate: int
) -> tuple[float, float]:
    """Return active speech seconds and active-frame ratio."""
    source = np.asarray(audio)
    waveform = source.astype(np.float64)
    if np.issubdtype(source.dtype, np.integer):
        info = np.iinfo(source.dtype)
        waveform /= max(abs(info.min), info.max)
    if waveform.ndim > 1:
        waveform = waveform.mean(axis=1)
    frame = max(1, round(sample_rate * SILENCE_FRAME_SECONDS))
    hop = max(1, round(sample_rate * SILENCE_HOP_SECONDS))
    if waveform.size < frame:
        return 0.0, 0.0
    squared = waveform * waveform
    cumulative = np.concatenate(([0.0], np.cumsum(squared)))
    starts = np.arange(0, waveform.size - frame + 1, hop)
    rms = np.sqrt((cumulative[starts + frame] - cumulative[starts]) / frame)
    active_frames = int(
        np.count_nonzero(rms >= 10.0 ** (SILENCE_DBFS / 20.0))
    )
    if active_frames == 0:
        return 0.0, 0.0
    return active_frames * hop / sample_rate, active_frames / len(starts)


def write_generated_part(
    job: PartJob, sample_rate: int, audio: np.ndarray
) -> str | None:
    """Apply narrow silence QC, then persist one generated part."""
    if silence_cap_enabled():
        audio, reports = cap_excessive_silence(audio, sample_rate, job.text)
    else:
        reports = []
    active_seconds, active_ratio = speech_activity(audio, sample_rate)
    minimum_seconds = positive_float("LEARN_QWEN_MIN_VOICED_SECONDS", 0.20)
    minimum_ratio = positive_float("LEARN_QWEN_MIN_VOICED_RATIO", 0.03)
    if active_seconds < minimum_seconds or active_ratio < minimum_ratio:
        job.destination.unlink(missing_ok=True)
        print(
            "qwen_batch: insufficient speech; discarding and retrying "
            f"{job.destination.name} (active={active_seconds:.2f}s, "
            f"ratio={active_ratio:.3f})",
            file=sys.stderr,
        )
        return "non-speech"
    job.destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = job.destination.with_name(
        f".{job.destination.name}.{os.getpid()}.tmp"
    )
    write_wav(temporary, sample_rate, audio)
    os.replace(temporary, job.destination)
    for kind, before, after in reports:
        print(
            "qwen_batch: capped excessive silence "
            f"{job.destination.name} "
            f"({kind} {before:.2f}s->{after:.2f}s)",
            file=sys.stderr,
        )
    return None


def positive_int(name: str, default: int) -> int:
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as exc:
        raise SystemExit(f"{name} must be an integer, got {raw!r}") from exc
    if value <= 0:
        raise SystemExit(f"{name} must be positive, got {value}")
    return value


def nonnegative_int(name: str, default: int) -> int:
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as exc:
        raise SystemExit(f"{name} must be an integer, got {raw!r}") from exc
    if value < 0:
        raise SystemExit(f"{name} must be nonnegative, got {value}")
    return value


def split_long_sentence(text: str, max_chars: int) -> list[str]:
    """Split one oversized sentence at the strongest available clause edge."""
    chunks: list[str] = []
    minimum = max(24, max_chars // 2)
    remaining = text.strip()
    while len(remaining) > max_chars:
        window = remaining[: max_chars + 1]
        cut = -1
        for pattern in (r"[;；:：,，]\s*", r"\s+"):
            matches = list(re.finditer(pattern, window))
            candidates = [match.end() for match in matches if match.end() >= minimum]
            if candidates:
                cut = candidates[-1]
                break
        if cut < minimum:
            cut = max_chars
        chunks.append(remaining[:cut].strip())
        remaining = remaining[cut:].strip()
    if remaining:
        chunks.append(remaining)
    return chunks


def split_text(text: str, max_chars: int) -> list[str]:
    """Keep complete sentences together, splitting only oversized sentences."""
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        return []
    sentences = [
        part.strip()
        for part in re.split(r"(?<=[.!?。！？])\s+", text)
        if part.strip()
    ]
    units: list[str] = []
    for sentence in sentences:
        if len(sentence) <= max_chars:
            units.append(sentence)
        else:
            units.extend(split_long_sentence(sentence, max_chars))

    chunks: list[str] = []
    current = ""
    for unit in units:
        combined = f"{current} {unit}".strip()
        if current and len(combined) > max_chars:
            chunks.append(current)
            current = unit
        else:
            current = combined
    if current:
        chunks.append(current)
    return chunks


def make_jobs(text_files: list[pathlib.Path], max_chars: int) -> list[ParagraphJob]:
    paragraphs: list[ParagraphJob] = []
    for source in text_files:
        text = source.read_text(encoding="utf-8").strip()
        if not text:
            continue
        pieces = split_text(text, max_chars)
        part_dir = source.parent / ".qwen-parts"
        part_dir.mkdir(exist_ok=True)
        parts = tuple(
            PartJob(
                destination=part_dir / f"{source.stem}.part{index:03d}.wav",
                text=piece,
            )
            for index, piece in enumerate(pieces, start=1)
        )
        paragraphs.append(ParagraphJob(source.with_suffix(".wav"), text, parts))
    return paragraphs


def group_text_files_by_section(
    chunk_dir: pathlib.Path,
    text_files: list[pathlib.Path],
) -> list[tuple[str, list[pathlib.Path]]]:
    """Keep chapter order while allowing length batching inside each chapter."""
    grouped: dict[str, list[pathlib.Path]] = {}
    for source in text_files:
        relative = source.relative_to(chunk_dir)
        section = relative.parts[0] if len(relative.parts) > 1 else "root"
        grouped.setdefault(section, []).append(source)
    return [(section, sorted(grouped[section])) for section in sorted(grouped)]


def estimated_audio_tokens(model, job: PartJob, token_factor: float) -> int:
    return max(
        1,
        math.ceil(
            len(model.tokenizer.encode(generation_text(job))) * token_factor
        ),
    )


def plan_batches(
    model,
    jobs: list[PartJob],
    max_batch_size: int,
    audio_token_budget: int,
    token_factor: float,
) -> list[list[PartJob]]:
    """Bucket jobs by predicted generation cost and padded token budget."""
    ordered = sorted(
        jobs,
        key=lambda job: (
            estimated_audio_tokens(model, job, token_factor),
            str(job.destination),
        ),
    )
    batches: list[list[PartJob]] = []
    index = 0
    while index < len(ordered):
        batch: list[PartJob] = []
        while index < len(ordered) and len(batch) < max_batch_size:
            candidate = ordered[index]
            padded_tokens = (len(batch) + 1) * estimated_audio_tokens(
                model, candidate, token_factor
            )
            if batch and padded_tokens > audio_token_budget:
                break
            batch.append(candidate)
            index += 1
        batches.append(batch)
    return batches


def positive_float(name: str, default: float) -> float:
    raw = os.environ.get(name, str(default))
    try:
        value = float(raw)
    except ValueError as exc:
        raise SystemExit(f"{name} must be a number, got {raw!r}") from exc
    if value <= 0:
        raise SystemExit(f"{name} must be positive, got {value}")
    return value


def probability(name: str, default: float) -> float:
    value = positive_float(name, default)
    if value > 1.0:
        raise SystemExit(f"{name} must be at most 1.0, got {value}")
    return value


def sampling_settings() -> tuple[int, float, float]:
    """Return validated Qwen sampling controls in call-order."""
    return (
        positive_int("LEARN_QWEN_TOP_K", 50),
        probability("LEARN_QWEN_TOP_P", 1.0),
        positive_float("LEARN_QWEN_REPETITION_PENALTY", 1.05),
    )


def token_cap(
    model,
    jobs: list[PartJob],
    hard_max: int,
    minimum: int,
    token_factor: float,
) -> int:
    """Bound a batch using target-text tokens instead of one global ceiling."""
    longest = max(estimated_audio_tokens(model, job, token_factor) for job in jobs)
    return min(hard_max, max(minimum, longest))


def render_batch(
    model,
    jobs: list[PartJob],
    ref_audio,
    max_tokens: int,
    minimum_tokens: int,
    token_factor: float,
) -> list[PartRetry]:
    """Render one batch, splitting adaptively if the device rejects its size."""
    texts = [generation_text(job) for job in jobs]
    eos_defer_tokens = nonnegative_int("LEARN_QWEN_EOS_DEFER_TOKENS", 0)
    top_k, top_p, repetition_penalty = sampling_settings()
    watchdog: TokenRunWatchdog = model._learn_token_run_watchdog
    watchdog.reset(
        len(jobs),
        eos_defer_tokens,
    )
    try:
        generated = list(
            model.batch_generate(
                texts=texts,
                ref_audio=ref_audio,
                ref_text=None,
                lang_code="korean",
                temperature=float(os.environ.get("LEARN_QWEN_TEMPERATURE", "0.65")),
                top_k=top_k,
                top_p=top_p,
                repetition_penalty=repetition_penalty,
                max_tokens=max_tokens,
                stream=False,
                verbose=False,
            )
        )
    except Exception as exc:
        watchdog.finish()
        mx.clear_cache()
        if len(jobs) == 1:
            job = jobs[0]
            job.destination.unlink(missing_ok=True)
            return [PartRetry(job, f"engine-error:{type(exc).__name__}: {exc}")]
        midpoint = len(jobs) // 2
        print(
            f"qwen_batch: batch {len(jobs)} failed ({exc}); "
            f"retrying as {midpoint}+{len(jobs) - midpoint}",
            file=sys.stderr,
        )
        return render_batch(
            model,
            jobs[:midpoint],
            ref_audio,
            max_tokens,
            minimum_tokens,
            token_factor,
        ) + render_batch(
            model,
            jobs[midpoint:],
            ref_audio,
            max_tokens,
            minimum_tokens,
            token_factor,
        )

    token_run_indices = watchdog.finish()

    by_index = {result.sequence_idx: result for result in generated}
    missing = sorted(set(range(len(jobs))) - set(by_index))
    retries: list[PartRetry] = [
        PartRetry(jobs[index], "missing-sequence") for index in missing
    ]
    for index, job in enumerate(jobs):
        if index not in by_index:
            job.destination.unlink(missing_ok=True)
            continue
        result = by_index[index]
        if index in token_run_indices:
            job.destination.unlink(missing_ok=True)
            retries.append(PartRetry(job, "token-run"))
            print(
                "qwen_batch: detected codec-token run; discarding and retrying "
                f"{job.destination.name}",
                file=sys.stderr,
            )
            continue
        job_limit = max(
            minimum_tokens,
            estimated_audio_tokens(model, job, token_factor),
        )
        if result.token_count >= min(max_tokens, job_limit) - 1:
            job.destination.unlink(missing_ok=True)
            retries.append(PartRetry(job, "token-cap"))
            continue
        audio = np.asarray(result.audio, dtype=np.float32)
        rejection = write_generated_part(job, result.sample_rate, audio)
        if rejection:
            retries.append(PartRetry(job, rejection))
    mx.clear_cache()
    return retries


def stitch_wavs(sources: list[pathlib.Path], destination: pathlib.Path) -> None:
    sample_rate: int | None = None
    audio_parts: list[np.ndarray] = []
    for source in sources:
        current_rate, audio = read_wav(source)
        if sample_rate is None:
            sample_rate = current_rate
        elif current_rate != sample_rate:
            raise RuntimeError(
                f"sample-rate mismatch while stitching {destination}: "
                f"{sample_rate} != {current_rate}"
            )
        audio_parts.append(np.asarray(audio, dtype=np.float32))
    if sample_rate is None or not audio_parts:
        raise RuntimeError(f"no generated audio parts for {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
    write_wav(temporary, sample_rate, np.concatenate(audio_parts))
    os.replace(temporary, destination)


def write_failure_placeholder(
    job: PartJob,
    sample_rate: int,
    reason: str,
    seconds: float = 0.35,
) -> None:
    """Quarantine one exhausted part without changing voice or aborting siblings."""
    job.destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = job.destination.with_name(
        f".{job.destination.name}.{os.getpid()}.tmp"
    )
    write_wav(
        temporary,
        sample_rate,
        np.zeros(max(1, round(sample_rate * seconds)), dtype=np.float32),
    )
    os.replace(temporary, job.destination)
    print(
        "qwen_batch: isolated failed part with a silent placeholder "
        f"{job.destination.name} ({reason})",
        file=sys.stderr,
    )


def recover_part(
    model,
    job: PartJob,
    ref_audio,
    hard_max: int,
    minimum_tokens: int,
    token_factor: float,
    depth: int = 0,
) -> None:
    """Split and retry a part rejected by a generation quality guard."""
    if depth >= 3:
        raise RuntimeError(
            f"Qwen generation failed quality guards after retries: {job.destination}"
        )
    if len(job.text) < 48:
        cap = token_cap(
            model, [job], hard_max, minimum_tokens, token_factor
        )
        retries = render_batch(
            model, [job], ref_audio, cap, minimum_tokens, token_factor
        )
        if retries:
            recover_part(
                model,
                retries[0].job,
                ref_audio,
                hard_max,
                minimum_tokens,
                token_factor,
                depth + 1,
            )
        return
    children_text = split_text(job.text, max(32, len(job.text) // 2))
    if len(children_text) < 2:
        midpoint = len(job.text) // 2
        children_text = [job.text[:midpoint].strip(), job.text[midpoint:].strip()]
    children = [
        PartJob(
            job.destination.with_name(f"{job.destination.stem}.retry{depth}-{i}.wav"),
            text,
        )
        for i, text in enumerate(children_text, start=1)
        if text
    ]
    cap = token_cap(model, children, hard_max, minimum_tokens, token_factor)
    retries = render_batch(
        model, children, ref_audio, cap, minimum_tokens, token_factor
    )
    for retry in retries:
        recover_part(
            model,
            retry.job,
            ref_audio,
            hard_max,
            minimum_tokens,
            token_factor,
            depth + 1,
        )
    stitch_wavs([child.destination for child in children], job.destination)


def recover_or_isolate(
    model,
    retry: PartRetry,
    ref_audio,
    hard_max: int,
    minimum_tokens: int,
    token_factor: float,
    chunk_dir: pathlib.Path,
) -> dict[str, str] | None:
    """Recover one rejected part or replace only that part with a warning gap."""
    try:
        recover_part(
            model,
            retry.job,
            ref_audio,
            hard_max,
            minimum_tokens,
            token_factor,
        )
        return None
    except Exception as exc:
        reason = f"{retry.reason}; {type(exc).__name__}: {exc}"
        write_failure_placeholder(retry.job, model.sample_rate, reason)
        return {
            "part": str(retry.job.destination.relative_to(chunk_dir)),
            "text": retry.job.text,
            "reason": reason,
        }


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit(
            "usage: qwen_batch.py <chunk_dir> <reference.wav> "
            "<reference.txt> <model_repo>"
        )

    chunk_dir = pathlib.Path(sys.argv[1])
    ref_audio = pathlib.Path(sys.argv[2])
    ref_text_file = pathlib.Path(sys.argv[3])
    model_repo = sys.argv[4]

    if not ref_audio.is_file():
        raise SystemExit(f"reference audio not found: {ref_audio}")
    if not ref_text_file.is_file() or not ref_text_file.read_text(
        encoding="utf-8"
    ).strip():
        raise SystemExit(f"reference transcript missing or empty: {ref_text_file}")

    # narrate.sh passes its temporary root. The model remains loaded once, while
    # chapters are rendered in NN order and only paragraphs inside one chapter
    # are length-batched together. This makes render progress follow the book.
    text_files = sorted(chunk_dir.rglob("*.tts.txt"))
    max_chars = positive_int("LEARN_QWEN_CHUNK_CHARS", DEFAULT_CHUNK_CHARS)
    file_groups = group_text_files_by_section(chunk_dir, text_files)
    paragraph_groups = [
        (section, make_jobs(files, max_chars)) for section, files in file_groups
    ]
    paragraphs = [
        paragraph
        for _section, section_paragraphs in paragraph_groups
        for paragraph in section_paragraphs
    ]
    if not paragraphs:
        return
    parts = [part for paragraph in paragraphs for part in paragraph.parts]

    # Validate all tunables before paying the model-load cost or writing audio.
    max_batch_size = positive_int("LEARN_QWEN_BATCH_SIZE", 16)
    max_token_run = positive_int("LEARN_QWEN_MAX_TOKEN_RUN", 16)
    audio_token_budget = positive_int(
        "LEARN_QWEN_BATCH_AUDIO_TOKEN_BUDGET", 4000
    )
    hard_max_tokens = positive_int("LEARN_QWEN_MAX_TOKENS", 1200)
    minimum_tokens = positive_int("LEARN_QWEN_MIN_TOKENS", 120)
    token_factor = positive_float("LEARN_QWEN_TOKEN_FACTOR", 4.0)
    seed = positive_int("LEARN_QWEN_SEED", 20260907)
    positive_float("LEARN_QWEN_TEMPERATURE", 0.65)
    top_k, top_p, repetition_penalty = sampling_settings()
    nonnegative_int("LEARN_QWEN_EOS_DEFER_TOKENS", 0)
    positive_float("LEARN_QWEN_MIN_VOICED_SECONDS", 0.20)
    voiced_ratio = positive_float("LEARN_QWEN_MIN_VOICED_RATIO", 0.03)
    if voiced_ratio > 1.0:
        raise SystemExit("LEARN_QWEN_MIN_VOICED_RATIO must be at most 1.0")
    if minimum_tokens > hard_max_tokens:
        raise SystemExit(
            "LEARN_QWEN_MIN_TOKENS must not exceed LEARN_QWEN_MAX_TOKENS"
        )
    print(
        "qwen_batch: sampling "
        f"temperature={os.environ.get('LEARN_QWEN_TEMPERATURE', '0.65')} "
        f"top_k={top_k} top_p={top_p} "
        f"repetition_penalty={repetition_penalty}",
        file=sys.stderr,
    )

    load_started = time.perf_counter()
    model = load_model(pathlib.Path(snapshot_download(model_repo)))
    model._learn_token_run_watchdog = stabilize_batched_model(
        model, max_token_run, use_fp32=max_batch_size > 1
    )
    load_seconds = time.perf_counter() - load_started
    mx.random.seed(seed)
    reference_waveform = load_audio(str(ref_audio), sample_rate=model.sample_rate)
    started = time.perf_counter()
    retry_hits: list[PartRetry] = []
    batch_count = 0
    for section, section_paragraphs in paragraph_groups:
        section_parts = [
            part for paragraph in section_paragraphs for part in paragraph.parts
        ]
        batches = plan_batches(
            model,
            section_parts,
            max_batch_size,
            audio_token_budget,
            token_factor,
        )
        print(
            f"qwen_batch: chapter {section} "
            f"paragraphs={len(section_paragraphs)} batches={len(batches)}",
            file=sys.stderr,
        )
        for batch_index, batch in enumerate(batches, start=1):
            cap = token_cap(
                model, batch, hard_max_tokens, minimum_tokens, token_factor
            )
            batch_started = time.perf_counter()
            retry_hits.extend(
                render_batch(
                    model,
                    batch,
                    reference_waveform,
                    cap,
                    minimum_tokens,
                    token_factor,
                )
            )
            batch_count += 1
            print(
                f"qwen_batch: chapter {section} batch {batch_index}/{len(batches)} "
                f"n={len(batch)} predicted_tokens="
                f"{estimated_audio_tokens(model, batch[-1], token_factor)} cap={cap} "
                f"in {time.perf_counter() - batch_started:.2f}s",
                file=sys.stderr,
            )

    failures: list[dict[str, str]] = []
    for retry in retry_hits:
        print(
            f"qwen_batch: {retry.reason} guard reached; retrying "
            f"{retry.job.destination.name} ({len(retry.job.text)} chars)",
            file=sys.stderr,
        )
        failure = recover_or_isolate(
            model,
            retry,
            reference_waveform,
            hard_max_tokens,
            minimum_tokens,
            token_factor,
            chunk_dir,
        )
        if failure:
            failures.append(failure)

    if failures:
        (chunk_dir / "qwen-partial-failures.json").write_text(
            json.dumps({"failures": failures}, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    for paragraph in paragraphs:
        stitch_wavs(
            [part.destination for part in paragraph.parts], paragraph.destination
        )
    elapsed = time.perf_counter() - started
    split_count = sum(len(paragraph.parts) - 1 for paragraph in paragraphs)
    print(
        f"qwen_batch: rendered {len(paragraphs)} paragraphs as {len(parts)} parts "
        f"in {elapsed:.2f}s (batches={batch_count}, max_batch={max_batch_size}, "
        f"internal_splits={split_count}, model_load={load_seconds:.2f}s)",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
