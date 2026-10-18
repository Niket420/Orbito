"""Local task persistence (task-state records only, no conversation history)."""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path

from app.tasks.state import Task

log = logging.getLogger(__name__)

MAX_STORED_TASKS = 50


class TaskRepository:
    """Keeps tasks in memory and, when given a path, mirrors them to a JSON file.

    The file is written atomically with 0600 permissions because it contains
    the user's instructions.
    """

    def __init__(self, path: Path | None = None) -> None:
        self._path = path
        self._tasks: dict[str, Task] = {}
        if path and path.exists():
            self._load(path)

    def _load(self, path: Path) -> None:
        try:
            records = json.loads(path.read_text())
            for record in records:
                task = Task.model_validate(record)
                self._tasks[task.task_id] = task
        except (OSError, ValueError) as exc:
            log.warning("task_store_unreadable", extra={"error": type(exc).__name__})

    def all(self) -> list[Task]:
        return list(self._tasks.values())

    def get(self, task_id: str) -> Task | None:
        return self._tasks.get(task_id)

    def save(self, task: Task) -> None:
        self._tasks[task.task_id] = task
        if len(self._tasks) > MAX_STORED_TASKS:
            oldest = sorted(self._tasks.values(), key=lambda t: t.created_at)
            for stale in oldest[: len(self._tasks) - MAX_STORED_TASKS]:
                del self._tasks[stale.task_id]
        self._flush()

    def _flush(self) -> None:
        if not self._path:
            return
        self._path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self._path.with_suffix(".tmp")
        data = json.dumps([t.model_dump(mode="json") for t in self._tasks.values()])
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(data)
        os.replace(tmp, self._path)
