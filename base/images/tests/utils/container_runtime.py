# SPDX-License-Identifier: MIT
"""Container runtime orchestration using podman-py.

Provides utilities for creating running containers with exec access
for runtime integration testing. Uses the podman Python library
(podman-py) which communicates via the Podman REST API socket.

The podman socket must be active before tests run. Start it with::

    systemctl --user start podman.socket
    # or: podman system service --timeout=0 &
"""

from __future__ import annotations

import logging
import os
import uuid
from pathlib import Path
from typing import NamedTuple

from podman import PodmanClient
from podman.domain.containers import Container
from podman.errors import APIError, NotFound

from .tools import NativeTool

logger = logging.getLogger(__name__)

# Register podman as a required native tool for container testing.
PODMAN = NativeTool(
    name="podman",
    package_hint="podman",
    reason="container runtime for live container tests",
    when="container",
)


class ContainerExecResult(NamedTuple):
    """Result of executing a command inside a container."""
    exit_code: int
    output: str


class ContainerInstance(NamedTuple):
    """A running container managed by the test framework."""
    container_id: str
    container_name: str
    image_ref: str


class ContainerRuntimeError(Exception):
    """Container runtime operation failed."""


def _find_podman_socket() -> Path:
    """Locate the podman socket, trying rootless first then rootful."""
    candidates: list[Path] = []

    # Rootless paths.
    xdg_runtime = os.environ.get("XDG_RUNTIME_DIR")
    if xdg_runtime:
        candidates.append(Path(xdg_runtime) / "podman" / "podman.sock")
    candidates.append(Path(f"/run/user/{os.getuid()}/podman/podman.sock"))

    # Rootful path.
    candidates.append(Path("/run/podman/podman.sock"))

    for sock in candidates:
        if sock.exists():
            logger.debug("Found podman socket: %s", sock)
            return sock

    tried = ", ".join(str(s) for s in candidates)
    raise ContainerRuntimeError(
        f"Podman socket not found. Tried: {tried}. "
        "Start it with: systemctl --user start podman.socket "
        "(rootless) or systemctl start podman.socket (rootful)"
    )


def get_podman_client() -> PodmanClient:
    """Create a PodmanClient connected to the podman socket.

    Tries rootless first, then falls back to rootful.
    Raises ContainerRuntimeError if the socket is unavailable.
    """
    socket_path = _find_podman_socket()
    uri = f"unix://{socket_path}"
    logger.info("Connecting to podman at %s", uri)

    client = PodmanClient(base_url=uri)
    try:
        client.ping()
    except APIError as exc:
        raise ContainerRuntimeError(
            f"Cannot connect to podman at {uri}: {exc}"
        ) from exc
    return client


def resolve_image_reference(
    client: PodmanClient,
    *,
    image_path: Path | None = None,
    image_ref: str | None = None,
) -> str:
    """Resolve to a podman-usable image reference.

    Exactly one of *image_path* or *image_ref* must be provided.

    - **image_path**: a local archive file (``.tar``, ``.tar.xz``, etc.)
      is loaded via ``podman load`` and the resulting image ID is returned.
    - **image_ref**: an image reference (e.g. ``mcr.microsoft.com/azurelinux/base/core:4.0``
      or ``localhost/container-base:latest``). Pulled from the registry
      if not already present locally.

    Returns:
        Image ID (for archives) or the image reference string.
    """
    if image_path and image_ref:
        raise ContainerRuntimeError(
            "image_path and image_ref are mutually exclusive"
        )
    if not image_path and not image_ref:
        raise ContainerRuntimeError(
            "Either image_path or image_ref must be provided"
        )

    if image_ref:
        # Ensure the image is available locally; pull if needed.
        try:
            client.images.get(image_ref)
            logger.info("Image already present locally: %s", image_ref)
        except NotFound:
            logger.info("Pulling image: %s", image_ref)
            client.images.pull(image_ref)
        return image_ref

    # Load from archive file.
    assert image_path is not None
    logger.info("Loading image archive: %s", image_path)
    with open(image_path, "rb") as f:
        images = list(client.images.load(f))

    if not images:
        raise ContainerRuntimeError(
            f"podman load returned no images for {image_path}"
        )

    image = images[0]
    logger.info("Loaded image: %s", image.id[:12])
    return image.id


# Session-level cache for images built from Dockerfiles.
# Keyed by resolved Dockerfile path; avoids redundant builds when
# multiple tests share the same Dockerfile.
_built_image_cache: dict[str, str] = {}


def build_image(
    client: PodmanClient,
    dockerfile_path: Path,
    base_image_ref: str,
) -> str:
    """Build a container image from a Dockerfile.

    Injects the image-under-test as the ``BASE_IMAGE`` build arg.
    Results are cached per session by Dockerfile path.
    """
    cache_key = str(dockerfile_path)
    if cache_key in _built_image_cache:
        cached = _built_image_cache[cache_key]
        logger.info("Using cached build for %s: %s", dockerfile_path.name, cached[:12])
        return cached

    context_dir = dockerfile_path.parent
    logger.info(
        "Building image from %s (base: %s, context: %s)",
        dockerfile_path, base_image_ref[:12], context_dir,
    )

    image, _build_logs = client.images.build(
        path=str(context_dir),
        dockerfile=str(dockerfile_path),
        buildargs={"BASE_IMAGE": base_image_ref},
        rm=True,
    )

    image_id = image.id
    logger.info("Built image: %s", image_id[:12])
    _built_image_cache[cache_key] = image_id
    return image_id


def create_container(
    client: PodmanClient,
    image_ref: str,
    container_name: str | None = None,
) -> ContainerInstance:
    """Create and start a container with exec access.

    The container runs ``sleep infinity`` to stay alive for the duration
    of the test, allowing repeated ``exec`` calls.

    Args:
        client: Active PodmanClient instance.
        image_ref: Image ID or reference to run.
        container_name: Optional name; auto-generated if None.

    Returns:
        A ContainerInstance with the container's ID, name, and image ref.
    """
    if container_name is None:
        container_name = f"azl-test-{uuid.uuid4().hex[:12]}"

    logger.info("Creating container %s from image %s", container_name, image_ref[:12])

    container: Container = client.containers.run(
        image_ref,
        command=["sleep", "infinity"],
        name=container_name,
        detach=True,
    )

    # Verify the container is running and exec works.
    try:
        container.reload()
        if container.status != "running":
            raise ContainerRuntimeError(
                f"Container {container_name} is not running "
                f"(status: {container.status})"
            )

        exit_code, output = container.exec_run(["echo", "ready"])
        if exit_code != 0:
            raise ContainerRuntimeError(
                f"Container exec readiness check failed for {container_name} "
                f"(exit_code={exit_code}, output={output!r})"
            )
    except BaseException:
        # Clean up on any failure (including KeyboardInterrupt).
        logger.warning("Readiness check failed; removing container %s", container_name)
        try:
            container.remove(force=True)
        except Exception as cleanup_exc:
            logger.warning("Failed to clean up container %s: %s", container_name, cleanup_exc)
        raise

    logger.info("Container ready: %s (ID: %s)", container_name, container.id[:12])
    return ContainerInstance(
        container_id=container.id,
        container_name=container_name,
        image_ref=image_ref,
    )


def exec_in_container(
    client: PodmanClient,
    container_name: str,
    command: str,
) -> ContainerExecResult:
    """Execute a shell command inside a running container.

    Args:
        client: Active PodmanClient instance.
        container_name: Name of the running container.
        command: Shell command string to execute via ``bash -c``.

    Returns:
        ContainerExecResult with exit_code and combined output.
    """
    logger.debug("Container exec [%s]: %s", container_name, command)
    container = client.containers.get(container_name)
    exit_code, output = container.exec_run(["bash", "-c", command])
    output_str = output.decode("utf-8", errors="replace") if isinstance(output, bytes) else str(output)
    return ContainerExecResult(exit_code=exit_code, output=output_str)


def destroy_container(client: PodmanClient, container_name: str) -> None:
    """Kill and remove a container (best-effort, never raises)."""
    logger.info("Destroying container %s", container_name)
    try:
        container = client.containers.get(container_name)
        container.kill()
    except (NotFound, APIError) as exc:
        logger.debug("Container kill skipped (%s): %s", container_name, exc)

    try:
        container = client.containers.get(container_name)
        container.remove(force=True)
    except (NotFound, APIError) as exc:
        logger.debug("Container remove skipped (%s): %s", container_name, exc)
