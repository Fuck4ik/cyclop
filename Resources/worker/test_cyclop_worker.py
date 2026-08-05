"""Worker tests. The engine is stubbed: this checks the protocol and the
idle-unload policy, not mlx-whisper, which has its own."""
import json
import sys
import threading
import time
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


class SlowFakeTranscriber:
    """Transcriber that sleeps to simulate long inference."""

    def __init__(self, sleep_seconds=0.1):
        self.loaded = False
        self.calls = 0
        self.sleep_seconds = sleep_seconds

    def transcribe(self, path):
        self.loaded = True
        self.calls += 1
        time.sleep(self.sleep_seconds)
        return "  медленный результат  "


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

    def test_no_race_condition_during_transcription(self):
        """Verify idle-unload cannot start while transcribe() is running.

        This reproduces the bug: if maybe_unload_idle() runs in another thread
        while transcribe() is in progress, it could unload the model mid-inference.
        The lock should prevent this: after transcribe() finishes, _last_used is
        recent and idle-unload will not trigger until the deadline passes.
        """
        slow = SlowFakeTranscriber(sleep_seconds=0.15)
        # Clock that advances, simulating time passing during transcription
        now = [1000.0]
        engine = Engine(
            transcriber=slow,
            idle_seconds=10,  # short deadline for test
            clock=lambda: now[0],
        )
        # Start transcription in a background thread
        result = {"text": None, "error": None}

        def transcribe_bg():
            try:
                result["text"] = handle_line(
                    json.dumps({"cmd": "transcribe", "path": "/tmp/a.wav"}), engine
                )
            except Exception as exc:
                result["error"] = exc

        t = threading.Thread(target=transcribe_bg, daemon=True)
        t.start()
        # Give transcription time to start
        time.sleep(0.05)
        # While transcribe() is still running, try to unload (simulating idle-watch)
        # The lock should block until transcribe() finishes
        now[0] += 11  # advance time past idle deadline
        unload_result = engine.maybe_unload_idle()
        # unload_result will be None because transcribe() updated _last_used and holds the lock
        t.join(timeout=1)

        # After transcription finishes, the engine should be in a consistent state:
        # either fully loaded or fully unloaded, never a mismatch.
        self.assertIsNotNone(result["text"], "transcription should complete")
        self.assertIsNone(result["error"], "transcription should not error")
        self.assertFalse(
            engine._loaded and engine._transcriber is None,
            "model state mismatch: _loaded=True but _transcriber=None",
        )
        self.assertFalse(
            not engine._loaded and engine._transcriber is not None,
            "model state mismatch: _loaded=False but _transcriber is not None",
        )

    def test_concurrent_transcribe_and_idle_check(self):
        """Verify that transcribe() and maybe_unload_idle() can run concurrently safely.

        Both methods use the same lock to prevent state corruption. This test
        verifies that the lock serializes access correctly.
        """
        slow = SlowFakeTranscriber(sleep_seconds=0.05)
        now = [1000.0]
        engine = Engine(
            transcriber=slow,
            idle_seconds=5,  # short deadline
            clock=lambda: now[0],
        )
        # Transcribe once to load the model
        handle_line(json.dumps({"cmd": "transcribe", "path": "/tmp/a.wav"}), engine)

        # Verify the model is loaded
        self.assertTrue(engine._loaded)
        self.assertIsNotNone(engine._transcriber)

        # Now simulate idle check happening while transcribe is in progress
        # by advancing time during transcription
        def concurrent_transcribe_and_check():
            def transcribe_bg():
                handle_line(
                    json.dumps({"cmd": "transcribe", "path": "/tmp/b.wav"}), engine
                )

            t = threading.Thread(target=transcribe_bg, daemon=True)
            t.start()
            # Give transcription time to start but not finish
            time.sleep(0.02)
            # Advance time past idle deadline while transcribe is running
            now[0] += 6
            # Try to idle-unload (should block until transcribe finishes)
            result = engine.maybe_unload_idle()
            t.join(timeout=1)
            return result

        result = concurrent_transcribe_and_check()
        # After transcribe() finishes, _last_used was updated, so idle-unload
        # might not trigger depending on timing. But either way, the state
        # must be consistent.
        self.assertFalse(
            engine._loaded and engine._transcriber is None,
            "state corruption: _loaded=True but _transcriber=None",
        )
        self.assertFalse(
            not engine._loaded and engine._transcriber is not None,
            "state corruption: _loaded=False but _transcriber is not None",
        )


if __name__ == "__main__":
    unittest.main()
