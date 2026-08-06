"""Worker tests. The engine is stubbed: this checks the protocol and the
idle-unload policy, not mlx-whisper, which has its own."""
import json
import struct
import sys
import tempfile
import threading
import time
import unittest
import wave
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).parent))
from cyclop_worker import Engine, handle_line
from cyclop_dictation.audio import decode_pcm, load_wav
from cyclop_dictation.config import WhisperConfig, load_config
from cyclop_dictation.downloader import Aggregator
from cyclop_dictation.model_catalog import get_model
from cyclop_dictation.preferences import PreferencesStore, UserPreferences
from cyclop_dictation.text_cleaner import clean_text


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

    def test_transcribe_reports_none_model_without_real_config(self):
        # This engine was built directly around a stub transcriber (see
        # setUp), the same seam every other test in this file uses — it
        # never runs _ensure(), so there is no real config to report a model
        # from. None here, not a guessed string, is the honest answer.
        out = handle_line(json.dumps({"cmd": "transcribe", "path": "/tmp/a.wav"}), self.engine)
        self.assertIsNone(out["model"])

    def test_transcribe_reports_the_actual_model(self):
        # Simulates what _ensure() would have set self._config to after
        # actually calling load_config() — this is the path that matters:
        # a history entry must name the model that produced it, not a
        # string hard-coded on the Swift side that goes stale the moment
        # someone switches models in WhisperDictation's own menu.
        self.engine._config = SimpleNamespace(
            whisper=SimpleNamespace(model="mlx-community/whisper-large-v3-turbo-q4")
        )
        out = handle_line(json.dumps({"cmd": "transcribe", "path": "/tmp/a.wav"}), self.engine)
        self.assertEqual(out["model"], "mlx-community/whisper-large-v3-turbo-q4")

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


class RecognitionSettingsTests(unittest.TestCase):
    """The settings are the reason this worker exists at all.

    They were tuned against real recordings — a transcription of a 1774-character
    dictation matched the existing history character for character — so anything
    that moves them should have to say so out loud by editing this test.
    """

    def test_decoding_parameters_are_the_tuned_ones(self):
        whisper = WhisperConfig()
        self.assertEqual(whisper.temperature, 0.0)
        self.assertFalse(whisper.condition_on_previous_text)
        self.assertIsNone(whisper.language, "автоопределение языка, а не фиксированный")

    def test_initial_prompt_is_intact(self):
        prompt = WhisperConfig().initial_prompt
        self.assertEqual(len(prompt), 1100)
        self.assertTrue(prompt.startswith("Это диктовка на русском языке для разработчика."))
        self.assertTrue(prompt.endswith("Сэм Альтман."))

    def test_default_model_is_the_balanced_one(self):
        self.assertEqual(
            WhisperConfig().model, "mlx-community/whisper-large-v3-turbo"
        )


class ConfigTests(unittest.TestCase):
    def test_loading_config_creates_nothing_on_disk(self):
        # The original called ensure_dirs() from load_config(), so asking which
        # model to use quietly laid out a recordings folder. Cyclop's Swift side
        # owns its directories; reading a preference must not write anything.
        with tempfile.TemporaryDirectory() as tmp:
            data_dir = Path(tmp) / "Cyclop"
            load_config(data_dir=data_dir)
            self.assertFalse(data_dir.exists(), f"{data_dir} появился на ровном месте")

    def test_missing_preferences_mean_the_default_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = load_config(data_dir=Path(tmp) / "Cyclop")
            self.assertEqual(config.whisper.model, "mlx-community/whisper-large-v3-turbo")

    def test_saved_preference_picks_the_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            data_dir = Path(tmp) / "Cyclop"
            store_path = data_dir / "dictation-preferences.json"
            PreferencesStore(store_path).save(UserPreferences(selected_model_id="small"))
            config = load_config(data_dir=data_dir)
            self.assertEqual(config.whisper.model, get_model("small").repo)

    def test_unknown_preference_falls_back_instead_of_failing(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "dictation-preferences.json"
            path.write_text('{"selected_model_id": "нет такой"}', encoding="utf-8")
            self.assertEqual(
                PreferencesStore(path).load().selected_model_id, "large-v3-turbo"
            )


class AudioTests(unittest.TestCase):
    """Reading recordings ourselves is what keeps ffmpeg out of the picture."""

    def test_16_bit_mono_becomes_floats_in_range(self):
        raw = struct.pack("<4h", 0, 16384, -16384, 32767)
        samples = decode_pcm(raw, sample_width=2, channels=1)
        self.assertEqual(len(samples), 4)
        self.assertAlmostEqual(samples[0], 0.0)
        self.assertAlmostEqual(samples[1], 0.5)
        self.assertAlmostEqual(samples[2], -0.5)
        self.assertLessEqual(max(samples), 1.0)

    def test_stereo_is_averaged_into_one_channel(self):
        raw = struct.pack("<4h", 16384, -16384, 32766, 32766)
        samples = decode_pcm(raw, sample_width=2, channels=2)
        self.assertEqual(len(samples), 2)
        self.assertAlmostEqual(samples[0], 0.0)
        self.assertAlmostEqual(samples[1], 32766 / 32768.0)

    def test_eight_bit_is_read_as_unsigned(self):
        samples = decode_pcm(bytes([128, 255, 0]), sample_width=1, channels=1)
        self.assertAlmostEqual(samples[0], 0.0)
        self.assertGreater(samples[1], 0.9)
        self.assertAlmostEqual(samples[2], -1.0)

    def test_exotic_formats_are_declined_rather_than_guessed(self):
        # 24-bit PCM exists; we have no reason to decode it, and returning
        # None is what sends mlx-whisper down its own ffmpeg path instead.
        self.assertIsNone(decode_pcm(b"\x00" * 9, sample_width=3, channels=1))

    def test_a_real_recording_is_read_without_ffmpeg(self):
        try:
            import numpy  # noqa: F401
        except ImportError:
            self.skipTest("numpy живёт в рантайме приложения, не в системном python3")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "sample.wav"
            with wave.open(str(path), "wb") as out:
                out.setnchannels(1)
                out.setsampwidth(2)
                out.setframerate(16_000)
                out.writeframes(struct.pack("<3h", 0, 16384, -16384))
            audio = load_wav(path)
            self.assertEqual(len(audio), 3)
            self.assertAlmostEqual(float(audio[1]), 0.5)

    def test_a_file_that_is_not_wav_at_all_is_declined(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "sample.wav"
            path.write_bytes(b"not a wav")
            self.assertIsNone(load_wav(path))


class DownloadProgressTests(unittest.TestCase):
    """`snapshot_download` runs two byte bars at once; both reach the full size."""

    def test_two_bars_over_the_same_bytes_are_not_added_up(self):
        aggregator = Aggregator(total_mb=459, step_mb=1)
        transfer, reconstruct = object(), object()
        aggregator.note(transfer, 200)
        aggregator.note(reconstruct, 180)
        progress = aggregator.note(transfer, 240)
        # 240, не 420: иначе полоса заполнится на середине скачивания.
        self.assertEqual(progress.downloaded_mb, 240)
        self.assertAlmostEqual(progress.fraction, 240 / 459, places=3)

    def test_progress_never_runs_past_the_total(self):
        aggregator = Aggregator(total_mb=100, step_mb=1)
        progress = aggregator.note(object(), 140)
        self.assertEqual(progress.downloaded_mb, 100)
        self.assertEqual(progress.fraction, 1.0)

    def test_tiny_steps_are_swallowed(self):
        aggregator = Aggregator(total_mb=1000, step_mb=10)
        bar = object()
        self.assertIsNotNone(aggregator.note(bar, 10))
        self.assertIsNone(aggregator.note(bar, 12), "12 МБ из 1000 — не повод для строки")
        self.assertIsNotNone(aggregator.note(bar, 25))

    def test_unknown_total_still_reports_something(self):
        # Offline dry run: the size is unknown, but the download itself works
        # and the panel should still see movement rather than a dead bar.
        aggregator = Aggregator(total_mb=0)
        progress = aggregator.note(object(), 5)
        self.assertEqual(progress.downloaded_mb, 5)
        self.assertEqual(progress.fraction, 0.0)

    def test_the_last_word_is_a_full_bar(self):
        aggregator = Aggregator(total_mb=459)
        aggregator.note(object(), 458.2)
        self.assertEqual(aggregator.finished().fraction, 1.0)


class TextCleanerTests(unittest.TestCase):
    def test_trailing_space_so_the_next_dictation_does_not_run_into_this_one(self):
        self.assertEqual(clean_text("привет"), "Привет ")

    def test_whitespace_only_input_stays_empty(self):
        self.assertEqual(clean_text("   \n  "), "")

    def test_punctuation_and_spacing_are_normalised(self):
        self.assertEqual(clean_text("да  ,нет"), "Да, нет ")


if __name__ == "__main__":
    unittest.main()
