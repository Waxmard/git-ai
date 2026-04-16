"""Gemini client creation and model resolution for git-ai."""
from __future__ import annotations

import os

from google import genai

COMMIT_MODEL = "gemini-3.1-flash-lite-preview"
MR_MODEL = "gemini-3.1-pro-preview"


def create_gemini_client() -> genai.Client:
    """Create a Gemini client using available credentials.

    Priority:
    1. GEMINI_API_KEY env var -> direct API key auth
    2. GOOGLE_CLOUD_PROJECT + GOOGLE_CLOUD_LOCATION -> Vertex AI with ADC

    Raises:
        ValueError: if no valid credentials are found.
    """
    api_key = os.environ.get("GEMINI_API_KEY")
    if api_key:
        return genai.Client(api_key=api_key)

    project = os.environ.get("GOOGLE_CLOUD_PROJECT") or os.environ.get("GOOGLE_VERTEX_PROJECT")
    location = (
        os.environ.get("GOOGLE_CLOUD_LOCATION")
        or os.environ.get("GOOGLE_VERTEX_LOCATION")
        or os.environ.get("VERTEX_LOCATION")
    )
    if project and location:
        return genai.Client(vertexai=True, project=project, location=location)

    raise ValueError(
        "Gemini auth not configured. Set GEMINI_API_KEY for direct API access, "
        "or set GOOGLE_CLOUD_PROJECT + GOOGLE_CLOUD_LOCATION for Vertex AI "
        "(ADC or GOOGLE_APPLICATION_CREDENTIALS)."
    )
