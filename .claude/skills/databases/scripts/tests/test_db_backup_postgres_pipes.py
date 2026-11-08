"""PostgreSQL backup and restore against stub pg_dump, psql and gzip binaries."""

import gzip
import os
import stat
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from db_backup import BackupManager


def _stub(bin_dir: Path, name: str, body: str) -> None:
    path = bin_dir / name
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


@pytest.fixture
def stub_bin(tmp_path, monkeypatch):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    # Only the stubs and the system tools the stubs need are on PATH.
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}/usr/bin{os.pathsep}/bin")
    return bin_dir


@pytest.fixture
def manager(tmp_path):
    backups = tmp_path / "backups"
    backups.mkdir()
    return BackupManager("postgres", str(backups))


def test_compressed_backup_succeeds_when_pg_dump_succeeds(stub_bin, manager):
    _stub(stub_bin, "pg_dump", "echo 'CREATE TABLE t();'\n")
    info = manager.create_backup("postgresql://x/db", "db", compress=True, verify=False)
    assert info is not None
    assert info.filename.endswith(".sql.gz")
    assert b"CREATE TABLE" in gzip.open(Path(manager.backup_dir) / info.filename).read()


def test_compressed_backup_fails_and_leaves_no_file_when_pg_dump_fails(stub_bin, manager):
    _stub(stub_bin, "pg_dump", "echo partial\nexit 1\n")
    info = manager.create_backup("postgresql://x/db", "db", compress=True, verify=False)
    assert info is None
    assert list(Path(manager.backup_dir).glob("*.sql.gz")) == []


def test_restore_gz_pipes_decompressed_sql_with_on_error_stop(stub_bin, manager, tmp_path):
    received = tmp_path / "received.sql"
    args = tmp_path / "args.txt"
    _stub(stub_bin, "psql", f'echo "$@" > {args}\ncat > {received}\n')
    backup = tmp_path / "b.sql.gz"
    backup.write_bytes(gzip.compress(b"SELECT 1;\n"))
    assert manager._restore_postgres(backup, "postgresql://x/db") is True
    assert received.read_bytes() == b"SELECT 1;\n"
    assert "ON_ERROR_STOP=1" in args.read_text()
    assert "--single-transaction" in args.read_text()


def test_restore_reports_failure_when_psql_fails(stub_bin, manager, tmp_path):
    _stub(stub_bin, "psql", "cat >/dev/null\necho boom >&2\nexit 3\n")
    backup = tmp_path / "b.sql"
    backup.write_text("SELECT 1;\n")
    assert manager._restore_postgres(backup, "postgresql://x/db") is False


def test_restore_streams_large_plain_dump_without_loading_it(stub_bin, manager, tmp_path, monkeypatch):
    received = tmp_path / "received.sql"
    _stub(stub_bin, "psql", f"cat > {received}\n")
    backup = tmp_path / "big.sql"
    chunk = b"INSERT INTO t VALUES (1);\n" * 1000
    with open(backup, "wb") as f:
        for _ in range(200):
            f.write(chunk)
    monkeypatch.setattr(Path, "read_bytes", lambda self: (_ for _ in ()).throw(AssertionError("read whole file")))
    assert manager._restore_postgres(backup, "postgresql://x/db") is True
    assert received.stat().st_size == backup.stat().st_size


def test_restore_failure_after_psql_stops_reading_is_reported(stub_bin, manager, tmp_path):
    _stub(stub_bin, "psql", "echo 'syntax error' >&2\nexit 3\n")
    backup = tmp_path / "big.sql"
    backup.write_bytes(b"SELECT 1;\n" * 500000)
    assert manager._restore_postgres(backup, "postgresql://x/db") is False
