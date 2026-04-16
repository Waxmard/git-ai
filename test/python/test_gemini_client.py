"""Tests for create_gemini_client auth priority in _gemini.py."""
import subprocess
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from git_ai._gemini import create_gemini_client

_VERTEX_ENV_VARS = [
    "GOOGLE_CLOUD_PROJECT",
    "GOOGLE_VERTEX_PROJECT",
    "GOOGLE_CLOUD_LOCATION",
    "GOOGLE_VERTEX_LOCATION",
    "VERTEX_LOCATION",
    "GOOGLE_APPLICATION_CREDENTIALS",
]


def _no_lookup_tools(_tool: str) -> None:
    """`shutil.which` stub that claims no credential-store tools exist."""
    return None


def test_api_key_auth(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "test-key")
    monkeypatch.delenv("GOOGLE_CLOUD_PROJECT", raising=False)

    mock_client = MagicMock()
    with patch("git_ai._gemini.genai.Client", return_value=mock_client) as mock_cls:
        result = create_gemini_client()

    mock_cls.assert_called_once_with(api_key="test-key")
    assert result is mock_client


def test_vertex_ai_auth(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.setenv("GOOGLE_CLOUD_PROJECT", "my-project")
    monkeypatch.setenv("GOOGLE_CLOUD_LOCATION", "us-east4")
    monkeypatch.delenv("GOOGLE_APPLICATION_CREDENTIALS", raising=False)

    mock_client = MagicMock()
    with patch("git_ai._gemini.genai.Client", return_value=mock_client) as mock_cls, \
         patch("git_ai._gemini.shutil.which", side_effect=_no_lookup_tools):
        result = create_gemini_client()

    mock_cls.assert_called_once_with(
        vertexai=True, project="my-project", location="us-east4"
    )
    assert result is mock_client


def test_vertex_project_fallback_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.delenv("GOOGLE_CLOUD_PROJECT", raising=False)
    monkeypatch.setenv("GOOGLE_VERTEX_PROJECT", "vertex-project")
    monkeypatch.setenv("GOOGLE_CLOUD_LOCATION", "us-central1")
    monkeypatch.delenv("GOOGLE_APPLICATION_CREDENTIALS", raising=False)

    with patch("git_ai._gemini.genai.Client") as mock_cls, \
         patch("git_ai._gemini.shutil.which", side_effect=_no_lookup_tools):
        create_gemini_client()

    mock_cls.assert_called_once_with(
        vertexai=True, project="vertex-project", location="us-central1"
    )


def test_api_key_takes_priority_over_vertex(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "my-key")
    monkeypatch.setenv("GOOGLE_CLOUD_PROJECT", "my-project")
    monkeypatch.setenv("GOOGLE_CLOUD_LOCATION", "us-east4")

    with patch("git_ai._gemini.genai.Client") as mock_cls:
        create_gemini_client()

    mock_cls.assert_called_once_with(api_key="my-key")


def test_no_auth_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    for var in _VERTEX_ENV_VARS:
        monkeypatch.delenv(var, raising=False)

    with patch("git_ai._gemini.shutil.which", side_effect=_no_lookup_tools):
        with pytest.raises(ValueError, match="Gemini auth not configured"):
            create_gemini_client()


def test_empty_api_key_falls_through_to_vertex(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "")
    monkeypatch.setenv("GOOGLE_CLOUD_PROJECT", "p")
    monkeypatch.setenv("GOOGLE_CLOUD_LOCATION", "us-east4")
    monkeypatch.delenv("GOOGLE_APPLICATION_CREDENTIALS", raising=False)

    with patch("git_ai._gemini.genai.Client") as mock_cls, \
         patch("git_ai._gemini.shutil.which", side_effect=_no_lookup_tools):
        create_gemini_client()

    mock_cls.assert_called_once_with(vertexai=True, project="p", location="us-east4")


def test_whitespace_api_key_falls_through(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "   ")
    monkeypatch.setenv("GOOGLE_CLOUD_PROJECT", "p")
    monkeypatch.setenv("GOOGLE_CLOUD_LOCATION", "us-east4")
    monkeypatch.delenv("GOOGLE_APPLICATION_CREDENTIALS", raising=False)

    with patch("git_ai._gemini.genai.Client") as mock_cls, \
         patch("git_ai._gemini.shutil.which", side_effect=_no_lookup_tools):
        create_gemini_client()

    mock_cls.assert_called_once_with(vertexai=True, project="p", location="us-east4")


def test_keychain_api_key_used(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.setenv("USER", "me")
    for var in _VERTEX_ENV_VARS:
        monkeypatch.delenv(var, raising=False)

    def which(tool: str) -> str | None:
        return "/usr/bin/security" if tool == "security" else None

    def run(cmd: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
        assert cmd[:2] == ["security", "find-generic-password"]
        return subprocess.CompletedProcess(cmd, returncode=0, stdout="kc-key\n", stderr="")

    with patch("git_ai._gemini.shutil.which", side_effect=which), \
         patch("git_ai._gemini.subprocess.run", side_effect=run), \
         patch("git_ai._gemini.genai.Client") as mock_cls:
        create_gemini_client()

    mock_cls.assert_called_once_with(api_key="kc-key")


def test_secret_tool_api_key_used(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    for var in _VERTEX_ENV_VARS:
        monkeypatch.delenv(var, raising=False)

    def which(tool: str) -> str | None:
        return "/usr/bin/secret-tool" if tool == "secret-tool" else None

    def run(cmd: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
        assert cmd[0] == "secret-tool"
        return subprocess.CompletedProcess(cmd, returncode=0, stdout="st-key", stderr="")

    with patch("git_ai._gemini.shutil.which", side_effect=which), \
         patch("git_ai._gemini.subprocess.run", side_effect=run), \
         patch("git_ai._gemini.genai.Client") as mock_cls:
        create_gemini_client()

    mock_cls.assert_called_once_with(api_key="st-key")


def test_keychain_miss_falls_through_to_vertex(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.setenv("USER", "me")
    monkeypatch.setenv("GOOGLE_CLOUD_PROJECT", "p")
    monkeypatch.setenv("GOOGLE_CLOUD_LOCATION", "us-east4")
    monkeypatch.delenv("GOOGLE_APPLICATION_CREDENTIALS", raising=False)

    def which(tool: str) -> str | None:
        return f"/usr/bin/{tool}" if tool in {"security", "secret-tool"} else None

    def run(cmd: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(cmd, returncode=1, stdout="", stderr="")

    with patch("git_ai._gemini.shutil.which", side_effect=which), \
         patch("git_ai._gemini.subprocess.run", side_effect=run), \
         patch("git_ai._gemini.genai.Client") as mock_cls:
        create_gemini_client()

    mock_cls.assert_called_once_with(vertexai=True, project="p", location="us-east4")


def test_missing_adc_file_raises(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.setenv("GOOGLE_CLOUD_PROJECT", "p")
    monkeypatch.setenv("GOOGLE_CLOUD_LOCATION", "us-east4")
    bogus = tmp_path / "does-not-exist.json"
    monkeypatch.setenv("GOOGLE_APPLICATION_CREDENTIALS", str(bogus))

    with patch("git_ai._gemini.shutil.which", side_effect=_no_lookup_tools):
        with pytest.raises(ValueError, match="GOOGLE_APPLICATION_CREDENTIALS"):
            create_gemini_client()


def test_vertex_without_gcloud_still_builds_client(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """No gcloud, no credentials file — SDK handles ADC discovery itself."""
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.setenv("GOOGLE_CLOUD_PROJECT", "p")
    monkeypatch.setenv("GOOGLE_CLOUD_LOCATION", "us-east4")
    monkeypatch.delenv("GOOGLE_APPLICATION_CREDENTIALS", raising=False)

    with patch("git_ai._gemini.shutil.which", side_effect=_no_lookup_tools), \
         patch("git_ai._gemini.genai.Client") as mock_cls:
        create_gemini_client()

    mock_cls.assert_called_once_with(vertexai=True, project="p", location="us-east4")
