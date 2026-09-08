#!/usr/bin/env python3
"""Create and verify reproducible gzip-compressed tar archives.

The release scripts run on Windows, while the resulting archives are consumed
on Unix hosts.  Windows file metadata cannot express a Unix executable bit,
and the platform tar utility normally stamps the current time and local
owner.  This small stdlib-only helper writes every TarInfo field explicitly so
the toolkit and the cross-compiled CLI archives have stable bytes and usable
permissions on Linux/macOS.
"""

from __future__ import annotations

import argparse
import gzip
import io
import os
from pathlib import Path, PurePosixPath
import stat
import sys
import tarfile
import tempfile
from typing import Iterable, Iterator, Sequence


FIXED_MTIME = 0
FIXED_UID = 0
FIXED_GID = 0
FIXED_OWNER = "root"
DEFAULT_FILE_MODE = 0o644
EXECUTABLE_MODE = 0o755
DIRECTORY_MODE = 0o755
SYMLINK_MODE = 0o777
EXECUTABLE_SUFFIXES = frozenset(
    {".sh", ".py", ".pl", ".rb", ".ps1", ".cmd", ".bat"}
)


class ArchiveError(RuntimeError):
    """Raised for invalid input or a non-reproducible archive."""


def _normalise_archive_name(value: str, *, directory: bool = False) -> str:
    """Return a safe POSIX archive path and reject traversal/absolute paths."""

    candidate = value.replace("\\", "/")
    if not candidate or "\x00" in candidate:
        raise ArchiveError("archive name is empty or contains NUL")
    path = PurePosixPath(candidate)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise ArchiveError(f"unsafe archive path: {value!r}")
    normalised = "/".join(path.parts)
    if not normalised:
        raise ArchiveError(f"unsafe archive path: {value!r}")
    return normalised + ("/" if directory else "")


def _iter_source_entries(source: Path, root_name: str) -> Iterator[tuple[Path, str]]:
    """Yield source entries in deterministic lexical order, including root."""

    def walk(path: Path, archive_name: str) -> Iterator[tuple[Path, str]]:
        try:
            mode = path.lstat().st_mode
        except OSError as exc:  # pragma: no cover - platform error detail
            raise ArchiveError(f"cannot stat {path}: {exc}") from exc
        is_dir = stat.S_ISDIR(mode) and not stat.S_ISLNK(mode)
        safe_name = _normalise_archive_name(archive_name, directory=is_dir)
        yield path, safe_name
        if not is_dir:
            return
        try:
            children = sorted(path.iterdir(), key=lambda item: item.name)
        except OSError as exc:  # pragma: no cover - platform error detail
            raise ArchiveError(f"cannot enumerate {path}: {exc}") from exc
        for child in children:
            child_name = f"{archive_name.rstrip('/')}/{child.name}"
            yield from walk(child, child_name)

    yield from walk(source, root_name)


def _is_executable_name(archive_name: str) -> bool:
    suffix = PurePosixPath(archive_name.rstrip("/")).suffix.lower()
    return suffix in EXECUTABLE_SUFFIXES


def _set_common_metadata(info: tarfile.TarInfo, mode: int) -> tarfile.TarInfo:
    info.mtime = FIXED_MTIME
    info.uid = FIXED_UID
    info.gid = FIXED_GID
    info.uname = FIXED_OWNER
    info.gname = FIXED_OWNER
    info.mode = mode
    # Do not let tarfile add host-dependent PAX metadata (atime/ctime/etc.).
    info.pax_headers = {}
    return info


def _tar_info(path: Path, archive_name: str, force_executable: bool) -> tuple[tarfile.TarInfo, bytes | None]:
    """Build a fully specified TarInfo and optional file payload."""

    try:
        source_mode = path.lstat().st_mode
    except OSError as exc:  # pragma: no cover - platform error detail
        raise ArchiveError(f"cannot stat {path}: {exc}") from exc

    clean_name = archive_name.rstrip("/")
    if stat.S_ISDIR(source_mode) and not stat.S_ISLNK(source_mode):
        return _directory_info(clean_name), None

    if stat.S_ISLNK(source_mode):
        try:
            target = os.readlink(path)
        except OSError as exc:  # pragma: no cover - platform error detail
            raise ArchiveError(f"cannot read symlink {path}: {exc}") from exc
        info = _set_common_metadata(tarfile.TarInfo(clean_name), SYMLINK_MODE)
        info.type = tarfile.SYMTYPE
        info.linkname = target.replace("\\", "/")
        return info, None

    if stat.S_ISREG(source_mode):
        mode = EXECUTABLE_MODE if force_executable or _is_executable_name(clean_name) else DEFAULT_FILE_MODE
        info = _set_common_metadata(tarfile.TarInfo(clean_name), mode)
        info.type = tarfile.REGTYPE
        try:
            payload = path.read_bytes()
        except OSError as exc:  # pragma: no cover - platform error detail
            raise ArchiveError(f"cannot read {path}: {exc}") from exc
        info.size = len(payload)
        return info, payload

    raise ArchiveError(f"unsupported source entry type: {path}")


def _directory_info(clean_name: str) -> tarfile.TarInfo:
    info = _set_common_metadata(tarfile.TarInfo(clean_name + "/"), DIRECTORY_MODE)
    info.type = tarfile.DIRTYPE
    info.size = 0
    return info


def create_archive(source: Path, output: Path, root_name: str, force_executable: bool) -> None:
    if not source.exists() and not source.is_symlink():
        raise ArchiveError(f"source does not exist: {source}")
    root_name = _normalise_archive_name(root_name, directory=source.is_dir())
    output = output.absolute()
    output.parent.mkdir(parents=True, exist_ok=True)

    # Write beside the destination and replace it atomically after closing both
    # streams.  The temporary filename never enters the archive.
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{output.name}.", suffix=".tmp", dir=str(output.parent)
    )
    os.close(fd)
    temporary = Path(temporary_name)
    try:
        with temporary.open("wb") as raw:
            # Passing an explicit mtime prevents gzip from embedding wall-clock
            # time.  An empty filename avoids a host-specific gzip name field.
            with gzip.GzipFile(
                filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=FIXED_MTIME
            ) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                    for path, archive_name in _iter_source_entries(source, root_name.rstrip("/")):
                        info, payload = _tar_info(path, archive_name, force_executable)
                        archive.addfile(info, io.BytesIO(payload) if payload is not None else None)
        os.replace(temporary, output)
    except Exception:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def _member_expected_mode(member: tarfile.TarInfo, force_executable: bool) -> int | None:
    if member.isdir():
        return DIRECTORY_MODE
    if member.issym():
        return SYMLINK_MODE
    if member.isfile():
        if force_executable or _is_executable_name(member.name):
            return EXECUTABLE_MODE
        return DEFAULT_FILE_MODE
    return None


def verify_archive(
    archive_path: Path,
    root_name: str,
    force_executable: bool,
) -> Sequence[tarfile.TarInfo]:
    if not archive_path.is_file():
        raise ArchiveError(f"archive does not exist: {archive_path}")
    expected_root = _normalise_archive_name(root_name, directory=True).rstrip("/")
    try:
        with tarfile.open(archive_path, mode="r:gz") as archive:
            members = archive.getmembers()
    except (OSError, tarfile.TarError) as exc:
        raise ArchiveError(f"cannot read archive {archive_path}: {exc}") from exc
    if not members:
        raise ArchiveError("archive is empty")

    regular_count = 0
    for member in members:
        name = member.name.replace("\\", "/")
        clean = name.rstrip("/")
        _normalise_archive_name(name, directory=member.isdir())
        if clean != expected_root and not clean.startswith(expected_root + "/"):
            raise ArchiveError(f"archive entry is outside expected root {expected_root!r}: {name!r}")
        if member.mtime != FIXED_MTIME:
            raise ArchiveError(f"non-deterministic mtime for {name!r}: {member.mtime}")
        if member.uid != FIXED_UID or member.gid != FIXED_GID:
            raise ArchiveError(f"non-deterministic owner ids for {name!r}")
        if member.uname != FIXED_OWNER or member.gname != FIXED_OWNER:
            raise ArchiveError(f"non-deterministic owner names for {name!r}")
        expected_mode = _member_expected_mode(member, force_executable)
        if expected_mode is None:
            raise ArchiveError(f"unsupported tar entry type for {name!r}")
        if stat.S_IMODE(member.mode) != expected_mode:
            raise ArchiveError(
                f"unexpected mode for {name!r}: got {oct(stat.S_IMODE(member.mode))}, "
                f"want {oct(expected_mode)}"
            )
        if member.isfile():
            regular_count += 1
    if regular_count == 0:
        raise ArchiveError("archive contains no regular files")
    return members


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser("create", help="create a deterministic tar.gz")
    create.add_argument("--source", required=True, type=Path)
    create.add_argument("--output", required=True, type=Path)
    create.add_argument("--root-name", required=True)
    create.add_argument(
        "--all-files-executable",
        action="store_true",
        help="set every regular file to mode 0755 (used for binary archives)",
    )

    verify = subparsers.add_parser("verify", help="verify deterministic metadata and modes")
    verify.add_argument("--archive", required=True, type=Path)
    verify.add_argument("--root-name", required=True)
    verify.add_argument(
        "--all-files-executable",
        action="store_true",
        help="require every regular file to have mode 0755",
    )
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _build_parser().parse_args(list(argv) if argv is not None else None)
    try:
        if args.command == "create":
            create_archive(args.source, args.output, args.root_name, args.all_files_executable)
            # Verify immediately, so a platform-specific tar/gzip regression
            # fails the build at its source rather than at release time.
            verify_archive(args.output, args.root_name, args.all_files_executable)
            print(f"deterministic archive created: {args.output}")
        else:
            members = verify_archive(args.archive, args.root_name, args.all_files_executable)
            print(f"deterministic archive verified: {args.archive} ({len(members)} entries)")
        return 0
    except ArchiveError as exc:
        print(f"deterministic archive error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
