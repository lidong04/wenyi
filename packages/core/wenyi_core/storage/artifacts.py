"""File implementation of the backend-neutral JSON artifact port.

Keys are relative to a run; Review and subtitle services never open state paths.
"""

from __future__ import annotations

import json
import os
import traceback
from pathlib import Path
from threading import RLock
from typing import Any


def _plain_path(value: Path) -> Path:
    """去掉 Windows 长路径前缀（``\\\\?\\`` 或 ``\\\\?\\UNC\\``），仅用于路径比较。

    ``Path.resolve()`` 在某些系统上对尚不存在的路径会返回 ``\\\\?\\C:\\...`` 形式，
    而根目录仍是 ``C:\\...``；此时 ``is_relative_to`` 会误判成"跑出运行目录"。
    """
    text = str(value)
    if text.startswith("\\\\?\\UNC\\"):
        return Path("\\\\" + text[8:])
    if text.startswith("\\\\?\\"):
        return Path(text[4:])
    return value


class FileArtifacts:
    def __init__(self, run_dir: str):
        self._artifact_root = os.path.abspath(run_dir)
        self._artifact_lock = RLock()

    def _artifact_path(self, key: str) -> Path:
        root = Path(self._artifact_root).resolve()
        path = Path(self._artifact_root, key).resolve()
        if not path.is_relative_to(root) and not _plain_path(path).is_relative_to(
            _plain_path(root)
        ):
            self._record_escape(key, root, path)
            raise ValueError(
                "Artifact key must remain within the run: "
                f"key={key!r} root={str(root)!r} resolved={str(path)!r}"
            )
        return path

    @staticmethod
    def _record_escape(key: str, root: Path, path: Path) -> None:
        """Append escape diagnostics when WENYI_ARTIFACT_DEBUG names a log file.

        The guard itself must never change behaviour, so failures here are ignored.
        """
        log_path = os.environ.get("WENYI_ARTIFACT_DEBUG", "").strip()
        if not log_path:
            return
        record = {
            "key": key,
            "root": str(root),
            "resolved": str(path),
            "cwd": os.getcwd(),
            "stack": traceback.format_stack()[-8:],
        }
        try:
            with open(log_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        except OSError:
            pass

    def read_artifact(self, key: str) -> Any | None:
        try:
            return json.loads(self._artifact_path(key).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None

    def write_artifact(self, key: str, value: Any) -> None:
        path = self._artifact_path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        with self._artifact_lock:
            tmp = path.with_name(path.name + ".tmp")
            tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
            os.replace(tmp, path)

    def delete_artifact(self, key: str) -> None:
        self._artifact_path(key).unlink(missing_ok=True)

    def list_artifacts(self, prefix: str = "") -> list[str]:
        base = _plain_path(Path(self._artifact_root).resolve())
        directory = self._artifact_path(prefix.rpartition("/")[0])
        if not directory.is_dir():
            return []
        keys = (
            _plain_path(path).relative_to(base).as_posix()
            for path in directory.rglob("*")
            if path.is_file()
        )
        return sorted(key for key in keys if key.startswith(prefix))

    def append_artifact_record(self, key: str, record: dict) -> None:
        path = self._artifact_path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        with self._artifact_lock, path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")

    def read_artifact_records(self, key: str) -> list[dict]:
        try:
            lines = self._artifact_path(key).read_text(encoding="utf-8").splitlines()
        except OSError:
            return []
        rows = []
        for line in lines:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(row, dict):
                rows.append(row)
        return rows
