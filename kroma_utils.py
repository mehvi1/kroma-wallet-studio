"""Local device discovery and private card-reference storage for Kroma."""
from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

CARD_ID_PATTERN = re.compile(r"[-A-Za-z0-9_+=]{20,64}\Z")
CARDS_STORE_PATH = (
    Path.home() / "Library" / "Application Support" / "Kroma" / "cards.json"
)


def valid_card_id(value: str) -> bool:
    """Accept only a single opaque Wallet reference, never a path."""
    return bool(CARD_ID_PATTERN.fullmatch(value))


def load_saved_cards() -> list[str]:
    """Load only well-formed local card references."""
    try:
        data = json.loads(CARDS_STORE_PATH.read_text("utf-8"))
    except (OSError, ValueError, TypeError):
        return []
    if not isinstance(data, list):
        return []
    return [item for item in data if isinstance(item, str) and valid_card_id(item)]


def save_cards(cards: list[str]) -> None:
    """Atomically save unique references in owner-only files/directories."""
    unique = list(
        dict.fromkeys(
            item for item in cards if isinstance(item, str) and valid_card_id(item)
        )
    )
    folder = CARDS_STORE_PATH.parent
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(folder, 0o700)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=folder,
        prefix="cards-",
        suffix=".tmp",
        delete=False,
    ) as handle:
        temporary = Path(handle.name)
        os.chmod(temporary, 0o600)
        json.dump(unique, handle, indent=2)
        handle.flush()
        os.fsync(handle.fileno())
    temporary.replace(CARDS_STORE_PATH)
    os.chmod(CARDS_STORE_PATH, 0o600)


def find_device_helper() -> str | None:
    """Find the bundled device helper in a build or development checkout."""
    root = Path(__file__).resolve().parent
    for candidate in (root / "bin" / "device_helper", root / "build" / "device_helper"):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def list_devices() -> list[dict]:
    """Enumerate paired devices reachable over USB or Wi-Fi pairing."""
    helper = find_device_helper()
    if not helper:
        return []
    try:
        output = subprocess.check_output(
            [helper, "list"], text=True, stderr=subprocess.DEVNULL, timeout=30
        )
    except (OSError, subprocess.SubprocessError):
        return []

    for line in reversed(output.splitlines()):
        try:
            devices = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(devices, list):
            return [item for item in devices if isinstance(item, dict)]
    return []


def format_device(device: dict) -> dict:
    product = device.get("product")
    has_product = bool(product and product != "Unknown")
    if device.get("name"):
        name = device["name"]
    elif str(product or "").startswith("iPhone"):
        name = "iPhone"
    else:
        name = "Apple Device" if has_product else "Locked / Unpaired Device"

    return {
        "udid": device["udid"],
        "name": name,
        "version": device.get("version") or ("Unknown" if has_product else ""),
        "product": product or "",
        "language": device.get("language") or "en",
        "locale": device.get("locale") or "",
        "bold_text": device.get("bold_text"),
        "connected": True,
    }


def get_all_connected_devices() -> list[dict]:
    raw = [item for item in list_devices() if item.get("udid")]
    iphones = [item for item in raw if str(item.get("product", "")).startswith("iPhone")]
    paired = [item for item in raw if item.get("product") and item not in iphones]
    unpaired = [item for item in raw if not item.get("product")]
    return [format_device(item) for item in iphones + paired + unpaired]


def get_connected_device(target_udid: str | None = None) -> dict | None:
    devices = get_all_connected_devices()
    if target_udid:
        return next((item for item in devices if item["udid"] == target_udid), None)
    return next(
        (item for item in devices if item.get("product")),
        devices[0] if devices else None,
    )
