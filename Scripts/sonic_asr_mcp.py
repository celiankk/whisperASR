#!/usr/bin/env python3
"""SonicScribe ASR MCP Server.

Bridges SonicScribe / WhisperASR on-device speech recognition engines
(SenseVoice, Paraformer, Whisper) to the Model Context Protocol (MCP).
Enables AI Agent harnesses (e.g. ZCode, Claude) to drive the ASR engine and
execute streaming benchmarks on the ASR Benchmark Workbench.

Tools:
    get_asr_status          - Engine readiness, model paths and active config.
    list_models             - Enumerate selectable engines with readiness,
                              language coverage and blockers.
    update_engine_config    - Hot-swap the engine and its hyper-parameters.
    transcribe_file         - Single-pass full file transcription, engine-aware.
    stream_transcribe       - Stream audio chunks with simulated network arrival,
                              yielding real-time partial/final timestamps & texts.
    benchmark_models        - Latency/accuracy matrix over engines x audio files.
"""

from __future__ import annotations

import json
import logging
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import wave
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

# Ensure logging strictly outputs to stderr (stdout belongs to MCP JSON-RPC protocol)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-7s [sonic-asr] %(message)s",
    datefmt="%H:%M:%S",
    stream=sys.stderr,
    force=True,
)
logger = logging.getLogger("sonic_asr_mcp")

# SDK import
try:
    from mcp.server.fastmcp import FastMCP
except ImportError:
    try:
        from mcp.server.mcpserver import MCPServer as FastMCP
    except ImportError:
        logger.critical("mcp package is required. Run: pip install mcp")
        sys.exit(1)

# Default model directory
MODELS_BASE = Path.home() / "Library/Application Support/WhisperASR/Models"
SENSEVOICE_DIR = MODELS_BASE / "sense-voice-zh-en-ja-ko-yue"
PARAFORMER_DIR = MODELS_BASE / "streaming-paraformer-bilingual-zh-en"
SILERO_VAD_PATH = MODELS_BASE / "silero_vad.onnx"
WHISPER_SMALL = MODELS_BASE / "ggml-small.bin"
WHISPER_MEDIUM = MODELS_BASE / "ggml-medium.bin"
QWEN3_GGUF = MODELS_BASE / "qwen3-asr-1.7b-bf16.gguf"

REPO_ROOT = Path(__file__).resolve().parent.parent

# SenseVoice ships a fixed language set; anything else silently degrades to
# auto inside sherpa-onnx, so we reject it up front instead.
SENSEVOICE_LANGS: Tuple[str, ...] = ("zh", "en", "ja", "ko", "yue")


# --------------------------------------------------------------------------- #
# Engine registry
# --------------------------------------------------------------------------- #


@dataclass
class EngineSpec:
    """A selectable recognition backend and everything needed to judge readiness."""

    id: str
    label: str
    kind: str                       # sherpa-sensevoice | sherpa-paraformer | whisper-ggml
    languages: Optional[Tuple[str, ...]]   # None => pass any code through
    files: Dict[str, Path] = field(default_factory=dict)
    notes: str = ""

    @property
    def missing_files(self) -> List[str]:
        return [name for name, path in self.files.items() if not path.exists()]

    def blockers(self) -> List[str]:
        """Human-readable reasons this engine cannot run right now."""
        reasons = [f"missing file: {self.files[n]}" for n in self.missing_files]
        if self.kind == "whisper-ggml" and not _resolve_whisper_cli():
            reasons.append(
                "no whisper-cli binary found (build it with: "
                "cmake -B build .whisper.cpp && cmake --build build -j --target whisper-cli, "
                "or set WHISPER_CLI=/path/to/whisper-cli)"
            )
        return reasons

    @property
    def ready(self) -> bool:
        return not self.blockers()


ENGINES: Dict[str, EngineSpec] = {
    spec.id: spec
    for spec in (
        EngineSpec(
            id="sense-voice",
            label="SenseVoice-Small (zh/en/ja/ko/yue, offline ONNX, CPU)",
            kind="sherpa-sensevoice",
            languages=SENSEVOICE_LANGS,
            files={
                "model": SENSEVOICE_DIR / "model.int8.onnx",
                "tokens": SENSEVOICE_DIR / "tokens.txt",
            },
        ),
        EngineSpec(
            id="whisper-small",
            label="Whisper small (multilingual ggml, GPU/Metal)",
            kind="whisper-ggml",
            languages=None,
            files={"model": WHISPER_SMALL},
        ),
        EngineSpec(
            id="whisper-medium",
            label="Whisper medium (multilingual ggml, GPU/Metal)",
            kind="whisper-ggml",
            languages=None,
            files={"model": WHISPER_MEDIUM},
        ),
        EngineSpec(
            id="paraformer-zh-en",
            label="Paraformer streaming bilingual zh/en",
            kind="sherpa-paraformer",
            languages=("zh", "en"),
            files={
                "encoder": PARAFORMER_DIR / "encoder.int8.onnx",
                "decoder": PARAFORMER_DIR / "decoder.int8.onnx",
                "tokens": PARAFORMER_DIR / "tokens.txt",
            },
            notes="Model directory on disk has truncated filenames "
                  "(encoder.onnx/coder.onnx, tokens.txt/kens.txt).",
        ),
    )
}

DEFAULT_ENGINE = "sense-voice"

# Cached backends, keyed by (engine, language, num_threads, use_itn) so that
# switching engines or language hints reloads exactly once.
_BACKENDS: Dict[Tuple[Any, ...], Any] = {}

_active_config: Dict[str, Any] = {
    "engine": DEFAULT_ENGINE,
    "language": "auto",
    "vad_threshold": 0.5,
    "trailing_silence_ms": 500,
    "num_threads": 2,
    "use_itn": True,
}


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #


def _resolve_whisper_cli() -> Optional[Path]:
    """Locate a whisper.cpp CLI, preferring an explicit override."""
    candidates: List[Optional[str]] = [os.environ.get("WHISPER_CLI")]
    candidates += [
        str(REPO_ROOT / ".whisper.cpp/build/bin/whisper-cli"),
        str(REPO_ROOT / ".whisper.cpp/build/bin/main"),
    ]
    candidates += [shutil.which(n) for n in ("whisper-cli", "whisper-cpp", "main")]
    for cand in candidates:
        if not cand:
            continue
        path = Path(cand)
        if path.is_file() and os.access(path, os.X_OK):
            return path
    return None


def _engine_spec(engine: Optional[str]) -> EngineSpec:
    key = (engine or _active_config["engine"]).strip().lower()
    if key not in ENGINES:
        raise ValueError(
            f"unknown engine {key!r}; available: {', '.join(sorted(ENGINES))}"
        )
    return ENGINES[key]


def _resolve_language(spec: EngineSpec, language: Optional[str]) -> str:
    """Validate the language hint against the engine and return what to forward.

    Empty string means "let the engine auto-detect".
    """
    lang = (language or "").strip().lower()
    if lang in ("", "auto", "none"):
        return ""
    if spec.languages is not None and lang not in spec.languages:
        raise ValueError(
            f"engine {spec.id!r} does not support language {lang!r}; "
            f"supported: {', '.join(spec.languages)}. "
            f"Pass language='auto', or pick an engine that covers it."
        )
    return lang


def _load_samples(audio_path: str) -> Tuple[List[float], int, float]:
    """Read a WAV as mono float32 samples. Returns (samples, sample_rate, duration_s)."""
    import soundfile as sf

    path = Path(audio_path).resolve()
    if not path.exists():
        raise FileNotFoundError(f"Audio file not found: {path}")
    samples, sr = sf.read(str(path), dtype="float32")
    if getattr(samples, "ndim", 1) > 1:
        samples = samples.mean(axis=1)
    data = samples.tolist()
    return data, int(sr), len(data) / float(sr)


def _write_wav16k(samples: Sequence[float], sample_rate: int, target: Path) -> Path:
    """Write 16-bit mono PCM at 16 kHz, transcoding via ffmpeg when needed."""
    if sample_rate != 16000:
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            raise RuntimeError(
                f"audio is {sample_rate} Hz but the whisper backend needs 16 kHz, "
                f"and ffmpeg is not on PATH to resample it"
            )
        raw = target.with_suffix(".src.wav")
        _write_wav16k_at(samples, sample_rate, raw)
        try:
            subprocess.run(
                [ffmpeg, "-y", "-loglevel", "error", "-i", str(raw),
                 "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(target)],
                check=True, capture_output=True,
            )
        finally:
            raw.unlink(missing_ok=True)
        return target
    _write_wav16k_at(samples, 16000, target)
    return target


def _write_wav16k_at(samples: Sequence[float], sample_rate: int, target: Path) -> None:
    pcm = struct.pack(
        f"<{len(samples)}h",
        *(max(-32768, min(32767, int(s * 32767))) for s in samples),
    )
    with wave.open(str(target), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(pcm)


def _char_error_rate(reference: str, hypothesis: str) -> Optional[float]:
    """Character error rate, jiwer when available, else a local Levenshtein."""
    if not reference:
        return None
    try:
        import jiwer  # type: ignore

        return float(jiwer.cer(reference, hypothesis))
    except Exception:
        pass

    def normalise(text: str) -> List[str]:
        return list(re.sub(r"\s+", "", text.strip().lower()))

    ref, hyp = normalise(reference), normalise(hypothesis)
    prev = list(range(len(hyp) + 1))
    for i, rc in enumerate(ref, 1):
        cur = [i]
        for j, hc in enumerate(hyp, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (rc != hc)))
        prev = cur
    return prev[-1] / float(len(ref)) if ref else None


# --------------------------------------------------------------------------- #
# Backends
# --------------------------------------------------------------------------- #


class SherpaSenseVoiceBackend:
    """SenseVoice-Small through sherpa-onnx, offline single-pass decode."""

    name = "sherpa-sensevoice"

    def __init__(self, spec: EngineSpec, language: str, num_threads: int, use_itn: bool):
        import sherpa_onnx

        self.spec = spec
        t0 = time.perf_counter()
        self._rec = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=str(spec.files["model"]),
            tokens=str(spec.files["tokens"]),
            num_threads=num_threads,
            use_itn=use_itn,
            language=language,
        )
        self.load_ms = (time.perf_counter() - t0) * 1000.0

    def transcribe(self, samples: Sequence[float], sample_rate: int) -> str:
        stream = self._rec.create_stream()
        stream.accept_waveform(sample_rate, list(samples))
        self._rec.decode_stream(stream)
        return stream.result.text.strip()


class WhisperGgmlBackend:
    """Whisper.cpp ggml models, driven through the whisper-cli executable."""

    name = "whisper-ggml"

    def __init__(self, spec: EngineSpec, language: str, num_threads: int,
                 use_itn: bool, task: str = "transcribe"):
        cli = _resolve_whisper_cli()
        if cli is None:
            raise RuntimeError("no whisper-cli binary available")
        self.spec = spec
        self._cli = cli
        self._language = language or "auto"
        self._threads = num_threads
        self._task = task
        self.last_infer_ms = 0.0
        self.last_wall_ms = 0.0
        self.load_ms = 0.0   # the model is loaded inside each CLI invocation

    def transcribe(self, samples: Sequence[float], sample_rate: int) -> str:
        text, self.load_ms, self.last_infer_ms, self.last_wall_ms = self._run(
            samples, sample_rate
        )
        return text

    def _run(self, samples: Sequence[float], sample_rate: int):
        with tempfile.TemporaryDirectory(prefix="sonic-asr-") as tmp:
            wav = _write_wav16k(samples, sample_rate, Path(tmp) / "in.wav")
            cmd = [str(self._cli), "-m", str(self.spec.files["model"]),
                   "-f", str(wav), "-t", str(self._threads), "-nt",
                   "-l", self._language]
            if self._task == "translate":
                cmd.append("-tr")   # speech translation to English
            t0 = time.perf_counter()
            proc = subprocess.run(cmd, capture_output=True, text=True)
            wall_ms = (time.perf_counter() - t0) * 1000.0
            if proc.returncode != 0:
                raise RuntimeError(
                    f"whisper-cli exited {proc.returncode}: {proc.stderr.strip()[-400:]}"
                )
        text = " ".join(
            line.strip() for line in proc.stdout.splitlines()
            if line.strip() and not line.strip().startswith("[")
        ).strip()

        def timing(pattern: str) -> float:
            match = re.search(pattern, proc.stderr)
            return float(match.group(1)) if match else 0.0

        load_ms = timing(r"load time\s*=\s*([\d.]+)\s*ms")
        infer_ms = timing(r"total time\s*=\s*([\d.]+)\s*ms")
        if infer_ms <= 0.0:
            infer_ms = wall_ms
        return text, load_ms, infer_ms, wall_ms


def _get_backend(spec: EngineSpec, language: str, num_threads: int, use_itn: bool,
                 task: str = "transcribe") -> Tuple[Any, float]:
    """Return (backend, load_ms). Cached; load_ms is 0.0 on a cache hit."""
    key = (spec.id, language, num_threads, use_itn, task)
    cached = _BACKENDS.get(key)
    if cached is not None:
        return cached, 0.0

    if task not in ("transcribe", "translate"):
        raise ValueError(f"task must be 'transcribe' or 'translate', got {task!r}")
    if task == "translate" and spec.kind != "whisper-ggml":
        raise ValueError(
            f"engine {spec.id!r} cannot translate; only the whisper engines do "
            f"(whisper-small / whisper-medium)"
        )

    if spec.kind == "sherpa-sensevoice":
        backend: Any = SherpaSenseVoiceBackend(spec, language, num_threads, use_itn)
    elif spec.kind == "whisper-ggml":
        backend = WhisperGgmlBackend(spec, language, num_threads, use_itn, task)
    else:
        raise RuntimeError(
            f"engine {spec.id!r} is not runnable: " + "; ".join(spec.blockers())
        )

    _BACKENDS[key] = backend
    return backend, float(getattr(backend, "load_ms", 0.0))


def _infer(spec: EngineSpec, language: str, num_threads: int, use_itn: bool,
           samples: Sequence[float], sample_rate: int,
           task: str = "transcribe") -> Dict[str, Any]:
    """One backend call, timed. Shared by transcribe_file / stream / benchmark."""
    backend, load_ms = _get_backend(spec, language, num_threads, use_itn, task)
    t0 = time.perf_counter()
    text = backend.transcribe(samples, sample_rate)
    infer_ms = (time.perf_counter() - t0) * 1000.0
    if spec.kind == "whisper-ggml":
        # whisper-cli reports its own encode+decode time, which excludes the
        # process spawn and the temp-WAV write; prefer it when present.
        load_ms = float(getattr(backend, "load_ms", load_ms) or load_ms)
        reported = float(getattr(backend, "last_infer_ms", 0.0) or 0.0)
        if reported > 0.0:
            infer_ms = reported
    return {"text": text, "load_ms": round(load_ms, 1), "infer_ms": round(infer_ms, 1),
            "cached": load_ms == 0.0}


# --------------------------------------------------------------------------- #
# MCP surface
# --------------------------------------------------------------------------- #


server = FastMCP(
    "sonic-asr",
    instructions="SonicScribe on-device speech recognition & streaming inference server.",
)


@server.tool()
def get_asr_status() -> str:
    """Introspect SonicScribe ASR engine readiness, models and configurations."""
    try:
        models_found = []
        if MODELS_BASE.exists():
            for path in MODELS_BASE.iterdir():
                if path.is_dir() or path.suffix in (".bin", ".onnx", ".gguf"):
                    models_found.append(path.name)

        api_online = False
        try:
            import urllib.request

            req = urllib.request.Request("http://127.0.0.1:8080/v1/models", method="GET")
            with urllib.request.urlopen(req, timeout=0.3) as resp:
                api_online = resp.status == 200
        except Exception:
            api_online = False

        return json.dumps({
            "ok": True,
            "engine": "SonicScribe ASR",
            "active_config": _active_config,
            "models_directory": str(MODELS_BASE),
            "available_models": models_found,
            "engines": [_describe(spec) for spec in ENGINES.values()],
            "sense_voice_ready": ENGINES["sense-voice"].ready,
            "silero_vad_ready": SILERO_VAD_PATH.exists(),
            "whisper_cli": str(_resolve_whisper_cli() or ""),
            "local_http_api_online": api_online,
        }, ensure_ascii=False, indent=2)
    except Exception as exc:
        logger.exception("get_asr_status failed")
        return json.dumps({"ok": False, "error": str(exc)})


def _describe(spec: EngineSpec) -> Dict[str, Any]:
    return {
        "id": spec.id,
        "label": spec.label,
        "kind": spec.kind,
        "ready": spec.ready,
        "languages": list(spec.languages) if spec.languages else "any (engine auto-detect)",
        "blockers": spec.blockers(),
        "notes": spec.notes,
    }


@server.tool()
def list_models(probe: bool = False) -> str:
    """List selectable ASR engines with readiness, language coverage and blockers.

    Args:
        probe: When true, actually load each ready engine and report its real
            load latency. Slower, but proves the engine runs rather than
            just that its files exist.
    """
    try:
        rows = []
        for spec in ENGINES.values():
            row = _describe(spec)
            if probe:
                if spec.ready:
                    try:
                        language = _resolve_language(spec, "auto")
                        backend, load_ms = _get_backend(
                            spec, language, _active_config["num_threads"],
                            _active_config["use_itn"],
                        )
                        row["probe"] = "ok"
                        row["probe_load_ms"] = round(
                            load_ms or float(getattr(backend, "load_ms", 0.0)), 1
                        )
                    except Exception as exc:
                        row["probe"] = f"failed: {exc}"
                else:
                    row["probe"] = "skipped (not ready)"
            rows.append(row)
        return json.dumps({
            "ok": True, "active_engine": _active_config["engine"], "engines": rows,
        }, ensure_ascii=False, indent=2)
    except Exception as exc:
        logger.exception("list_models failed")
        return json.dumps({"ok": False, "error": str(exc)})


@server.tool()
def update_engine_config(
    engine: Optional[str] = None,
    vad_threshold: Optional[float] = None,
    trailing_silence_ms: Optional[int] = None,
    language: Optional[str] = None,
    num_threads: Optional[int] = None,
    use_itn: Optional[bool] = None,
    **kwargs: Any,
) -> str:
    """Hot-swap the ASR engine and update its hyper-parameters.

    Unknown keyword arguments are rejected rather than silently ignored, so a
    typo can never masquerade as a successful reconfiguration.

    Args:
        engine: Engine id from `list_models` (e.g. 'sense-voice', 'whisper-small').
        vad_threshold: Float 0.0-1.0 for VAD speech sensitivity (lower = more sensitive).
        trailing_silence_ms: Milliseconds of trailing silence before committing an utterance.
        language: Language hint ('auto', 'zh', 'en', 'ja', 'ko', 'yue'). Validated
            against the selected engine's coverage.
        num_threads: Number of CPU decoding threads.
        use_itn: Inverse text normalisation (digits, punctuation).
    """
    try:
        if kwargs:
            raise ValueError(
                f"unknown config key(s): {', '.join(sorted(kwargs))}. Accepted: "
                "engine, vad_threshold, trailing_silence_ms, language, num_threads, use_itn"
            )

        changed: List[str] = []

        if engine is not None:
            spec = _engine_spec(engine)
            if not spec.ready:
                raise ValueError(
                    f"engine {spec.id!r} is not runnable: " + "; ".join(spec.blockers())
                )
            _active_config["engine"] = spec.id
            changed.append("engine")

        if language is not None:
            spec = _engine_spec(engine)
            lang = language.strip().lower()
            if lang in ("", "auto", "none"):
                _active_config["language"] = "auto"
            else:
                _resolve_language(spec, lang)   # raises when unsupported
                _active_config["language"] = lang
            changed.append("language")

        if vad_threshold is not None:
            value = float(vad_threshold)
            if not 0.0 <= value <= 1.0:
                raise ValueError(f"vad_threshold must be within [0, 1], got {value}")
            _active_config["vad_threshold"] = value
            changed.append("vad_threshold")

        if trailing_silence_ms is not None:
            value = int(trailing_silence_ms)
            if value < 0:
                raise ValueError(f"trailing_silence_ms must be >= 0, got {value}")
            _active_config["trailing_silence_ms"] = value
            changed.append("trailing_silence_ms")

        if num_threads is not None:
            value = int(num_threads)
            if value < 1:
                raise ValueError(f"num_threads must be >= 1, got {value}")
            _active_config["num_threads"] = value
            _BACKENDS.clear()               # thread count is a load-time setting
            changed.append("num_threads")

        if use_itn is not None:
            _active_config["use_itn"] = bool(use_itn)
            changed.append("use_itn")

        # Engine and language are bound at load time; drop cached backends so
        # the next call actually picks the new setting up.
        if {"engine", "language", "use_itn"} & set(changed):
            _BACKENDS.clear()

        return json.dumps({
            "ok": True,
            "message": "Engine configuration updated",
            "changed": changed,
            "active_config": _active_config,
        }, ensure_ascii=False, indent=2)
    except Exception as exc:
        logger.warning("update_engine_config rejected: %s", exc)
        return json.dumps({
            "ok": False, "error": str(exc), "active_config": _active_config,
        }, ensure_ascii=False, indent=2)


@server.tool()
def transcribe_file(
    audio_path: str,
    language: str = "auto",
    engine: Optional[str] = None,
    reference: str = "",
    task: str = "transcribe",
) -> str:
    """Transcribe a full audio file in a single pass.

    Args:
        audio_path: Absolute filesystem path to a WAV audio file.
        language: Target language hint ('auto', 'zh', 'en', 'ja', 'ko', 'yue').
        engine: Engine id from `list_models`; defaults to the active engine.
        reference: Optional ground-truth transcript; when given, the response
            includes a character error rate so accuracy is scored in-band.
        task: 'transcribe' (default) or 'translate'. Translation is speech
            translation into English and is only available on the whisper
            engines (sense-voice cannot translate).
    """
    try:
        spec = _engine_spec(engine)
        if not spec.ready:
            return json.dumps({
                "ok": False, "engine": spec.id,
                "error": "engine not runnable: " + "; ".join(spec.blockers()),
            }, ensure_ascii=False)
        lang = _resolve_language(spec, language)
        samples, sr, duration_s = _load_samples(audio_path)
        result = _infer(spec, lang, _active_config["num_threads"],
                        _active_config["use_itn"], samples, sr, task)

        payload: Dict[str, Any] = {
            "ok": True,
            "engine": spec.id,
            "task": task,
            "language": lang or "auto",
            "text": result["text"],
            "duration_s": round(duration_s, 2),
            "load_ms": result["load_ms"],
            "infer_ms": result["infer_ms"],
            "backend_cached": result["cached"],
            "rtf": round(result["infer_ms"] / 1000.0 / max(0.001, duration_s), 3),
        }
        if reference:
            payload["cer"] = _char_error_rate(reference, result["text"])
            payload["reference"] = reference
        return json.dumps(payload, ensure_ascii=False, indent=2)
    except Exception as exc:
        logger.exception("transcribe_file failed")
        return json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False)


def _chunk_span_ms(event: Dict[str, Any], index: int, count: int,
                   total_ms: float) -> Tuple[float, float]:
    """Audio window [start_ms, end_ms) for one arrival-timeline entry.

    The workbench manifest carries `audio_sent_ms` + `duration_ms`, which tile
    the clip contiguously. Splitting the clip into equal `total/count` windows
    instead leaves a gap at every boundary (320 ms spacing vs a 293 ms window
    on the 11-chunk smoke sample), splicing 27 ms holes into the waveform.
    """
    if "start_ms" in event and "end_ms" in event:
        return float(event["start_ms"]), float(event["end_ms"])
    sent = float(event.get("audio_sent_ms", event.get("sent_ms", 0.0)))
    if "duration_ms" in event:
        return sent, sent + float(event["duration_ms"])
    step = total_ms / max(1, count)
    return index * step, (index + 1) * step


@server.tool()
def stream_transcribe(
    audio_path: str,
    arrival_timeline_json: str,
    language: str = "auto",
    engine: Optional[str] = None,
    config_json: str = "{}",
) -> str:
    """Stream audio chunks following an arrival timeline and yield real-time events.

    Feeds audio chunks into the recognition engine in temporal order (respecting
    network delay, jitter and drops). Generates partial transcripts and final
    committed hypothesis along with exact timestamps. The output directly conforms
    to the input expected by `submit_and_persist_stream_result` on the benchmark
    workbench.

    Args:
        audio_path: Absolute path to the WAV file.
        arrival_timeline_json: JSON array of chunks from `simulate_network_impairment`
            or `chunk_manifest`.
        language: Language code hint ('zh', 'en', 'auto', etc.).
        engine: Engine id from `list_models`; defaults to the active engine.
        config_json: Optional hyper-parameter overrides, merged over the active
            config for this session only (e.g. {"num_threads": 4}).
    """
    try:
        spec = _engine_spec(engine)
        if not spec.ready:
            return json.dumps({
                "ok": False, "engine": spec.id,
                "error": "engine not runnable: " + "; ".join(spec.blockers()),
            }, ensure_ascii=False)

        overrides = json.loads(config_json) if config_json and config_json != "{}" else {}
        if not isinstance(overrides, dict):
            return json.dumps({"ok": False, "error": "config_json must be an object"})
        unknown = set(overrides) - {
            "language", "num_threads", "use_itn", "chunk_size_ms", "engine",
            "whisper_decode_stride", "task",
        }
        if unknown:
            return json.dumps({
                "ok": False,
                "error": f"unsupported config_json key(s): {', '.join(sorted(unknown))}",
            }, ensure_ascii=False)

        lang = _resolve_language(spec, overrides.get("language", language))
        threads = int(overrides.get("num_threads", _active_config["num_threads"]))
        use_itn = bool(overrides.get("use_itn", _active_config["use_itn"]))
        # Decode every chunk by default: throttling past the first chunk would
        # make TTFT/flicker look better than the engine really is, which is
        # exactly what a latency benchmark must not do.
        stride = int(overrides.get("whisper_decode_stride", 1))
        if stride < 1:
            return json.dumps({"ok": False, "error": "whisper_decode_stride must be >= 1"})

        try:
            chunks_raw = json.loads(arrival_timeline_json)
        except Exception as exc:
            return json.dumps({"ok": False, "error": f"Invalid arrival_timeline_json: {exc}"})
        if isinstance(chunks_raw, dict) and "events" in chunks_raw:
            chunks_raw = chunks_raw["events"]
        if not isinstance(chunks_raw, list) or not chunks_raw:
            return json.dumps({"ok": False, "error": "arrival_timeline_json must be a non-empty array"})

        data, sr, duration_s = _load_samples(audio_path)
        total_audio_ms = duration_s * 1000.0
        total_samples = len(data)

        task = str(overrides.get("task", "transcribe"))
        backend, load_ms = _get_backend(spec, lang, threads, use_itn, task)

        received: List[float] = []
        current_partial_text = ""
        chunk_events: List[Dict[str, Any]] = []

        valid_indices = [i for i, c in enumerate(chunks_raw) if not c.get("dropped", False)]
        last_valid_idx = valid_indices[-1] if valid_indices else -1

        for idx, event in enumerate(chunks_raw):
            seq = event.get("seq", idx)
            sent_ms = float(event.get("audio_sent_ms", event.get("sent_ms", 0.0)))
            dropped = bool(event.get("dropped", False))
            size_bytes = event.get("size_bytes", 0)

            # A raw `chunk_manifest` carries no arrival time at all — it
            # describes what was *sent*. Only an impairment timeline (from
            # simulate_network_impairment) models delivery, and that one marks
            # a lost packet with an explicit null. Absent key => delivered.
            has_recv = "audio_recv_ms" in event or "recv_ms" in event
            recv_ms = event.get("audio_recv_ms", event.get("recv_ms"))
            if not has_recv:
                recv_ms = sent_ms
            elif recv_ms is None and not dropped:
                dropped = True

            if dropped or recv_ms is None:
                chunk_events.append({
                    "seq": seq, "audio_sent_ms": sent_ms, "audio_recv_ms": None,
                    "text_recv_ms": None, "text": current_partial_text,
                    "is_final": False, "dropped": True, "size_bytes": size_bytes,
                })
                continue

            start_ms, end_ms = _chunk_span_ms(event, idx, len(chunks_raw), total_audio_ms)
            start_sample = max(0, min(total_samples, int(start_ms / 1000.0 * sr)))
            end_sample = max(start_sample, min(total_samples, int(end_ms / 1000.0 * sr)))
            if end_sample > start_sample:
                received.extend(data[start_sample:end_sample])

            t0 = time.perf_counter()
            should_decode = len(received) > 1600 and (   # >= 100 ms buffered
                spec.kind != "whisper-ggml"
                or idx == last_valid_idx
                or stride == 1
                or idx % stride == 0
            )
            if should_decode:
                current_partial_text = backend.transcribe(received, sr).strip()
            infer_duration_ms = (time.perf_counter() - t0) * 1000.0

            chunk_events.append({
                "seq": seq,
                "audio_sent_ms": sent_ms,
                "audio_recv_ms": recv_ms,
                "text_recv_ms": round(recv_ms + max(25.0, infer_duration_ms), 2),
                "text": current_partial_text,
                "is_final": idx == last_valid_idx,
                "dropped": False,
                "size_bytes": size_bytes,
            })

        return json.dumps({
            "ok": True,
            "engine": spec.id,
            "language": lang or "auto",
            "hyp_asr": current_partial_text,
            "chunk_events": chunk_events,
            "total_chunks": len(chunks_raw),
            "dropped_chunks": sum(1 for e in chunk_events if e["dropped"]),
            "audio_duration_ms": round(total_audio_ms, 1),
            "load_ms": round(load_ms, 1),
        }, ensure_ascii=False, indent=2)
    except Exception as exc:
        logger.exception("stream_transcribe failed")
        return json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False)


@server.tool()
def benchmark_models(
    audio_paths_json: str,
    engines_json: str = "[]",
    language: str = "auto",
    references_json: str = "{}",
    num_threads: Optional[int] = None,
    task: str = "transcribe",
) -> str:
    """Measure latency and accuracy for several engines over several audio files.

    Runs a full cross-product of engines x files on real audio and returns one
    row per combination with load time, inference time, RTF, transcript and —
    when a reference transcript is supplied — character error rate. Engines that
    cannot run are reported in `skipped` with their blockers rather than failing
    the whole call.

    Args:
        audio_paths_json: JSON array of absolute WAV paths.
        engines_json: JSON array of engine ids; empty means every ready engine.
        language: Language hint applied to all files ('auto' to let each engine decide).
        references_json: JSON object mapping audio path -> ground-truth transcript.
        num_threads: Override the active thread count for this run.
        task: 'transcribe' (default) or 'translate' (whisper engines only;
            speech translation into English).
    """
    try:
        if task not in ("transcribe", "translate"):
            return json.dumps({"ok": False, "error": f"invalid task {task!r}"})
        paths = json.loads(audio_paths_json)
        if not isinstance(paths, list) or not paths:
            return json.dumps({"ok": False, "error": "audio_paths_json must be a non-empty array"})
        requested = json.loads(engines_json) if engines_json else []
        if not isinstance(requested, list):
            return json.dumps({"ok": False, "error": "engines_json must be an array"})
        references = json.loads(references_json) if references_json else {}
        if not isinstance(references, dict):
            return json.dumps({"ok": False, "error": "references_json must be an object"})

        threads = int(num_threads or _active_config["num_threads"])
        specs = [_engine_spec(e) for e in requested] if requested else list(ENGINES.values())

        rows: List[Dict[str, Any]] = []
        skipped: List[Dict[str, Any]] = []

        for spec in specs:
            if not spec.ready:
                skipped.append({"engine": spec.id, "reason": "; ".join(spec.blockers())})
                continue
            try:
                lang = _resolve_language(spec, language)
            except ValueError as exc:
                skipped.append({"engine": spec.id, "reason": str(exc)})
                continue
            if task == "translate" and spec.kind != "whisper-ggml":
                skipped.append({
                    "engine": spec.id,
                    "reason": "cannot translate (whisper engines only)",
                })
                continue

            for path in paths:
                try:
                    samples, sr, duration_s = _load_samples(path)
                    result = _infer(spec, lang, threads, _active_config["use_itn"],
                                    samples, sr, task)
                    row: Dict[str, Any] = {
                        "engine": spec.id,
                        "file": Path(path).name,
                        "task": task,
                        "language": lang or "auto",
                        "duration_s": round(duration_s, 2),
                        "load_ms": result["load_ms"],
                        "infer_ms": result["infer_ms"],
                        "rtf": round(result["infer_ms"] / 1000.0 / max(0.001, duration_s), 3),
                        "text": result["text"],
                    }
                    reference = references.get(path)
                    if reference:
                        row["cer"] = _char_error_rate(reference, result["text"])
                    rows.append(row)
                except Exception as exc:
                    rows.append({"engine": spec.id, "file": Path(path).name,
                                 "error": str(exc)})

        summary = {}
        for row in rows:
            if "rtf" in row:
                summary.setdefault(row["engine"], []).append(row["rtf"])
        return json.dumps({
            "ok": True,
            "rows": rows,
            "skipped": skipped,
            "mean_rtf": {k: round(sum(v) / len(v), 3) for k, v in summary.items()},
        }, ensure_ascii=False, indent=2)
    except Exception as exc:
        logger.exception("benchmark_models failed")
        return json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False)


def main() -> None:
    logger.info("Starting sonic-asr MCP server over stdio...")
    server.run(transport="stdio")


if __name__ == "__main__":
    main()
