import json
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path
from typing import cast

from scripts import bench_llama_file_read as bench


class BenchLlamaFileReadTests(unittest.TestCase):
    def test_collect_files_skips_ignored_dirs_and_binary_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "README.md").write_text("hello", encoding="utf-8")
            (root / "lua").mkdir()
            (root / "lua" / "plugin.lua").write_text("return {}", encoding="utf-8")
            (root / ".git").mkdir()
            (root / ".git" / "config").write_text("ignored", encoding="utf-8")
            (root / "image.bin").write_bytes(b"\x00\x01\x02")

            files = bench.collect_files(root, max_files=50, max_file_bytes=1000, max_total_bytes=10000)
            rels = [item.relative_path for item in files]

            self.assertEqual(["README.md", "lua/plugin.lua"], rels)

    def test_build_direct_prompt_includes_file_sections_and_stats(self):
        files = [
            bench.FilePayload(Path("/tmp/project/README.md"), "README.md", "NeoCode readme", False),
            bench.FilePayload(Path("/tmp/project/lua/init.lua"), "lua/init.lua", "return {}", False),
        ]

        prompt, stats = bench.build_direct_prompt(files, "Summarize this project")

        self.assertIn("Summarize this project", prompt)
        self.assertIn("## README.md", prompt)
        self.assertIn("NeoCode readme", prompt)
        self.assertEqual(2, stats["file_count"])
        self.assertEqual(len("NeoCode readme") + len("return {}"), stats["content_chars"])

    def test_collect_files_rejects_explicit_paths_outside_root(self):
        with tempfile.TemporaryDirectory() as root_tmp, tempfile.TemporaryDirectory() as outside_tmp:
            root = Path(root_tmp)
            outside = Path(outside_tmp) / "secret.txt"
            outside.write_text("secret", encoding="utf-8")

            files = bench.collect_files(root, explicit_files=[str(outside)])

            self.assertEqual([], files)

    @unittest.skipIf(not hasattr(Path, "symlink_to"), "symlinks unavailable")
    def test_collect_files_rejects_symlink_escape(self):
        with tempfile.TemporaryDirectory() as root_tmp, tempfile.TemporaryDirectory() as outside_tmp:
            root = Path(root_tmp)
            outside = Path(outside_tmp) / "secret.txt"
            outside.write_text("secret", encoding="utf-8")
            link = root / "linked.txt"
            try:
                link.symlink_to(outside)
            except OSError:
                self.skipTest("symlink creation is not allowed")

            files = bench.collect_files(root, explicit_files=["linked.txt"])

            self.assertEqual([], files)

    def test_collect_files_enforces_total_limit_by_utf8_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "unicode.txt").write_text("éééé", encoding="utf-8")

            files = bench.collect_files(root, max_total_bytes=3)

            self.assertLessEqual(len(files[0].content.encode("utf-8")), 3)
            self.assertTrue(files[0].truncated)

    def test_parse_sse_chunks_tracks_first_content_and_usage(self):
        lines = [
            b'data: {"choices":[{"delta":{"role":"assistant"}}]}\n',
            b'data: {"choices":[{"delta":{"content":"Hi"}}]}\n',
            b'data: {"choices":[{"delta":{"content":" there"}}]}\n',
            b'data: {"usage":{"prompt_tokens":10,"completion_tokens":2},"choices":[{"delta":{}}]}\n',
            b'data: [DONE]\n',
        ]

        parsed = bench.parse_sse_lines(lines)

        self.assertEqual("Hi there", parsed.text)
        self.assertEqual(2, parsed.content_chunks)
        self.assertEqual({"prompt_tokens": 10, "completion_tokens": 2}, parsed.usage)

    def test_parse_sse_chunks_merges_streamed_tool_call_fragments(self):
        lines = [
            b'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read_"}}]}}]}\n',
            b'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"text_file","arguments":"{\\\"path\\\":"}}]}}]}\n',
            b'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\\"README.md\\\"}"}}]}}]}\n',
            b'data: [DONE]\n',
        ]

        parsed = bench.parse_sse_lines(lines)
        tool_call = parsed.tool_calls[0]
        tool_function = cast(dict[str, str], tool_call["function"])

        self.assertEqual(1, len(parsed.tool_calls))
        self.assertEqual("read_text_file", tool_function["name"])
        self.assertEqual('{"path":"README.md"}', tool_function["arguments"])

    def test_parse_sse_chunks_tolerates_malformed_tool_index(self):
        lines = [
            b'data: {"choices":[{"delta":{"tool_calls":[{"index":"bad","function":{"name":"read_text_file"}}]}}]}\n',
            b'data: [DONE]\n',
        ]

        parsed = bench.parse_sse_lines(lines)

        self.assertEqual(1, len(parsed.tool_calls))

    def test_safe_tool_result_rejects_wrong_tool_name(self):
        files = [bench.FilePayload(Path("/tmp/project/README.md"), "README.md", "hello", False)]

        rel_path, result = bench.safe_tool_result(
            Path("/tmp/project"),
            files,
            {"function": {"name": "delete_file", "arguments": '{"path":"README.md"}'}},
        )

        self.assertEqual("", rel_path)
        self.assertIn("unsupported tool", result)

    def test_safe_tool_result_rejects_outside_root(self):
        with tempfile.TemporaryDirectory() as root_tmp, tempfile.TemporaryDirectory() as outside_tmp:
            root = Path(root_tmp)
            outside = Path(outside_tmp) / "secret.txt"
            outside.write_text("secret", encoding="utf-8")

            rel_path, result = bench.safe_tool_result(
                root,
                [],
                {"function": {"name": "read_text_file", "arguments": json.dumps({"path": str(outside)})}},
            )

            self.assertEqual(str(outside), rel_path)
            self.assertIn("outside benchmark root", result)

    def test_read_file_tool_schema_matches_openai_function_format(self):
        schema = bench.build_read_file_tool_schema()
        schema_function = cast(dict[str, object], schema["function"])
        parameters = cast(dict[str, object], schema_function["parameters"])
        properties = cast(dict[str, object], parameters["properties"])

        self.assertEqual("function", schema["type"])
        self.assertEqual("read_text_file", schema_function["name"])
        self.assertIn("path", properties)

    def test_main_dry_run_outputs_json_without_live_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "README.md").write_text("hello", encoding="utf-8")

            output = bench.main([
                "--root", str(root),
                "--file", "README.md",
                "--mode", "tool-loop",
                "--json",
            ])
            data = json.loads(output)

            self.assertFalse(data["live"])
            self.assertEqual("tool-loop", data["mode"])
            self.assertEqual(1, data["prompt"]["file_count"])
            self.assertIn("No request sent", data["note"])

    def test_dry_run_never_opens_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "README.md").write_text("hello", encoding="utf-8")

            with mock.patch("urllib.request.urlopen", side_effect=AssertionError("network called")):
                output = bench.main(["--root", str(root), "--file", "README.md", "--json"])

            self.assertFalse(json.loads(output)["live"])

    def test_live_direct_payload_shape_can_be_mocked(self):
        with mock.patch.object(bench, "detect_model", return_value="mock-model"), \
             mock.patch.object(bench, "post_chat_stream") as post:
            post.return_value = (
                bench.ParsedStream("ok", 1, {"prompt_tokens": 3, "completion_tokens": 1}, []),
                {"elapsed_s": 2.0, "first_content_s": 1.0},
            )

            result = bench.run_live_direct(
                bench.build_parser().parse_args(["--live"]),
                "prompt text",
                {"file_count": 1, "content_chars": 4, "truncated_files": 0, "prompt_chars": 11},
            )

            payload = post.call_args.args[1]
            self.assertEqual("mock-model", payload["model"])
            self.assertNotIn("tools", payload)
            self.assertEqual("direct", result["mode"])

    def test_live_tool_loop_reports_actual_round_stats(self):
        with mock.patch.object(bench, "detect_model", return_value="mock-model"), \
             mock.patch.object(bench, "post_chat_stream") as post:
            post.side_effect = [
                (
                    bench.ParsedStream("", 0, {"prompt_tokens": 5}, [
                        {"id": "call_1", "function": {"name": "read_text_file", "arguments": '{"path":"README.md"}'}}
                    ]),
                    {"elapsed_s": 1.0, "first_content_s": 1.0},
                ),
                (
                    bench.ParsedStream("summary", 1, {"prompt_tokens": 8, "completion_tokens": 2}, []),
                    {"elapsed_s": 2.0, "first_content_s": 0.5},
                ),
            ]

            result = bench.run_live_tool_loop(
                bench.build_parser().parse_args(["--root", "/tmp/project", "--live", "--mode", "tool-loop"]),
                [bench.FilePayload(Path("/tmp/project/README.md"), "README.md", "hello", False)],
                {"file_count": 1, "content_chars": 5, "truncated_files": 0, "prompt_chars": 100},
            )

            self.assertEqual("tool-loop", result["mode"])
            round1 = cast(dict[str, object], result["round1"])
            tool = cast(dict[str, object], result["tool"])
            round2 = cast(dict[str, object], result["round2"])
            self.assertIn("round1_prompt_chars", round1)
            self.assertEqual(5, tool["result_chars"])
            self.assertIn("round2_message_chars", round2)

    def test_cli_prints_dry_run_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "README.md").write_text("hello", encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    "scripts/bench_llama_file_read.py",
                    "--root",
                    str(root),
                    "--file",
                    "README.md",
                    "--json",
                ],
                cwd=Path(__file__).resolve().parents[1],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(0, result.returncode)
            self.assertNotEqual("", result.stdout.strip())
            self.assertFalse(json.loads(result.stdout)["live"])


if __name__ == "__main__":
    unittest.main()
