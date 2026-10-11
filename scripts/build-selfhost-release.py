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
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SELFHOST = ROOT / "selfhost"
sys.path.insert(0, str(SELFHOST))
from chronicle_ops.release import RELEASE_SIGNER, parse_version, read_manifest

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
SMOKE_ARCHIVE_HASH_FIELD = "release_archive_sha256"
PREVIOUS_RELEASE_TRUSTED_SHA256_ENV = "CHRONICLE_PREVIOUS_RELEASE_TRUSTED_SHA256"
SMOKE_REQUIRED_EVIDENCE = dict.fromkeys((
    "source_free_archive", "fresh_install", "previous_version_upgrade",
    "automatic_pre_upgrade_backup", "upgrade_environment_isolation", "upgrade_state_continuity",
    "schema_safe_rollback", "forward_recovery", "tde_rotation_restart_continuity",
    "tde_rotated_keyring_backup", "external_boundary_verify", "restart_order_recovery",
    "study_restart_persistence", "clean_restore", "disk_full_recovery", "dashboard_headers",
    "container_security_audit", "keyless_volume_fails", "internal_guard_rate_limit",
    "post_restore_verify", "monitoring_data_path",
), "pass") | {"monitoring": "true"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create a self-host bundle that contains configuration only and pulls immutable images."
    )
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-revision", required=True)
    # The private checkout's HEAD never exists in the public mirror; this is the public commit
    # the release tag points at, so a self-hoster can map the bundle to published source.
    parser.add_argument("--public-revision")
    parser.add_argument("--source-date-epoch", required=True, type=int)
    parser.add_argument("--backend-image", required=True)
    parser.add_argument("--frontend-image", required=True)
    parser.add_argument("--caddy-image", required=True)
    parser.add_argument("--backup-image")
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


def verify_release_signature(checksum: Path, signature: Path, public_key: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="chronicle-release-signature-") as directory:
        allowed = Path(directory) / "allowed_signers"
        allowed.write_text(f"{RELEASE_SIGNER} {public_key.read_text().strip()}\n")
        with checksum.open("rb") as message:
            result = subprocess.run(
                ["ssh-keygen", "-Y", "verify", "-f", str(allowed), "-I", RELEASE_SIGNER,
                 "-n", RELEASE_SIGNER, "-s", str(signature)],
                stdin=message, capture_output=True, timeout=30)
        if result.returncode:
            fail("invalid release signature")


def require_archive_checksum(archive: Path, checksum: Path) -> None:
    entry = re.fullmatch(r"([0-9a-f]{64}) [ *]" + re.escape(archive.name) + r"\n?",
                         checksum.read_text(encoding="ascii"))
    if entry is None or entry[1] != sha256(archive):
        fail("release archive checksum does not match its sidecar")


def require_trusted_release_archive(archive: Path, checksum: Path, signature: Path,
                                    public_key: Path, trusted_sha256: str = "") -> None:
    if signature.exists():
        verify_release_signature(checksum, signature, public_key)
    elif not re.fullmatch(r"[0-9a-f]{64}", trusted_sha256) or sha256(archive) != trusted_sha256:
        fail("unsigned predecessor requires an independently trusted archive SHA-256")
    require_archive_checksum(archive, checksum)


def archive_manifest(source: tarfile.TarFile) -> dict:
    manifests = [member for member in source.getmembers()
                 if member.isfile() and member.name.endswith("/release-manifest.json")]
    if len(manifests) != 1:
        fail("release archive must contain one release manifest")
    with source.extractfile(manifests[0]) as handle:
        return json.load(handle)


def smoke_predecessor_evidence(archive: Path) -> dict[str, str]:
    with tarfile.open(archive, "r:gz") as source:
        manifest = archive_manifest(source)
    return {
        "previous_source_revision": manifest["source_revision"],
        "previous_release_version": manifest["release_version"],
        "previous_release_archive_sha256": sha256(archive),
    }


def require_smoke_result(result: Path, archive: Path, previous_archive: Path) -> None:
    rows = [line.split("=", 1) for line in result.read_text().splitlines()]
    if any(len(row) != 2 for row in rows) or len({row[0] for row in rows}) != len(rows):
        fail("malformed release smoke result")
    evidence = dict(rows)
    if evidence.get("status") != "passed" or evidence.get(SMOKE_ARCHIVE_HASH_FIELD) != sha256(archive):
        fail("release smoke did not pass for this signed archive")
    if any(evidence.get(key) != expected
           for key, expected in smoke_predecessor_evidence(previous_archive).items()):
        fail("release smoke predecessor does not match the current latest published archive")
    if any(evidence.get(key) != expected for key, expected in SMOKE_REQUIRED_EVIDENCE.items()):
        fail("release smoke is missing required passing coverage")


def backup_image_pin(text: str) -> str:
    pins = re.findall(r"(?m)^    image: (\S+)$", text)
    if len(pins) != 1 or not IMAGE_RE.fullmatch(pins[0]):
        fail("expected exactly one immutable backup image pin")
    return pins[0]


def require_public_archive_images(archive: Path) -> None:
    with tarfile.open(archive, "r:gz") as source:
        manifest = archive_manifest(source)
        images = manifest["images"]
        if not isinstance(images, dict) or set(images) != set(PLACEHOLDERS.values()) or any(
                not isinstance(pin, str) or not IMAGE_RE.fullmatch(pin) for pin in images.values()):
            fail("candidate has invalid runtime image pins")
        overlays = [member for member in source.getmembers()
                    if member.isfile() and member.name.endswith("/selfhost/overlays/backups.yml")]
        if len(overlays) != 1:
            fail("candidate must contain one backup overlay")
        with source.extractfile(overlays[0]) as handle:
            backup = backup_image_pin(handle.read().decode())
    with tempfile.TemporaryDirectory(prefix="chronicle-anonymous-registry-") as directory:
        for pin in [*images.values(), backup]:
            result = subprocess.run(["docker", "manifest", "inspect", pin],
                                    env=dict(os.environ, DOCKER_CONFIG=directory),
                                    capture_output=True, timeout=60)
            if result.returncode:
                fail(f"release image is unavailable without registry credentials: {pin}")


def require_public_release_tag(remote: str, tag: str, revision: str) -> None:
    if not isinstance(revision, str) or not REVISION_RE.fullmatch(revision):
        fail("release has no valid public source revision")
    ref = f"refs/tags/{tag}"
    result = subprocess.run(["git", "ls-remote", remote, ref, ref + "^{}"],
                            check=True, capture_output=True, text=True, timeout=60)
    refs = {name: commit for commit, name in (line.split() for line in result.stdout.splitlines())}
    if refs and refs.get(ref + "^{}", refs.get(ref)) != revision:
        fail("existing public release tag does not match the verified public source revision")


def require_smoke_images(bundle: Path, images: dict[str, str], backup_image: str) -> None:
    manifest, _ = read_manifest(bundle / "release-manifest.json", True)
    if manifest["images"] != images:
        fail("candidate images do not match the smoke runtime images")
    if backup_image_pin((bundle / "selfhost/overlays/backups.yml").read_text()) != backup_image:
        fail("candidate backup image does not match the smoke runtime image")


def require_changelog(path: Path, version: str) -> None:
    target = parse_version(version, path)
    versions = []
    for heading in re.findall(r"(?m)^## \[([^\]]+)\]$", path.read_text(encoding="utf-8")):
        try:
            versions.append(parse_version(heading, path))
        except ValueError:
            continue
    if versions.count(target) != 1:
        fail("CHANGELOG.md must contain exactly one entry for the target release")
    if versions != sorted(versions, reverse=True):
        fail("CHANGELOG.md release entries must be ordered newest first")


def pin_backup_image(path: Path, image: str) -> None:
    text, count = re.subn(r"(?m)^(    image: )\S+$", lambda match: match[1] + image,
                          path.read_text(encoding="utf-8"))
    if count != 1:
        fail("expected exactly one backup image in overlays/backups.yml")
    path.write_text(text, encoding="utf-8")


def resolve_within(root: Path, candidate: Path, *, strict: bool, description: str) -> Path:
    """Resolve a release path and reject traversal or symlink escape from its declared root."""
    resolved_root = root.resolve(strict=strict)
    resolved_candidate = candidate.resolve(strict=strict)
    try:
        resolved_candidate.relative_to(resolved_root)
    except ValueError:
        fail(f"{description} escapes its release root: {candidate}")
    return resolved_candidate


def require_committed_release_source(root: Path, revision: str) -> None:
    """Bind the claimed source revision to the bytes eligible for this bundle."""
    head = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"],
                          check=True, capture_output=True, text=True).stdout.strip()
    if revision != head:
        fail("release source revision does not match HEAD")
    inputs = ["selfhost", "docker/init-db-roles.sql", "LICENSE", "THIRD-PARTY.md", "CHANGELOG.md", "SECURITY.md"]
    state = subprocess.run(["git", "-C", str(root), "status", "--porcelain", "--untracked-files=no", "--", *inputs],
                           check=True, capture_output=True, text=True).stdout
    if state.strip():
        fail("refusing modified tracked release inputs; release source must be committed")


def tracked_source_paths(root: Path) -> set[str]:
    """Return the repository index manifest used to define release source inputs."""
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--full-name", "-z"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        fail("could not read the tracked release source manifest")
    return {path.decode("utf-8") for path in result.stdout.split(b"\0") if path}


def require_tracked(path: Path, repository_root: Path, tracked_paths: set[str]) -> None:
    try:
        relative = path.resolve(strict=True).relative_to(repository_root.resolve(strict=True))
    except (OSError, ValueError):
        fail(f"release source is outside the repository: {path}")
    if relative.as_posix() not in tracked_paths:
        fail(f"refusing untracked release input: {relative.as_posix()}")


def copy_tree(
    source: Path,
    destination: Path,
    *,
    tracked_paths: set[str],
    repository_root: Path = ROOT,
) -> None:
    source_root = source.resolve(strict=True)
    destination_root = destination.resolve(strict=False)
    # Containers bind-mount these directories (config/ as the backend user); mkdir alone
    # would leave them owner-only under a private umask.
    destination_root.mkdir(parents=True, exist_ok=True)
    destination_root.chmod(0o755)
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
            require_tracked(path, repository_root, tracked_paths)
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
    require_committed_release_source(ROOT, args.source_revision)
    tracked_paths = tracked_source_paths(ROOT)
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
    if args.public_revision is not None and not REVISION_RE.fullmatch(args.public_revision):
        fail("--public-revision must be a full lowercase Git SHA")
    if not 0 <= args.source_date_epoch <= 0xFFFFFFFF:
        fail("--source-date-epoch must fit the gzip timestamp range (0 through 4294967295)")

    images = {
        "backend": args.backend_image,
        "frontend": args.frontend_image,
        "caddy": args.caddy_image,
    }
    image_inputs = dict(images)
    if args.backup_image is not None:
        image_inputs["backup"] = args.backup_image
    for name, image in image_inputs.items():
        if not IMAGE_RE.fullmatch(image):
            fail(f"{name} image must be an immutable name@sha256 reference")

    normalized_version = args.version.removeprefix("v")
    require_changelog(ROOT / "CHANGELOG.md", normalized_version)
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
        # mkdir honours the caller's umask; Compose bind-mounts selfhost/ into containers
        # that run as their image's own user (config-guard as the postgres uid), so the
        # directories must be world-searchable whatever umask built the archive.
        bundle.mkdir(mode=0o755)
        bundle.chmod(0o755)
        (bundle / "selfhost").mkdir(mode=0o755)
        (bundle / "selfhost").chmod(0o755)
        copy_tree(SELFHOST / "caddy", bundle / "selfhost" / "caddy", tracked_paths=tracked_paths)
        copy_tree(SELFHOST / "config", bundle / "selfhost" / "config", tracked_paths=tracked_paths)
        copy_tree(SELFHOST / "docs", bundle / "selfhost" / "docs", tracked_paths=tracked_paths)
        copy_tree(SELFHOST / "monitoring", bundle / "selfhost" / "monitoring", tracked_paths=tracked_paths)
        copy_tree(SELFHOST / "overlays", bundle / "selfhost" / "overlays", tracked_paths=tracked_paths)
        if args.backup_image is not None:
            pin_backup_image(bundle / "selfhost" / "overlays" / "backups.yml", args.backup_image)

        root_files = [
            ".env.example",
            ".gitignore",
            "Caddyfile.split",
            "Caddyfile.split.local",
            "Caddyfile.split.tls",
            "README.md",
            "backend-entrypoint.sh",
            "backup-entrypoint.sh",
            "backup-prune-hook.sh",
            "ca-export.sh",
            "cert-init.sh",
            "chronicle",
            "release-signing.pub",
            "chronicle_ops/__init__.py",
            "chronicle_ops/dump.py",
            "chronicle_ops/restore.py",
            "chronicle_ops/__main__.py",
            "chronicle_ops/adopt.py",
            "chronicle_ops/common.py",
            "chronicle_ops/receipts.py",
            "chronicle_ops/reconcile.py",
            "chronicle_ops/release.py",
            "chronicle_ops/upgrade.py",
            "chronicle_ops/verify.py",
            "db-init.sh",
            "docker-compose.yml",
            "guard-config.sh",
            "network-policy.sh",
            "network-subnet.py",
            "init-tde.sh",
            "restore.sh",
            "restore-continuity-digest.sql",
            "restore-continuity.version",
            "restore-restrictions-schema.sql",
            "restore-authorities-schema.sql",
            "restore-restrictions-containment.sql",
            "rotate-secret.sh",
            "upgrade.sh",
            "verify-config.sh",
        ]
        for name in root_files:
            source = SELFHOST / name
            if not source.is_file() or source.is_symlink():
                fail(f"required bundle input is missing or unsafe: {source}")
            require_tracked(source, ROOT, tracked_paths)
            target = bundle / "selfhost" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.parent.chmod(0o755)
            shutil.copyfile(source, target)
            if name == ".env.example":
                # A self-hoster's documented `cp .env.example .env` must produce a private
                # secret file without relying on a favorable shell umask or an extra chmod.
                target.chmod(0o600)
            else:
                target.chmod(0o755 if os.access(source, os.X_OK) else 0o644)

        # backups holds dumps, so it stays private; tls must be traversable by the
        # unprivileged config-guard/cert-init containers (cert-init locks key.pem down).
        (bundle / "selfhost" / "backups").mkdir(mode=0o700)
        (bundle / "selfhost" / "tls").mkdir(mode=0o755)
        (bundle / "selfhost" / "tls").chmod(0o755)

        docker_dir = bundle / "docker"
        docker_dir.mkdir(mode=0o755)
        docker_dir.chmod(0o755)
        role_sql = ROOT / "docker" / "init-db-roles.sql"
        require_tracked(role_sql, ROOT, tracked_paths)
        shutil.copyfile(role_sql, docker_dir / role_sql.name)
        (docker_dir / role_sql.name).chmod(0o644)
        # Operators read release notes and the vulnerability-reporting policy offline.
        for name in ("LICENSE", "THIRD-PARTY.md", "CHANGELOG.md", "SECURITY.md"):
            source = ROOT / name
            require_tracked(source, ROOT, tracked_paths)
            shutil.copyfile(source, bundle / name)
            (bundle / name).chmod(0o644)

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
            **({"public_revision": args.public_revision} if args.public_revision else {}),
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
