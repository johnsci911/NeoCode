#!/usr/bin/env python3
"""Benchmark local file-read prompts against llama.cpp without NeoCode.

Default mode is a safe dry run: it reads files, builds the request prompt, and
prints payload stats, but it does not contact llama-server unless --live is set.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


DEFAULT_PROMPT = "Read these project files and summarize what this project is about in 5 concise bullets."
IGNORED_DIRS = {
    ".git",
    ".hg",
    ".svn",
    ".cache",
    ".DS_Store",
    "node_modules",
    "vendor",
    "dist",
    "build",
    ".next",
    "__pycache__",
}
TEXT_EXTENSIONS = {
    "",
    ".c",
    ".cc",
    ".cfg",
    ".cmake",
    ".cpp",
    ".css",
    ".h",
    ".hpp",
    ".html",
    ".ini",
    ".js",
    ".json",
    ".lua",
    ".md",
    ".py",
    ".rs",
    ".sh",
    ".toml",
    ".ts",
    ".tsx",
    ".txt",
    ".vim",
    ".yaml",
    ".yml",
}


@dataclass(frozen=True)
class FilePayload:
    path: Path
    relative_path: str
    content: str
    truncated: bool


@dataclass(frozen=True)
class ParsedStream:
    text: str
    content_chunks: int
    usage: dict[str, object] | None
    tool_calls: list[dict[str, object]]


def _is_ignored(path: Path) -> bool:
    return any(part in IGNORED_DIRS for part in path.parts)


def _looks_binary(data: bytes) -> bool:
    return b"\x00" in data


def _is_text_candidate(path: Path) -> bool:
    if path.name in {"README", "Makefile", "Dockerfile", "LICENSE"}:
        return True
    return path.suffix.lower() in TEXT_EXTENSIONS


def _read_text(path: Path, max_file_bytes: int) -> tuple[str, bool] | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None

    if _looks_binary(data[:4096]):
        return None

    truncated = len(data) > max_file_bytes
    data = data[:max_file_bytes]
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        text = data.decode("utf-8", errors="replace")
    return text, truncated


def _inside_root(path: Path, root: Path) -> Path | None:
    try:
        resolved = path.expanduser().resolve()
        resolved.relative_to(root)
    except (OSError, ValueError):
        return None
    return resolved


def _truncate_utf8_bytes(text: str, max_bytes: int) -> tuple[str, bool]:
    data = text.encode("utf-8")
    if len(data) <= max_bytes:
        return text, False
    return data[:max_bytes].decode("utf-8", errors="ignore"), True


def collect_files(
    root: Path,
    *,
    explicit_files: Sequence[str] | None = None,
    includes: Sequence[str] | None = None,
    max_files: int = 200,
    max_file_bytes: int = 200_000,
    max_total_bytes: int = 1_000_000,
) -> list[FilePayload]:
    root = root.expanduser().resolve()
    includes = list(includes or ["*"])
    candidates: list[Path] = []

    if explicit_files:
        for raw in explicit_files:
            path = Path(raw).expanduser()
            if not path.is_absolute():
                path = root / path
            resolved = _inside_root(path, root)
            if resolved is not None:
                candidates.append(resolved)
    else:
        for path in sorted(root.rglob("*")):
            if len(candidates) >= max_files:
                break
            if not path.is_file() or _is_ignored(path.relative_to(root)):
                continue
            resolved = _inside_root(path, root)
            if resolved is None:
                continue
            rel = path.relative_to(root).as_posix()
            if not any(fnmatch.fnmatch(rel, pattern) for pattern in includes):
                continue
            if not _is_text_candidate(resolved):
                continue
            candidates.append(resolved)

    files: list[FilePayload] = []
    total = 0
    for path in candidates:
        if len(files) >= max_files or total >= max_total_bytes:
            break
        rel_path = path.relative_to(root)
        if not path.is_file() or _is_ignored(rel_path):
            continue
        read = _read_text(path, max_file_bytes)
        if not read:
            continue
        content, truncated = read
        remaining = max_total_bytes - total
        if len(content.encode("utf-8")) > remaining:
            content, total_truncated = _truncate_utf8_bytes(content, remaining)
            truncated = truncated or total_truncated
        total += len(content.encode("utf-8"))
        rel = rel_path.as_posix()
        files.append(FilePayload(path=path, relative_path=rel, content=content, truncated=truncated))

    return files


def build_read_file_tool_schema() -> dict[str, object]:
    return {
        "type": "function",
        "function": {
            "name": "read_text_file",
            "description": "Read one UTF-8 text file from the benchmark project by relative or absolute path.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path to the file, for example README.md or lua/neocode/session.lua.",
                    },
                },
                "required": ["path"],
            },
        },
    }


def build_direct_prompt(files: Sequence[FilePayload], task: str) -> tuple[str, dict[str, int]]:
    sections = [task, "", "Files:"]
    content_chars = 0
    truncated_count = 0

    for item in files:
        content_chars += len(item.content)
        if item.truncated:
            truncated_count += 1
        marker = " [truncated]" if item.truncated else ""
        sections.extend([
            "",
            f"## {item.relative_path}{marker}",
            "```",
            item.content,
            "```",
        ])

    stats = {
        "file_count": len(files),
        "content_chars": content_chars,
        "truncated_files": truncated_count,
        "prompt_chars": len("\n".join(sections)),
    }
    return "\n".join(sections), stats


def parse_sse_lines(lines: Iterable[bytes]) -> ParsedStream:
    text_parts: list[str] = []
    content_chunks = 0
    usage: dict[str, object] | None = None
    tool_calls_by_index: dict[int, dict[str, object]] = {}

    for raw in lines:
        line = raw.decode("utf-8", errors="replace").strip()
        if not line or not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if payload == "[DONE]":
            break
        try:
            chunk = json.loads(payload)
        except json.JSONDecodeError:
            continue
        if isinstance(chunk.get("usage"), dict):
            usage = chunk["usage"]
        choices = chunk.get("choices") or []
        if not choices:
            continue
        delta = choices[0].get("delta") or {}
        content = delta.get("content")
        if isinstance(content, str) and content:
            text_parts.append(content)
            content_chunks += 1
        if isinstance(delta.get("tool_calls"), list):
            for tc in delta["tool_calls"]:
                try:
                    index = int(tc.get("index", len(tool_calls_by_index)))
                except (TypeError, ValueError):
                    index = len(tool_calls_by_index)
                merged = tool_calls_by_index.setdefault(index, {
                    "id": tc.get("id") or f"call_{index}",
                    "type": tc.get("type") or "function",
                    "function": {"name": "", "arguments": ""},
                })
                if tc.get("id"):
                    merged["id"] = tc["id"]
                if tc.get("type"):
                    merged["type"] = tc["type"]
                fn = tc.get("function") or {}
                merged_fn = merged["function"]
                if isinstance(merged_fn, dict):
                    if fn.get("name"):
                        merged_fn["name"] = str(merged_fn.get("name", "")) + fn["name"]
                    if fn.get("arguments"):
                        merged_fn["arguments"] = str(merged_fn.get("arguments", "")) + fn["arguments"]

    tool_calls = [tool_calls_by_index[i] for i in sorted(tool_calls_by_index)]
    return ParsedStream("".join(text_parts), content_chunks, usage, tool_calls)


def detect_model(base_url: str) -> str | None:
    try:
        with urllib.request.urlopen(f"{base_url.rstrip('/')}/v1/models", timeout=5) as response:
            data = json.loads(response.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError):
        return None
    models = data.get("data") or []
    if models and isinstance(models[0], dict):
        return models[0].get("id")
    return None


def post_chat_stream(base_url: str, payload: dict[str, object]) -> tuple[ParsedStream, dict[str, float]]:
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    start = time.perf_counter()
    first_line_at: float | None = None
    lines: list[bytes] = []
    with urllib.request.urlopen(request, timeout=600) as response:
        for line in response:
            if first_line_at is None and line.strip():
                first_line_at = time.perf_counter()
            lines.append(line)
    end = time.perf_counter()
    parsed = parse_sse_lines(lines)
    timings = {
        "elapsed_s": end - start,
        "first_sse_line_s": (first_line_at - start) if first_line_at else end - start,
        "first_content_s": (first_line_at - start) if first_line_at else end - start,
    }
    return parsed, timings


def run_live_direct(args: argparse.Namespace, prompt: str, prompt_stats: dict[str, int]) -> dict[str, object]:
    model = args.model or detect_model(args.base_url) or "unknown"
    payload: dict[str, object] = {
        "model": model,
        "messages": [
            {"role": "system", "content": "You are benchmarking direct local file context. Answer concisely."},
            {"role": "user", "content": prompt},
        ],
        "stream": True,
        "stream_options": {"include_usage": True},
        "temperature": args.temperature,
        "max_tokens": args.max_tokens,
    }
    parsed, timings = post_chat_stream(args.base_url, payload)
    gen_s = max(timings["elapsed_s"] - timings["first_content_s"], 0.001)
    return {
        "live": True,
        "mode": "direct",
        "model": model,
        "prompt": prompt_stats,
        "timings": timings,
        "usage": parsed.usage,
        "output_chars": len(parsed.text),
        "content_chunks": parsed.content_chunks,
        "approx_chunks_per_s": parsed.content_chunks / gen_s,
        "preview": parsed.text[: args.preview_chars],
    }


def _safe_tool_file_result(root: Path, files: Sequence[FilePayload], arguments: str) -> tuple[str, str]:
    try:
        args = json.loads(arguments or "{}")
    except json.JSONDecodeError:
        return "", "Error: invalid JSON arguments"

    requested = str(args.get("path") or "")
    if not requested:
        return "", "Error: missing path"

    root = root.expanduser().resolve()
    path = Path(requested).expanduser()
    if not path.is_absolute():
        path = root / path
    try:
        resolved = path.resolve()
        resolved.relative_to(root)
    except (OSError, ValueError):
        return requested, "Error: path is outside benchmark root"

    by_path = {item.path.resolve(): item for item in files}
    item = by_path.get(resolved)
    if item is None:
        read = _read_text(resolved, 200_000)
        if not read:
            return requested, "Error: file is not readable text"
        content, truncated = read
        rel = resolved.relative_to(root).as_posix()
        item = FilePayload(resolved, rel, content, truncated)

    marker = "\n[truncated]" if item.truncated else ""
    return item.relative_path, item.content + marker


def safe_tool_result(root: Path, files: Sequence[FilePayload], tool_call: dict[str, object]) -> tuple[str, str]:
    fn = tool_call.get("function") if isinstance(tool_call, dict) else {}
    fn = fn if isinstance(fn, dict) else {}
    name = str(fn.get("name") or "")
    if name != "read_text_file":
        return "", f"Error: unsupported tool {name or '(missing)'}"
    return _safe_tool_file_result(root, files, str(fn.get("arguments") or "{}"))


def run_live_tool_loop(args: argparse.Namespace, files: Sequence[FilePayload], prompt_stats: dict[str, int]) -> dict[str, object]:
    model = args.model or detect_model(args.base_url) or "unknown"
    root = Path(args.root)
    file_list = "\n".join(f"- {item.relative_path}" for item in files[: args.max_files])
    round1_user_content = f"{args.prompt}\n\nAvailable benchmark files:\n{file_list}"
    messages: list[dict[str, object]] = [
        {
            "role": "system",
            "content": "You are benchmarking local tool calling. Use read_text_file when file contents are needed.",
        },
        {
            "role": "user",
            "content": round1_user_content,
        },
    ]

    base_payload: dict[str, object] = {
        "model": model,
        "stream": True,
        "stream_options": {"include_usage": True},
        "temperature": args.temperature,
        "max_tokens": args.max_tokens,
    }

    round1_payload = dict(base_payload)
    round1_payload["messages"] = messages
    round1_payload["tools"] = [build_read_file_tool_schema()]
    round1, round1_timings = post_chat_stream(args.base_url, round1_payload)

    result: dict[str, object] = {
        "live": True,
        "mode": "tool-loop",
        "model": model,
        "prompt": prompt_stats,
        "round1": {
            "timings": round1_timings,
            "usage": round1.usage,
            "tool_calls": len(round1.tool_calls),
            "output_chars": len(round1.text),
            "round1_prompt_chars": sum(len(str(m.get("content") or "")) for m in messages),
            "file_list_chars": len(file_list),
        },
    }
    if not round1.tool_calls:
        result["preview"] = round1.text[: args.preview_chars]
        result["note"] = "Model did not call read_text_file in round 1."
        return result

    tool_call = round1.tool_calls[0]
    fn = tool_call.get("function") if isinstance(tool_call, dict) else {}
    fn = fn if isinstance(fn, dict) else {}
    rel_path, tool_result = safe_tool_result(root, files, tool_call)
    messages.append({
        "role": "assistant",
        "content": round1.text or None,
        "tool_calls": [tool_call],
    })
    messages.append({
        "role": "tool",
        "tool_call_id": tool_call.get("id", "call_0"),
        "content": tool_result[:3000],
    })

    round2_payload = dict(base_payload)
    round2_payload["messages"] = messages
    round2, round2_timings = post_chat_stream(args.base_url, round2_payload)
    result["tool"] = {"name": fn.get("name"), "path": rel_path, "result_chars": len(tool_result)}
    result["round2"] = {
        "timings": round2_timings,
        "usage": round2.usage,
        "output_chars": len(round2.text),
        "content_chunks": round2.content_chunks,
        "round2_message_chars": sum(len(str(m.get("content") or "")) for m in messages),
    }
    result["preview"] = round2.text[: args.preview_chars]
    return result


def _json_or_text(result: dict[str, object], as_json: bool) -> str:
    if as_json:
        return json.dumps(result, indent=2, sort_keys=True)
    prompt = result.get("prompt")
    prompt_stats = prompt if isinstance(prompt, dict) else {}
    lines = [
        f"mode: {result.get('mode')}",
        f"live: {result.get('live')}",
        f"files: {prompt_stats.get('file_count')}",
        f"prompt chars: {prompt_stats.get('prompt_chars')}",
    ]
    if result.get("note"):
        lines.append(str(result["note"]))
    timings = result.get("timings")
    if isinstance(timings, dict):
        lines.append(f"first SSE line: {timings.get('first_sse_line_s', 0):.2f}s")
        lines.append(f"elapsed: {timings.get('elapsed_s', 0):.2f}s")
    if result.get("usage"):
        lines.append("usage: " + json.dumps(result["usage"], sort_keys=True))
    if result.get("preview"):
        lines.append("\n--- preview ---\n" + str(result["preview"]))
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="Project root to read from. Default: current directory")
    parser.add_argument("--file", action="append", dest="files", help="Specific file to include. Repeatable")
    parser.add_argument("--include", action="append", default=[], help="Glob for auto-collected files. Default: *")
    parser.add_argument("--max-files", type=int, default=200)
    parser.add_argument("--max-file-bytes", type=int, default=200_000)
    parser.add_argument("--max-total-bytes", type=int, default=1_000_000)
    parser.add_argument("--prompt", default=DEFAULT_PROMPT)
    parser.add_argument("--mode", choices=["direct", "tool-loop"], default="direct")
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    parser.add_argument("--model")
    parser.add_argument("--temperature", type=float, default=0.2)
    parser.add_argument("--max-tokens", type=int, default=512)
    parser.add_argument("--preview-chars", type=int, default=1000)
    parser.add_argument("--live", action="store_true", help="Actually send the prompt to llama-server")
    parser.add_argument("--json", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> str:
    parser = build_parser()
    args = parser.parse_args(argv)
    root = Path(args.root)

    read_start = time.perf_counter()
    files = collect_files(
        root,
        explicit_files=args.files,
        includes=args.include or None,
        max_files=args.max_files,
        max_file_bytes=args.max_file_bytes,
        max_total_bytes=args.max_total_bytes,
    )
    prompt, prompt_stats = build_direct_prompt(files, args.prompt)
    read_elapsed = time.perf_counter() - read_start
    prompt_stats["read_elapsed_ms"] = round(read_elapsed * 1000)

    if not args.live:
        result: dict[str, object] = {
            "live": False,
            "mode": args.mode,
            "prompt": prompt_stats,
            "base_url": args.base_url,
            "note": "No request sent. Re-run with --live to benchmark llama.cpp.",
        }
    elif args.mode == "direct":
        result = run_live_direct(args, prompt, prompt_stats)
    else:
        result = run_live_tool_loop(args, files, prompt_stats)

    output = _json_or_text(result, args.json)
    return output


if __name__ == "__main__":
    print(main(sys.argv[1:]))
