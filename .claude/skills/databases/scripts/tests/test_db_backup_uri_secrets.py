"""A password in the connection URI must never reach a child process's argv."""

import gzip
import os
import stat
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from db_backup import BackupManager, mongo_uri_args, split_postgres_password

SECRET = "p@ss/w:rd"
PG_URI = "postgresql://alice:p%40ss%2Fw%3Ard@db.example.com:5432/app?sslmode=require"


def _stub(bin_dir: Path, name: str, body: str) -> None:
    path = bin_dir / name
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


@pytest.fixture
def stub_bin(tmp_path, monkeypatch):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}/usr/bin{os.pathsep}/bin")
    monkeypatch.delenv("PGPASSWORD", raising=False)
    return bin_dir


@pytest.fixture
def manager(tmp_path):
    backups = tmp_path / "backups"
    backups.mkdir()
    return BackupManager("postgres", str(backups))


def test_split_moves_userinfo_and_query_passwords_to_the_environment():
    uri, env = split_postgres_password(PG_URI)
    assert "p%40ss" not in uri and SECRET not in uri
    assert uri.startswith("postgresql://alice@db.example.com:5432/app") and "sslmode=require" in uri
    assert env["PGPASSWORD"] == SECRET

    uri, env = split_postgres_password("postgresql://h/db?user=u&password=pw&sslmode=require")
    assert "pw" not in uri and "sslmode=require" in uri and env["PGPASSWORD"] == "pw"


def test_split_leaves_a_passwordless_uri_alone():
    uri, env = split_postgres_password("postgresql://alice@h/db")
    assert uri == "postgresql://alice@h/db" and "PGPASSWORD" not in env


def test_pg_dump_gets_the_password_through_the_environment(stub_bin, manager, tmp_path):
    seen = tmp_path / "seen.txt"
    _stub(stub_bin, "pg_dump", f'echo "$@ PW=$PGPASSWORD" > {seen}\necho "SELECT 1;"\n')
    assert manager.create_backup(PG_URI, "app", compress=True, verify=False) is not None
    text = seen.read_text()
    assert "p%40ss" not in text.split(" PW=")[0] and text.strip().endswith(f"PW={SECRET}")


def test_psql_restore_gets_the_password_through_the_environment(stub_bin, manager, tmp_path):
    seen = tmp_path / "seen.txt"
    _stub(stub_bin, "psql", f'echo "$@ PW=$PGPASSWORD" > {seen}\ncat > /dev/null\n')
    backup = tmp_path / "b.sql.gz"
    backup.write_bytes(gzip.compress(b"SELECT 1;\n"))
    assert manager._restore_postgres(backup, PG_URI) is True
    text = seen.read_text()
    assert "p%40ss" not in text.split(" PW=")[0] and text.strip().endswith(f"PW={SECRET}")


def test_mongo_uri_with_password_uses_a_private_config_file():
    uri = "mongodb://bob:s3cret@host:27017/db"
    with mongo_uri_args(uri) as args:
        assert "s3cret" not in " ".join(args) and args[0] == "--config"
        path = Path(args[1])
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
        assert "s3cret" in path.read_text()
    assert not path.exists()


def test_mongo_uri_without_password_stays_on_the_command_line():
    with mongo_uri_args("mongodb://host:27017/db") as args:
        assert args == ["--uri", "mongodb://host:27017/db"]
