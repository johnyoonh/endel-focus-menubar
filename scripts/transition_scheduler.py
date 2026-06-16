#!/usr/bin/env python3
"""Plan TaskForge work blocks for travel transition windows."""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


METADATA_RE = re.compile(r"\[([A-Za-z0-9_-]+)::\s*([^\]]+)\]")
TASK_NOTES_RE = re.compile(r"\[\[(10_journal/TaskNotes/[^\]|]+)")
DUE_DATE_RE = re.compile(r"📅\s*(\d{4}-\d{2}-\d{2})")
DUE_TIME_RE = re.compile(r"⏰\s*(\d{1,2})(?::(\d{2}))?\s*(AM|PM)", re.I)
TAG_RE = re.compile(r"(?<!\w)#([A-Za-z0-9][A-Za-z0-9_/-]*)")


@dataclasses.dataclass(frozen=True)
class Task:
    title: str
    list_name: str
    file_path: Path
    line_number: int
    raw_line: str
    estimate_minutes: int
    metadata: dict[str, str]
    tags: tuple[str, ...]
    task_notes_path: Path | None
    task_notes_text: str

    @property
    def source_ref(self) -> str:
        return f"{self.file_path}:{self.line_number}"


@dataclasses.dataclass(frozen=True)
class Window:
    title: str
    start: dt.datetime
    end: dt.datetime
    kind: str
    connectivity: str
    context: str

    @property
    def minutes(self) -> int:
        return max(0, int((self.end - self.start).total_seconds() // 60))


def parse_datetime(value: str) -> dt.datetime:
    normalized = value.replace("Z", "+00:00")
    parsed = dt.datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        raise ValueError(f"datetime must include timezone offset: {value}")
    return parsed


def metadata_values(line: str) -> dict[str, str]:
    return {key.lower(): value.strip() for key, value in METADATA_RE.findall(line)}


def parse_due_time(line: str) -> str | None:
    match = DUE_TIME_RE.search(line)
    if not match:
        return None
    hour = int(match.group(1)) % 12
    minute = int(match.group(2) or "0")
    if match.group(3).upper() == "PM":
        hour += 12
    return f"{hour:02d}:{minute:02d}"


def parse_estimate(value: str | None) -> int:
    if not value:
        return 25
    match = re.search(r"(\d+)", value)
    if not match:
        return 25
    minutes = int(match.group(1))
    if "h" in value.lower() and "m" not in value.lower():
        minutes *= 60
    return min(240, max(5, minutes))


def clean_title(raw: str) -> str:
    title = re.sub(r"%%\[ticktick_id:: [^\]]+\]%%", "", raw)
    title = re.sub(r"%%[^%]+%%", "", title)
    title = re.sub(r"\[\[(?:10_journal/TaskNotes/[^\]|]+)(?:\|[^\]]+)?\]\]", "", title)
    title = re.sub(r"\[[A-Za-z0-9_-]+::\s*[^\]]+\]", "", title)
    title = re.sub(r"[📅⏳✅]\s*\d{4}-\d{2}-\d{2}", "", title)
    title = re.sub(r"⏰\s*\d{1,2}(?::\d{2})?\s*(?:AM|PM)", "", title, flags=re.I)
    title = re.sub(r"🎯\s*\d{1,2}(?::\d{2})?\s*(?:AM|PM)", "", title, flags=re.I)
    title = re.sub(r"#remind-at-scheduled\b", "", title)
    title = re.sub(r"(?<!\w)#[A-Za-z0-9][A-Za-z0-9_/-]*", "", title)
    title = re.sub(r"[🔺⏫🔼🔽⏬]", "", title)
    title = re.sub(r"^\[?\d{2}:\d{2}(?:\s*-\s*\d{2}:\d{2})?\]?\s*", "", title)
    title = re.sub(r"\s*-\d{1,2}:\d{2}\s*(?:AM|PM)\b", "", title, flags=re.I)
    title = re.sub(r"🛫\s*\d{4}-\d{2}-\d{2}", "", title)
    title = re.sub(r"⏱️?\s*\d{1,2}:\d{2}\s*(?:AM|PM)?\s*-\s*\d{1,2}:\d{2}\s*(?:AM|PM)?", "", title, flags=re.I)
    title = re.sub(r"⏱️?\s*\d{1,2}:\d{2}\s*(?:AM|PM)?", "", title, flags=re.I)
    return " ".join(title.split()).strip()


def task_notes_path(wiki_path: Path, line: str) -> Path | None:
    match = TASK_NOTES_RE.search(line)
    if not match:
        return None
    path = wiki_path / f"{match.group(1)}.md"
    return path


def load_task_notes(path: Path | None) -> str:
    if not path or not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")[:6000]


def load_open_tasks(wiki_path: Path) -> list[Task]:
    tasks_dir = wiki_path / "10_journal" / "TaskForge"
    if not tasks_dir.exists():
        return []
    tasks: list[Task] = []
    for file_path in sorted(tasks_dir.glob("*.md"), key=lambda p: p.name.lower()):
        for index, line in enumerate(file_path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1):
            if not line.startswith("- [ ] "):
                continue
            metadata = metadata_values(line)
            raw_title = line[6:]
            title = clean_title(raw_title)
            if not title:
                continue
            notes_path = task_notes_path(wiki_path, line)
            tags = tuple(f"#{tag}" for tag in TAG_RE.findall(line))
            tasks.append(
                Task(
                    title=title,
                    list_name=file_path.stem,
                    file_path=file_path,
                    line_number=index,
                    raw_line=line,
                    estimate_minutes=parse_estimate(metadata.get("estimate")),
                    metadata=metadata,
                    tags=tags,
                    task_notes_path=notes_path,
                    task_notes_text=load_task_notes(notes_path),
                )
            )
    return sorted(tasks, key=task_sort_key)


def task_sort_key(task: Task) -> tuple[int, str, str]:
    scheduled = task.metadata.get("scheduled") or "9999-12-31"
    due = DUE_DATE_RE.search(task.raw_line)
    due_date = due.group(1) if due else "9999-12-31"
    return (min_date_key(scheduled, due_date), task.list_name.lower(), task.title.lower())


def min_date_key(*dates: str) -> int:
    parsed: list[int] = []
    for value in dates:
        if re.match(r"^\d{4}-\d{2}-\d{2}$", value):
            parsed.append(int(value.replace("-", "")))
    return min(parsed) if parsed else 99991231


def load_windows(path: Path) -> list[Window]:
    data = json.loads(path.read_text(encoding="utf-8"))
    windows: list[Window] = []
    for item in data:
        windows.append(
            Window(
                title=str(item["title"]),
                start=parse_datetime(str(item["start"])),
                end=parse_datetime(str(item["end"])),
                kind=str(item.get("kind", "transition")).lower(),
                connectivity=str(item.get("connectivity", "unknown")).lower(),
                context=str(item.get("context", "")),
            )
        )
    return windows


def default_trip_windows() -> list[Window]:
    raw = [
        {
            "title": "Lyft: Home to DFW",
            "start": "2026-06-16T13:15:00-05:00",
            "end": "2026-06-16T14:15:00-05:00",
            "kind": "lyft",
            "connectivity": "phone",
            "context": "ride to airport; phone-friendly only",
        },
        {
            "title": "DFW airport buffer",
            "start": "2026-06-16T14:15:00-05:00",
            "end": "2026-06-16T15:45:00-05:00",
            "kind": "airport",
            "connectivity": "laptop",
            "context": "airport waiting time before boarding",
        },
        {
            "title": "AA 2810 in-flight Wi-Fi",
            "start": "2026-06-16T16:45:00-05:00",
            "end": "2026-06-16T17:35:00-07:00",
            "kind": "flight",
            "connectivity": "aa-wifi",
            "context": "American Airlines Wi-Fi; laptop possible; avoid calls",
        },
        {
            "title": "Lyft: SFO to Hotel des Arts",
            "start": "2026-06-16T18:45:00-07:00",
            "end": "2026-06-16T19:30:00-07:00",
            "kind": "lyft",
            "connectivity": "phone",
            "context": "ride to hotel; phone-friendly only",
        },
        {
            "title": "SFO return airport buffer",
            "start": "2026-06-17T21:15:00-07:00",
            "end": "2026-06-17T22:45:00-07:00",
            "kind": "airport",
            "connectivity": "laptop",
            "context": "airport waiting time before return flight",
        },
    ]
    tmp = Path(tempfile.mkstemp(suffix=".json")[1])
    try:
        tmp.write_text(json.dumps(raw), encoding="utf-8")
        return load_windows(tmp)
    finally:
        tmp.unlink(missing_ok=True)


def score_task(task: Task, window: Window) -> tuple[float, list[str]]:
    text = " ".join([task.title, task.list_name, " ".join(task.tags), task.task_notes_text]).lower()
    score = 0.45
    reasons: list[str] = []

    if task.estimate_minutes <= max(5, window.minutes - 5):
        score += 0.15
        reasons.append("fits the available window")
    else:
        score -= 0.35
        reasons.append("estimate exceeds the transition window")

    has_call_requirement = any(word in text for word in ("call", "phone call", "zoom", "meet", "recording", "interview"))
    call_is_negated = any(phrase in text for phrase in ("no call", "no calls", "without calls", "no meeting"))
    if has_call_requirement and not call_is_negated:
        score -= 0.35
        reasons.append("requires synchronous conversation")
    if any(
        word in text
        for word in (
            "password",
            "secret",
            "private",
            "bank",
            "tax",
            "medical",
            "credit card",
            "legal",
            "settlement",
            "cash",
            "finance",
            "runway",
            "insurance",
            "account",
            "cancel card",
            "crypto",
            "currency",
            "finance",
            "financial",
        )
    ):
        score -= 0.60
        reasons.append("appears sensitive for public travel work")

    if window.kind == "lyft":
        if task.estimate_minutes <= 20:
            score += 0.15
            reasons.append("short enough for a ride")
        if any(word in text for word in ("email", "reply", "read", "review", "triage", "outline", "notes")):
            score += 0.15
            reasons.append("phone-friendly work")
        if any(word in text for word in ("code", "build", "test", "xcode", "terminal", "computer")):
            score -= 0.30
            reasons.append("needs laptop or stable files")
    elif window.kind == "airport":
        if any(word in text for word in ("code", "write", "draft", "review", "plan", "test", "read")):
            score += 0.18
            reasons.append("good airport laptop task")
    elif window.kind == "flight":
        if window.connectivity in {"aa-wifi", "wifi"}:
            score += 0.10
            reasons.append("Wi-Fi is expected")
        if any(word in text for word in ("deep", "write", "draft", "code", "review", "plan", "design")):
            score += 0.28
            reasons.append("good uninterrupted flight task")
        if any(word in text for word in ("upload", "download", "video", "large file")):
            score -= 0.20
            reasons.append("may need stronger connectivity than in-flight Wi-Fi")

    if task.metadata.get("status", "").lower() == "in progress":
        score += 0.08
        reasons.append("already in progress")

    due = DUE_DATE_RE.search(task.raw_line)
    if due:
        due_date = dt.date.fromisoformat(due.group(1))
        if due_date <= window.start.date():
            score += 0.18
            reasons.append("due by the transition date")

    return max(0.0, min(1.0, score)), reasons


def proposal_id(task: Task, window: Window) -> str:
    seed = f"{task.source_ref}|{window.title}|{window.start.isoformat()}"
    return hashlib.sha1(seed.encode("utf-8")).hexdigest()[:12]


def build_proposals(tasks: list[Task], windows: list[Window], min_confidence: float) -> list[dict[str, Any]]:
    proposals: list[dict[str, Any]] = []
    used_sources: set[str] = set()
    for window in sorted(windows, key=lambda item: item.start):
        ranked: list[tuple[float, Task, list[str]]] = []
        for task in tasks:
            if task.source_ref in used_sources:
                continue
            confidence, reasons = score_task(task, window)
            ranked.append((confidence, task, reasons))
        ranked.sort(key=lambda item: (-item[0], item[1].estimate_minutes, item[1].title.lower()))
        if not ranked:
            continue
        confidence, task, reasons = ranked[0]
        if confidence < min_confidence:
            continue
        used_sources.add(task.source_ref)
        duration = min(task.estimate_minutes, max(5, window.minutes - 5))
        end = min(window.end, window.start + dt.timedelta(minutes=duration))
        marker = f"transition-scheduler:{proposal_id(task, window)}"
        proposals.append(
            {
                "id": proposal_id(task, window),
                "title": f"Transition work: {task.title}",
                "start": window.start.isoformat(),
                "end": end.isoformat(),
                "window_title": window.title,
                "window_kind": window.kind,
                "connectivity": window.connectivity,
                "confidence": round(confidence, 2),
                "reasons": reasons,
                "task": {
                    "title": task.title,
                    "list": task.list_name,
                    "file": str(task.file_path),
                    "line": task.line_number,
                    "estimate_minutes": task.estimate_minutes,
                    "task_notes": str(task.task_notes_path) if task.task_notes_path else None,
                },
                "dedupe_marker": marker,
                "description": (
                    f"TaskForge transition work block.\n"
                    f"Source: {task.source_ref}\n"
                    f"Window: {window.title}\n"
                    f"Connectivity: {window.connectivity}\n"
                    f"Confidence: {confidence:.2f}\n"
                    f"Marker: {marker}"
                ),
            }
        )
    return proposals


def ics_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace(";", r"\;").replace(",", r"\,").replace("\n", r"\n")


def format_ics_datetime(value: str) -> str:
    parsed = parse_datetime(value).astimezone(dt.timezone.utc)
    return parsed.strftime("%Y%m%dT%H%M%SZ")


def proposals_to_ics(proposals: list[dict[str, Any]]) -> str:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Endel Focus//Transition Scheduler//EN"]
    for proposal in proposals:
        lines.extend(
            [
                "BEGIN:VEVENT",
                f"UID:{proposal['dedupe_marker']}@endel-focus",
                f"DTSTAMP:{stamp}",
                f"DTSTART:{format_ics_datetime(proposal['start'])}",
                f"DTEND:{format_ics_datetime(proposal['end'])}",
                f"SUMMARY:{ics_escape(proposal['title'])}",
                f"DESCRIPTION:{ics_escape(proposal['description'])}",
                "CLASS:PRIVATE",
                "TRANSP:OPAQUE",
                "END:VEVENT",
            ]
        )
    lines.append("END:VCALENDAR")
    return "\r\n".join(lines) + "\r\n"


def existing_marker(calendar: str, proposal: dict[str, Any]) -> bool:
    marker = str(proposal["dedupe_marker"])
    start = parse_datetime(str(proposal["start"])) - dt.timedelta(days=1)
    end = parse_datetime(str(proposal["end"])) + dt.timedelta(days=1)
    result = subprocess.run(
        [
            "gcalcli",
            "search",
            marker,
            start.date().isoformat(),
            end.date().isoformat(),
            "--calendar",
            calendar,
            "--nocolor",
        ],
        check=False,
        text=True,
        capture_output=True,
    )
    return "No Events Found" not in result.stdout


def apply_proposals(calendar: str, proposals: list[dict[str, Any]]) -> list[dict[str, Any]]:
    fresh = [proposal for proposal in proposals if not existing_marker(calendar, proposal)]
    if not fresh:
        return []
    with tempfile.NamedTemporaryFile("w", suffix=".ics", delete=False, encoding="utf-8") as handle:
        handle.write(proposals_to_ics(fresh))
        path = handle.name
    try:
        subprocess.run(["gcalcli", "import", "--calendar", calendar, path], check=True)
    finally:
        Path(path).unlink(missing_ok=True)
    return fresh


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Plan TaskForge work blocks for transition windows.")
    parser.add_argument("--wiki-path", default=os.environ.get("TASKFORGE_WIKI_PATH", "~/Documents/wiki"))
    parser.add_argument("--windows-json", type=Path, help="JSON array of transition windows.")
    parser.add_argument("--calendar", default="Gmail")
    parser.add_argument("--min-confidence", type=float, default=0.75)
    parser.add_argument("--apply", action="store_true", help="Import high-confidence private blocks with gcalcli.")
    parser.add_argument("--output", choices=["json", "ics"], default="json")
    args = parser.parse_args(argv)

    wiki_path = Path(args.wiki_path).expanduser()
    windows = load_windows(args.windows_json) if args.windows_json else default_trip_windows()
    proposals = build_proposals(load_open_tasks(wiki_path), windows, args.min_confidence)

    if args.apply:
        applied = apply_proposals(args.calendar, proposals)
        print(json.dumps({"applied": applied, "skipped": len(proposals) - len(applied)}, indent=2))
        return 0
    if args.output == "ics":
        sys.stdout.write(proposals_to_ics(proposals))
    else:
        print(json.dumps({"proposals": proposals}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
