"""Tests for error handling in _call_gemini."""
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest
from google.genai import errors as genai_errors
from google.genai import types

from git_ai._generate import _call_gemini


def _client_with_response(response: object) -> MagicMock:
    client = MagicMock()
    client.models.generate_content.return_value = response
    return client


def _client_raising(exc: BaseException) -> MagicMock:
    client = MagicMock()
    client.models.generate_content.side_effect = exc
    return client


def _api_error(code: int, message: str = "boom") -> genai_errors.APIError:
    cls = (
        genai_errors.ClientError
        if 400 <= code < 500
        else genai_errors.ServerError
        if 500 <= code < 600
        else genai_errors.APIError
    )
    return cls(code, {"error": {"code": code, "status": "X", "message": message}})


def test_rate_limit_raises_runtime_error() -> None:
    client = _client_raising(_api_error(429, "quota exceeded"))
    with pytest.raises(RuntimeError, match="rate-limited"):
        _call_gemini(client, "model", "sys", "in")


def test_auth_error_raises_with_hint() -> None:
    client = _client_raising(_api_error(401, "bad key"))
    with pytest.raises(RuntimeError, match="auth rejected"):
        _call_gemini(client, "model", "sys", "in")


def test_server_error_translated() -> None:
    client = _client_raising(_api_error(503, "unavailable"))
    with pytest.raises(RuntimeError, match="server error"):
        _call_gemini(client, "model", "sys", "in")


def test_network_exception_wrapped() -> None:
    client = _client_raising(ConnectionError("dns fail"))
    with pytest.raises(RuntimeError, match="Gemini call failed.*dns fail"):
        _call_gemini(client, "model", "sys", "in")


def test_empty_string_response_raises() -> None:
    response = SimpleNamespace(text="", candidates=[], prompt_feedback=None)
    client = _client_with_response(response)
    with pytest.raises(RuntimeError, match="empty response"):
        _call_gemini(client, "model", "sys", "in")


def test_none_response_raises() -> None:
    response = SimpleNamespace(text=None, candidates=[], prompt_feedback=None)
    client = _client_with_response(response)
    with pytest.raises(RuntimeError, match="empty response"):
        _call_gemini(client, "model", "sys", "in")


def test_safety_block_raises_with_reason() -> None:
    candidate = SimpleNamespace(finish_reason=types.FinishReason.SAFETY)
    response = SimpleNamespace(
        text=None, candidates=[candidate], prompt_feedback=None
    )
    client = _client_with_response(response)
    with pytest.raises(RuntimeError, match="blocked the response.*SAFETY"):
        _call_gemini(client, "model", "sys", "in")


def test_prompt_block_raises_with_reason() -> None:
    feedback = SimpleNamespace(block_reason=types.BlockedReason.PROHIBITED_CONTENT)
    response = SimpleNamespace(text=None, candidates=[], prompt_feedback=feedback)
    client = _client_with_response(response)
    with pytest.raises(
        RuntimeError, match="blocked the response.*PROHIBITED_CONTENT"
    ):
        _call_gemini(client, "model", "sys", "in")


def test_successful_response_strips_fences() -> None:
    response = SimpleNamespace(
        text="```\nhello\n```", candidates=[], prompt_feedback=None
    )
    client = _client_with_response(response)
    assert _call_gemini(client, "model", "sys", "in") == "hello"
