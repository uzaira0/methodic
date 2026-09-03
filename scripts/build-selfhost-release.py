#!/usr/bin/env python3
"""Build a deterministic, source-free Chronicle self-host release bundle."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SELFHOST = ROOT / "selfhost"
# Accept the registry host:port form used by private/self-hosted OCI registries while still
# requiring an immutable digest. The final optional colon remains the image tag, not a port.
IMAGE_RE = re.compile(
    r"^[A-Za-z0-9._-]+(?::[0-9]{1,5})?"
    r"(?:/[A-Za-z0-9._-]+)*(?::[A-Za-z0-9._-]+)?"
    r"@sha256:[0-9a-f]{64}$"
)
VERSION_RE = re.compile(
    r"^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)
REVISION_RE = re.compile(r"^[0-9a-f]{40}$")
PLACEHOLDERS = {
    "__CHRONICLE_BACKEND_IMAGE__": "backend",
    "__CHRONICLE_SELFHOST_FRONTEND_IMAGE__": "frontend",
    "__CHRONICLE_SELFHOST_CADDY_IMAGE__": "caddy",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create a self-host bundle that contains configuration only and pulls immutable images."
    )
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--source-date-epoch", required=True, type=int)
    parser.add_argument("--backend-image", required=True)
    parser.add_argument("--frontend-image", required=True)
    parser.add_argument("--caddy-image", required=True)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build" / "releases")
    return parser.parse_args()


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"self-host release build failed: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_within(root: Path, candidate: Path, *, strict: bool, description: str) -> Path:
    """Resolve a release path and reject traversal or symlink escape from its declared root."""
    resolved_root = root.resolve(strict=strict)
    resolved_candidate = candidate.resolve(strict=strict)
    try:
        resolved_candidate.relative_to(resolved_root)
    except ValueError:
        fail(f"{description} escapes its release root: {candidate}")
    return resolved_candidate


def copy_tree(source: Path, destination: Path) -> None:
    source_root = source.resolve(strict=True)
    destination_root = destination.resolve(strict=False)
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if path.is_symlink():
            fail(f"refusing symlink in release input: {path}")
        safe_source = resolve_within(
            source_root, path, strict=True, description="release input"
        )
        target = resolve_within(
            destination_root,
            destination_root / relative,
            strict=False,
            description="release output",
        )
        if path.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            target.chmod(0o755)
        elif path.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            with safe_source.open("rb") as source_handle, target.open("xb") as target_handle:
                shutil.copyfileobj(source_handle, target_handle)
            target.chmod(0o755 if os.access(path, os.X_OK) else 0o644)
        else:
            fail(f"unsupported release input type: {path}")


def add_to_tar(archive: tarfile.TarFile, path: Path, arcname: str, epoch: int) -> None:
    info = archive.gettarinfo(str(path), arcname=arcname)
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = epoch
    if path.is_dir():
        archive.addfile(info)
        return
    with path.open("rb") as handle:
        archive.addfile(info, handle)


def main() -> None:
    args = parse_args()
    version_match = VERSION_RE.fullmatch(args.version)
    if not version_match:
        fail("--version must be a semantic release version such as v1.2.3 or v1.2.3-rc.1")
    prerelease = version_match.group(4)
    if prerelease is not None:
        for identifier in prerelease.split("."):
            if identifier.isdigit() and len(identifier) > 1 and identifier.startswith("0"):
                fail("--version numeric prerelease identifiers must not contain leading zeroes")
    if not REVISION_RE.fullmatch(args.source_revision):
        fail("--source-revision must be a full lowercase Git SHA")
    if not 0 <= args.source_date_epoch <= 0xFFFFFFFF:
        fail("--source-date-epoch must fit the gzip timestamp range (0 through 4294967295)")

    images = {
        "backend": args.backend_image,
        "frontend": args.frontend_image,
        "caddy": args.caddy_image,
    }
    for name, image in images.items():
        if not IMAGE_RE.fullmatch(image):
            fail(f"{name} image must be an immutable name@sha256 reference")

    normalized_version = args.version.removeprefix("v")
    bundle_name = f"chronicle-selfhost-{normalized_version}"
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    final_directory = output_dir / bundle_name
    archive_path = output_dir / f"{bundle_name}.tar.gz"
    checksum_path = output_dir / f"{bundle_name}.tar.gz.sha256"
    for output in (final_directory, archive_path, checksum_path):
        if output.exists() or output.is_symlink():
            fail(f"refusing to replace existing output: {output}")

    staging_parent = Path(tempfile.mkdtemp(prefix=".selfhost-release-", dir=output_dir))
    try:
        bundle = staging_parent / bundle_name
        bundle.mkdir(mode=0o755)
        copy_tree(SELFHOST / "caddy", bundle / "selfhost" / "caddy")
        copy_tree(SELFHOST / "config", bundle / "selfhost" / "config")
        copy_tree(SELFHOST / "docs", bundle / "selfhost" / "docs")
        shutil.copyfile(
            ROOT / "docs" / "db" / "POSTGRES-18-UPGRADE.md",
            bundle / "selfhost" / "docs" / "POSTGRES-18-UPGRADE.md",
        )
        (bundle / "selfhost" / "docs" / "POSTGRES-18-UPGRADE.md").chmod(0o644)
        copy_tree(SELFHOST / "monitoring", bundle / "selfhost" / "monitoring")
        copy_tree(SELFHOST / "overlays", bundle / "selfhost" / "overlays")

        root_files = [
            ".env.example",
            ".gitignore",
            "Caddyfile.split",
            "Caddyfile.split.local",
            "Caddyfile.split.tls",
            "README.md",
            "backend-entrypoint.sh",
            "backup-entrypoint.sh",
            "ca-export.sh",
            "cert-init.sh",
            "chronicle",
            "db-init.sh",
            "docker-compose.yml",
            "guard-config.sh",
            "init-tde.sh",
            "restore.sh",
            "rotate-secret.sh",
            "upgrade.sh",
            "verify-config.sh",
        ]
        for name in root_files:
            source = SELFHOST / name
            if not source.is_file() or source.is_symlink():
                fail(f"required bundle input is missing or unsafe: {source}")
            target = bundle / "selfhost" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            if name == ".env.example":
                # A self-hoster's documented `cp .env.example .env` must produce a private
                # secret file without relying on a favorable shell umask or an extra chmod.
                target.chmod(0o600)
            else:
                target.chmod(0o755 if os.access(source, os.X_OK) else 0o644)

        for runtime_dir in (bundle / "selfhost" / "backups", bundle / "selfhost" / "tls"):
            runtime_dir.mkdir(mode=0o700)

        docker_dir = bundle / "docker"
        docker_dir.mkdir(mode=0o755)
        role_sql = ROOT / "docker" / "init-db-roles.sql"
        shutil.copyfile(role_sql, docker_dir / role_sql.name)
        (docker_dir / role_sql.name).chmod(0o644)
        shutil.copyfile(ROOT / "LICENSE", bundle / "LICENSE")
        (bundle / "LICENSE").chmod(0o644)

        env_path = bundle / "selfhost" / ".env.example"
        env_text = env_path.read_text(encoding="utf-8")
        for placeholder, image_name in PLACEHOLDERS.items():
            if env_text.count(placeholder) != 1:
                fail(f"expected exactly one {placeholder} in selfhost/.env.example")
            env_text = env_text.replace(placeholder, images[image_name])
        env_text = re.sub(
            r"(?m)^RELEASE_VERSION=.*$", f"RELEASE_VERSION={normalized_version}", env_text, count=1
        )
        if "__CHRONICLE_" in env_text:
            fail("unresolved Chronicle image placeholder remains in generated .env.example")
        env_path.write_text(env_text, encoding="utf-8")

        compose_text = (bundle / "selfhost" / "docker-compose.yml").read_text(encoding="utf-8")
        if re.search(r"(?m)^\s*build\s*:", compose_text):
            fail("generated Compose still contains a local build block")
        if "context: .." in compose_text or "dockerfile:" in compose_text:
            fail("generated Compose still references the source workspace")

        file_hashes: dict[str, str] = {}
        for path in sorted(bundle.rglob("*")):
            if path.is_file():
                file_hashes[path.relative_to(bundle).as_posix()] = sha256(path)
        manifest = {
            "schema_version": 1,
            "release_version": normalized_version,
            "source_revision": args.source_revision,
            "source_date_epoch": args.source_date_epoch,
            "images": images,
            "files": file_hashes,
        }
        manifest_path = bundle / "release-manifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        manifest_path.chmod(0o644)

        # Build every byte before publishing any final path. The previous ordering moved the
        # directory first and only then created the tarball; a tar/gzip/disk failure left a
        # release-looking directory plus a partial archive and made a clean retry impossible.
        staged_archive = staging_parent / archive_path.name
        staged_checksum = staging_parent / checksum_path.name
        with staged_archive.open("xb") as raw_archive:
            with gzip.GzipFile(
                filename="", mode="wb", fileobj=raw_archive, mtime=args.source_date_epoch
            ) as compressed:
                with tarfile.open(
                    fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT
                ) as archive:
                    add_to_tar(archive, bundle, bundle_name, args.source_date_epoch)
                    for path in sorted(bundle.rglob("*")):
                        add_to_tar(
                            archive,
                            path,
                            f"{bundle_name}/{path.relative_to(bundle).as_posix()}",
                            args.source_date_epoch,
                        )

        archive_digest = sha256(staged_archive)
        staged_checksum.write_text(
            f"{archive_digest}  {archive_path.name}\n", encoding="ascii"
        )

        for output in (final_directory, archive_path, checksum_path):
            if output.exists() or output.is_symlink():
                fail(f"refusing to replace output created during this build: {output}")

        published: list[Path] = []
        try:
            # Directory rename is atomic on the output filesystem. Hard-linking the two files
            # gives no-replace publication semantics (staging is deliberately under output_dir).
            os.rename(bundle, final_directory)
            published.append(final_directory)
            os.link(staged_archive, archive_path)
            published.append(archive_path)
            staged_archive.unlink()
            os.link(staged_checksum, checksum_path)
            published.append(checksum_path)
            staged_checksum.unlink()
        except BaseException:
            # These are exact paths this invocation successfully published after proving they
            # were absent. Remove only those paths so an ordinary exception is retryable.
            for output in reversed(published):
                if output == final_directory:
                    shutil.rmtree(output)
                else:
                    output.unlink(missing_ok=True)
            raise
    finally:
        if staging_parent.exists():
            shutil.rmtree(staging_parent)
    print(archive_path)
    print(checksum_path)


if __name__ == "__main__":
    main()
