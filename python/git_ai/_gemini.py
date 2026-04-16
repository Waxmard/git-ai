"""Gemini client creation and model resolution for git-ai."""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

from google import genai

COMMIT_MODEL = "gemini-3.1-flash-lite-preview"
MR_MODEL = "gemini-3.1-pro-preview"

_KEYCHAIN_SERVICE = "gemini-api-key"
_LOOKUP_TIMEOUT_SECONDS = 5


def _run_lookup(cmd: list[str]) -> str | None:
    """Run a credential-lookup command; return stripped stdout or None."""
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=_LOOKUP_TIMEOUT_SECONDS,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def _resolve_api_key() -> str | None:
    """Find a Gemini API key from env or OS credential stores.

    Order mirrors `resolve_gemini_api_key` in lib/ai-common.sh:
    env var, macOS Keychain, secret-tool, pass, kwallet-query.
    """
    env_key = (os.environ.get("GEMINI_API_KEY") or "").strip()
    if env_key:
        return env_key

    if shutil.which("security"):
        account = os.environ.get("USER") or os.environ.get("LOGNAME")
        if account:
            key = _run_lookup(
                [
                    "security",
                    "find-generic-password",
                    "-a",
                    account,
                    "-s",
                    _KEYCHAIN_SERVICE,
                    "-w",
                ]
            )
            if key:
                return key
        key = _run_lookup(
            ["security", "find-generic-password", "-s", _KEYCHAIN_SERVICE, "-w"]
        )
        if key:
            return key

    if shutil.which("secret-tool"):
        key = _run_lookup(["secret-tool", "lookup", "service", _KEYCHAIN_SERVICE])
        if key:
            return key

    if shutil.which("pass"):
        key = _run_lookup(["pass", "show", _KEYCHAIN_SERVICE])
        if key:
            return key

    if shutil.which("kwallet-query"):
        key = _run_lookup(["kwallet-query", "kdewallet", "-r", _KEYCHAIN_SERVICE])
        if key:
            return key

    return None


def _resolve_vertex_config() -> tuple[str | None, str | None]:
    project = os.environ.get("GOOGLE_CLOUD_PROJECT") or os.environ.get(
        "GOOGLE_VERTEX_PROJECT"
    )
    location = (
        os.environ.get("GOOGLE_CLOUD_LOCATION")
        or os.environ.get("GOOGLE_VERTEX_LOCATION")
        or os.environ.get("VERTEX_LOCATION")
    )
    return project, location


def _check_adc_credentials_file() -> None:
    """Fail fast if GOOGLE_APPLICATION_CREDENTIALS points at a missing file.

    Otherwise defer to the SDK's full ADC discovery (metadata server,
    workload identity, gcloud user creds, etc.).
    """
    path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if path and not Path(path).is_file():
        raise ValueError(
            f"GOOGLE_APPLICATION_CREDENTIALS points at missing file: {path}"
        )


def create_gemini_client() -> genai.Client:
    """Create a Gemini client using available credentials.

    Priority:
    1. GEMINI_API_KEY env, macOS Keychain, secret-tool, pass, kwallet.
    2. GOOGLE_CLOUD_PROJECT + GOOGLE_CLOUD_LOCATION -> Vertex AI with ADC.

    Raises:
        ValueError: if no valid credentials are found, or if
            GOOGLE_APPLICATION_CREDENTIALS is set but missing.
    """
    api_key = _resolve_api_key()
    if api_key:
        return genai.Client(api_key=api_key)

    project, location = _resolve_vertex_config()
    if project and location:
        _check_adc_credentials_file()
        return genai.Client(vertexai=True, project=project, location=location)

    raise ValueError(
        "Gemini auth not configured. Options: set GEMINI_API_KEY, store "
        "'gemini-api-key' in your OS credential store (macOS Keychain, "
        "secret-tool, pass, or kwallet), or set GOOGLE_CLOUD_PROJECT + "
        "GOOGLE_CLOUD_LOCATION for Vertex AI (with ADC or "
        "GOOGLE_APPLICATION_CREDENTIALS)."
    )
