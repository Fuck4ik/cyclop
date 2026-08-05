"""Worker tests. The engine is stubbed: this checks the protocol and the
idle-unload policy, not mlx-whisper, which has its own."""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cyclop_worker import Engine, handle_line


class FakeTranscriber:
    def __init__(self):
        self.loaded = False
        self.calls = 0

    def transcribe(self, path):
        self.loaded = True
        self.calls += 1
        return "  распознанный текст  "


class WorkerProtocolTests(unittest.TestCase):
    def setUp(self):
        self.fake = FakeTranscriber()
        self.engine = Engine(transcriber=self.fake, idle_seconds=600, clock=lambda: self.now)
        self.now = 1000.0

    def test_transcribe_returns_cleaned_text(self):
        out = handle_line(json.dumps({"cmd": "transcribe", "path": "/tmp/a.wav"}), self.engine)
        self.assertEqual(out["text"], "распознанный текст")
        self.assertIn("took", out)

    def test_unknown_command_is_an_error_not_a_crash(self):
        out = handle_line(json.dumps({"cmd": "рисовать"}), self.engine)
        self.assertIn("error", out)

    def test_garbage_line_is_an_error_not_a_crash(self):
        out = handle_line("не json", self.engine)
        self.assertIn("error", out)

    def test_unload_reports_and_forgets_the_model(self):
        handle_line(json.dumps({"cmd": "transcribe", "path": "/tmp/a.wav"}), self.engine)
        out = handle_line(json.dumps({"cmd": "unload"}), self.engine)
        self.assertTrue(out["unloaded"])

    def test_idle_unload_only_after_the_deadline(self):
        handle_line(json.dumps({"cmd": "transcribe", "path": "/tmp/a.wav"}), self.engine)
        self.now += 599
        self.assertIsNone(self.engine.maybe_unload_idle())
        self.now += 2
        self.assertIsNotNone(self.engine.maybe_unload_idle())

    def test_idle_unload_does_not_repeat_while_still_idle(self):
        handle_line(json.dumps({"cmd": "transcribe", "path": "/tmp/a.wav"}), self.engine)
        self.now += 601
        self.assertIsNotNone(self.engine.maybe_unload_idle())
        self.now += 601
        self.assertIsNone(self.engine.maybe_unload_idle(), "выгружать нечего — модель уже выгружена")


if __name__ == "__main__":
    unittest.main()
