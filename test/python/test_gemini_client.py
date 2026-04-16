"""Tests for create_gemini_client auth priority in _gemini.py."""
from unittest.mock import MagicMock, patch

import pytest

from git_ai._gemini import create_gemini_client


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

    mock_client = MagicMock()
    with patch("git_ai._gemini.genai.Client", return_value=mock_client) as mock_cls:
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

    with patch("git_ai._gemini.genai.Client") as mock_cls:
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
    for var in [
        "GEMINI_API_KEY",
        "GOOGLE_CLOUD_PROJECT",
        "GOOGLE_VERTEX_PROJECT",
        "GOOGLE_CLOUD_LOCATION",
        "GOOGLE_VERTEX_LOCATION",
        "VERTEX_LOCATION",
    ]:
        monkeypatch.delenv(var, raising=False)

    with pytest.raises(ValueError, match="Gemini auth not configured"):
        create_gemini_client()
