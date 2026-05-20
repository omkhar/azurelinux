# SPDX-License-Identifier: MIT
"""Validate nginx works on the container-base image.

Uses ``@pytest.mark.dockerfile()`` to build a custom image with
nginx installed on top of the image-under-test.
"""

from __future__ import annotations

import pytest


@pytest.mark.dockerfile()
def test_nginx_config_valid(container_exec) -> None:
    """nginx configuration must pass validation."""
    result = container_exec("nginx -t 2>&1")
    assert result.exit_code == 0, f"nginx -t failed: {result.output}"
    assert "syntax is ok" in result.output
    assert "test is successful" in result.output


@pytest.mark.dockerfile()
def test_nginx_serves_response(container_exec) -> None:
    """nginx must start and serve HTTP responses."""
    # Start nginx in the background.
    start = container_exec("nginx")
    assert start.exit_code == 0, f"nginx failed to start: {start.output}"

    # Verify it responds on port 80.
    result = container_exec("curl -sf http://localhost:80/")
    assert result.exit_code == 0, f"curl failed: {result.output}"
    assert "azl-nginx-ok" in result.output


@pytest.mark.dockerfile()
def test_nginx_health_endpoint(container_exec) -> None:
    """nginx /health endpoint must return 200."""
    start = container_exec("nginx")
    assert start.exit_code == 0, f"nginx failed to start: {start.output}"

    result = container_exec("curl -sf http://localhost:80/health")
    assert result.exit_code == 0, f"health check failed: {result.output}"
    assert "healthy" in result.output
