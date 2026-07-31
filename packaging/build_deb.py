#!/usr/bin/env python3
from __future__ import annotations

import argparse
import io
import shutil
import tarfile
import tempfile
from pathlib import Path
from typing import Optional


PROJECT_ROOT = Path(__file__).resolve().parent.parent
PACKAGE_NAME = "alrotek-gateway-installer"
INSTALL_ROOT = Path("opt/alrotek/gateway-installer")
VERSION_FILE = PROJECT_ROOT / "VERSION"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Construye el paquete Debian de Alrotek Gateway Installer."
    )
    parser.add_argument(
        "--version",
        help="Sobrescribe la versión guardada en el archivo VERSION.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=PROJECT_ROOT / "dist",
        help="Directorio donde se guardará el .deb.",
    )
    return parser.parse_args()


def validate_version(version: str) -> None:
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+:~-")
    if not version or any(character not in allowed for character in version):
        raise ValueError(f"Versión inválida: {version!r}")


def resolve_version(override: Optional[str]) -> str:
    if override:
        version = override.strip()
    else:
        try:
            version = VERSION_FILE.read_text(encoding="utf-8").strip()
        except FileNotFoundError as error:
            raise FileNotFoundError(
                f"No se encontró el archivo de versión: {VERSION_FILE}"
            ) from error

    validate_version(version)
    return version


def install_file(source: Path, destination: Path, mode: int) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(mode)


def prepare_package_tree(root: Path, version: str) -> None:
    application_root = root / INSTALL_ROOT

    install_file(
        PROJECT_ROOT / "installer_gui.py",
        application_root / "installer_gui.py",
        0o755,
    )
    install_file(
        PROJECT_ROOT / ".env.example",
        application_root / ".env.example",
        0o644,
    )
    install_file(
        PROJECT_ROOT / "README.md",
        application_root / "README.md",
        0o644,
    )
    packaged_version = application_root / "VERSION"
    packaged_version.write_text(f"{version}\n", encoding="utf-8")
    packaged_version.chmod(0o644)

    for relative_path in (
        "scripts/common.sh",
        "scripts/install.sh",
        "scripts/update.sh",
        "scripts/uninstall.sh",
        "templates/gateway.desktop",
        "templates/alrotek-gateway.service",
        "templates/lightdm-autologin.conf",
    ):
        mode = 0o755 if relative_path.endswith(".sh") else 0o644
        install_file(
            PROJECT_ROOT / relative_path,
            application_root / relative_path,
            mode,
        )

    install_file(
        PROJECT_ROOT / "packaging" / "alrotek-gateway-installer",
        root / "usr/bin/alrotek-gateway-installer",
        0o755,
    )
    install_file(
        PROJECT_ROOT / "packaging" / "alrotek-gateway-installer.desktop",
        root / "usr/share/applications/alrotek-gateway-installer.desktop",
        0o644,
    )

    control_dir = root / "DEBIAN"
    control_dir.mkdir(parents=True, exist_ok=True)
    control = f"""Package: {PACKAGE_NAME}
Version: {version}
Section: admin
Priority: optional
Architecture: all
Depends: python3 (>= 3.9), python3-tk, git, sudo, pkexec | policykit-1
Maintainer: Alrotek
Description: Instalador gráfico de Alrotek Gateway
 Instala, repara, actualiza y desinstala Gateway en equipos Linux.
"""
    (control_dir / "control").write_text(control, encoding="utf-8")
    (control_dir / "control").chmod(0o644)


def normalized_filter(info: tarfile.TarInfo) -> tarfile.TarInfo:
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = 0
    return info


def create_tar_gz(
    output: Path,
    source: Path,
    entries: list[tuple[Path, str]],
) -> None:
    with tarfile.open(output, "w:gz", format=tarfile.GNU_FORMAT) as archive:
        for path, archive_name in entries:
            archive.add(
                path,
                arcname=archive_name,
                recursive=True,
                filter=normalized_filter,
            )


def write_ar_member(output: io.BufferedWriter, name: str, data: bytes) -> None:
    normalized_name = f"{name}/"
    if len(normalized_name) > 16:
        raise ValueError(f"Nombre demasiado largo para ar: {name}")

    header = (
        normalized_name.ljust(16)
        + "0".ljust(12)
        + "0".ljust(6)
        + "0".ljust(6)
        + "100644".ljust(8)
        + str(len(data)).ljust(10)
        + "`\n"
    ).encode("ascii")
    if len(header) != 60:
        raise AssertionError("Encabezado ar inválido")

    output.write(header)
    output.write(data)
    if len(data) % 2:
        output.write(b"\n")


def create_deb(output: Path, control_archive: Path, data_archive: Path) -> None:
    with output.open("wb") as package:
        package.write(b"!<arch>\n")
        write_ar_member(package, "debian-binary", b"2.0\n")
        write_ar_member(package, "control.tar.gz", control_archive.read_bytes())
        write_ar_member(package, "data.tar.gz", data_archive.read_bytes())


def main() -> None:
    args = parse_args()
    version = resolve_version(args.version)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    output = args.output_dir / f"{PACKAGE_NAME}_{version}_all.deb"

    with tempfile.TemporaryDirectory(prefix="gateway-installer-deb-") as temporary:
        temporary_path = Path(temporary)
        package_root = temporary_path / "root"
        package_root.mkdir()
        prepare_package_tree(package_root, version)

        control_archive = temporary_path / "control.tar.gz"
        data_archive = temporary_path / "data.tar.gz"
        create_tar_gz(
            control_archive,
            package_root / "DEBIAN",
            [(package_root / "DEBIAN" / "control", "control")],
        )

        data_entries = [
            (child, str(child.relative_to(package_root)))
            for child in sorted(package_root.iterdir())
            if child.name != "DEBIAN"
        ]
        create_tar_gz(data_archive, package_root, data_entries)
        create_deb(output, control_archive, data_archive)

    print(output)


if __name__ == "__main__":
    main()
