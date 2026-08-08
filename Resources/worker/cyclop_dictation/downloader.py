"""Fetching model weights with something to show for the wait.

`mlx_whisper` downloads the model on its own the first time it transcribes,
silently and with no way to report how far along it is. So Cyclop downloads
first, by hand: `snapshot_download` accepts a `tqdm_class`, and a class that
reports instead of drawing turns the wait into numbers the panel can show.

The total comes from a dry run rather than from the progress bars, which only
learn a file's size when that file starts: without it the denominator would
grow as the download went on, and a bar that jumps backwards reads as broken.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Progress:
    downloaded_mb: float
    total_mb: float

    @property
    def fraction(self) -> float:
        if self.total_mb <= 0:
            return 0.0
        return min(1.0, self.downloaded_mb / self.total_mb)


class Aggregator:
    """One number out of however many progress bars the library opens.

    `snapshot_download` keeps two of them running to the full size at once —
    bytes off the network and bytes written to disk — so adding them up
    reports twice the download and fills the bar at the halfway point. The
    largest bar is the honest answer: with the two moving together it is the
    real figure, and it stays sane whatever the library does next.
    """

    def __init__(self, total_mb: float, step_mb: float = 0.0):
        self._total_mb = total_mb
        # A line per network buffer would be thousands of them, finer than
        # anything the panel can draw. Capped at a megabyte for the opposite
        # reason: Swift watches these lines to tell a live download from a
        # dead one, and a tenth of a percent of three gigabytes is three
        # megabytes — on a slow connection that is minutes of silence, long
        # enough for the watchdog to kill a download that was working.
        self._step_mb = step_mb if step_mb > 0 else min(max(total_mb / 1000, 0.1), 1.0)
        self._bars: dict[object, float] = {}
        self._reported = -1.0

    def note(self, bar: object, downloaded_mb: float) -> Progress | None:
        """Record one bar's position. Returns Progress worth sending, or None."""
        self._bars[bar] = downloaded_mb
        done = min(max(self._bars.values()), self._total_mb) if self._total_mb > 0 else max(self._bars.values())
        if done - self._reported < self._step_mb:
            return None
        self._reported = done
        return Progress(downloaded_mb=round(done, 1), total_mb=round(self._total_mb, 1))

    def finished(self) -> Progress:
        """Where the bars stop is never quite the end; the caller shows this."""
        return Progress(downloaded_mb=round(self._total_mb, 1), total_mb=round(self._total_mb, 1))


def is_ready(repo: str) -> bool:
    """True when the weights are already on disk. Never touches the network."""
    try:
        from huggingface_hub import snapshot_download

        snapshot_download(repo, local_files_only=True)
        return True
    except Exception:
        # LocalEntryNotFoundError normally, but a half-written cache entry can
        # raise other things too, and every one of them means the same: we
        # cannot rely on this model being here.
        return False


def remove(repo: str) -> float:
    """Delete the weights from the Hugging Face cache. Returns freed megabytes.

    Through `scan_cache_dir` rather than `rm -rf` on a path we assembled
    ourselves: the cache has its own layout of blobs, refs and snapshots, with
    files shared between revisions, and deleting a directory out from under it
    is how a cache stops being readable rather than becoming empty.
    """
    from huggingface_hub import scan_cache_dir

    cache = scan_cache_dir()
    for entry in cache.repos:
        if entry.repo_id != repo:
            continue
        strategy = cache.delete_revisions(*[r.commit_hash for r in entry.revisions])
        freed = strategy.expected_freed_size / 2**20
        strategy.execute()
        return round(freed, 1)
    return 0.0


def download(repo: str, on_progress=None) -> str:
    """Fetch the weights, reporting Progress as they arrive. Returns the path."""
    from huggingface_hub import snapshot_download
    from tqdm.auto import tqdm

    class Quiet(tqdm):
        """A bar that never draws — stdout is the protocol, stderr is the log."""

        def display(self, *args, **kwargs):
            return False

    aggregator = Aggregator(_expected_mb(repo, Quiet))

    class Reporter(Quiet):
        def update(self, n=1):
            super().update(n)
            self._report()

        def close(self):
            super().close()
            self._report()

        def _report(self):
            # Only the byte bars: `snapshot_download` also opens one counting
            # files, and adding files to bytes would be nonsense.
            if on_progress is None or self.unit != "B":
                return
            progress = aggregator.note(self, self.n / 2**20)
            if progress is not None:
                on_progress(progress)

    path = snapshot_download(repo, tqdm_class=Reporter)
    if on_progress is not None:
        on_progress(aggregator.finished())
    return path


def _expected_mb(repo: str, tqdm_class) -> float:
    """How much is left to fetch, in megabytes, before fetching any of it."""
    try:
        from huggingface_hub import snapshot_download

        files = snapshot_download(repo, dry_run=True, tqdm_class=tqdm_class)
        return sum(f.file_size for f in files if not f.is_cached) / 2**20
    except Exception:
        # Offline, or an API that stopped answering this question. The download
        # itself still works; the panel just shows an indeterminate wait.
        return 0.0
