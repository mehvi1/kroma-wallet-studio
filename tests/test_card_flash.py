import base64
import io
import json
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import Mock, patch

import kroma_backend as backend
import kroma_wallet as wallet


TEST_CARD_ID = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"

PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


class CardFlashTests(unittest.TestCase):
    def test_cache_removal_moves_link_and_required_companion_payload(self) -> None:
        successful = {
            "exitCode": 0,
            "targetGatePassed": True,
            "operation": {"ok": True},
        }
        with (
            patch.object(wallet, "native", return_value=successful),
            patch.object(wallet, "run_json", return_value={"exitCode": 0, "ok": True}) as transfer,
        ):
            result = wallet.remove_files(
                "device", "/protected/card.cache", ["FrontFace"], retries=1
            )

        self.assertTrue(result)
        command = transfer.call_args.args[0]
        self.assertEqual(len(command), 6)
        self.assertIn("/airlift-link-", command[4])
        self.assertTrue(command[5].endswith("/removed-0"))

    def test_flash_writes_pdf_and_removes_rendered_cache(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            image_path = Path(temporary) / "card.png"
            image_path.write_bytes(PNG_1X1)
            write_file = Mock(return_value=True)
            remove_files = Mock(return_value=True)

            with (
                patch.object(backend, "write_file", write_file),
                patch.object(backend, "write_files_batch", Mock(return_value=False)),
                patch.object(backend, "remove_files", remove_files),
                redirect_stdout(io.StringIO()),
            ):
                result = backend.cmd_flash("device", TEST_CARD_ID, str(image_path))

        self.assertTrue(result)

        writes = [call.args for call in write_file.call_args_list]
        pass_assets = {
            leaf: payload
            for _, target, leaf, payload in writes
            if target.endswith(".pkpass")
        }
        self.assertEqual(
            set(pass_assets),
            {
                "cardBackgroundCombined@3x.png",
                "cardBackgroundCombined@2x.png",
                "cardBackgroundCombined.pdf",
            },
        )
        self.assertTrue(pass_assets["cardBackgroundCombined.pdf"].startswith(b"%PDF-"))

        removals = [call.args for call in remove_files.call_args_list]
        for extension in (".cache", ".pkcache"):
            self.assertIn(("device", f"/var/mobile/Library/Passes/Cards/{TEST_CARD_ID}{extension}", list(backend.CACHE_FILES)), removals)

    def test_flash_fails_when_wallet_cache_cannot_be_removed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            image_path = Path(temporary) / "card.png"
            image_path.write_bytes(PNG_1X1)
            output = io.StringIO()
            with (
                patch.object(backend, "write_files_batch", return_value=True),
                patch.object(backend, "remove_files", side_effect=[True, False]),
                redirect_stdout(output),
            ):
                result = backend.cmd_flash("device", TEST_CARD_ID, str(image_path))
        messages = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertFalse(result)
        self.assertEqual(messages[-1]["type"], "error")

    def test_flash_reports_failure_when_an_asset_write_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            image_path = Path(temporary) / "card.png"
            image_path.write_bytes(PNG_1X1)
            write_file = Mock(
                side_effect=[True, True, False, True, True, True, True, True, True]
            )
            output = io.StringIO()

            with (
                patch.object(backend, "write_files_batch", Mock(return_value=False)),
                patch.object(backend, "write_file", write_file),
                patch.object(backend, "remove_files", Mock(return_value=True)),
                redirect_stdout(output),
            ):
                result = backend.cmd_flash("device", TEST_CARD_ID, str(image_path))

        messages = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertFalse(result)
        self.assertEqual(messages[-1]["type"], "error")
        self.assertFalse(any(message["type"] == "success" for message in messages))

    def test_flash_streams_per_file_progress_and_finishes_at_total(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            image_path = Path(temporary) / "card.png"
            image_path.write_bytes(PNG_1X1)
            output = io.StringIO()

            def batch(_udid, _target, files, retries=3, progress_callback=None):
                self.assertEqual(retries, 3)
                self.assertIsNotNone(progress_callback)
                for index, (leaf, _payload) in enumerate(files, 1):
                    progress_callback({
                        "type": "atc_progress",
                        "index": index,
                        "total": len(files),
                        "leaf": leaf,
                    })
                return True

            with (
                patch.object(backend, "write_files_batch", side_effect=batch),
                patch.object(backend, "remove_files", return_value=True),
                redirect_stdout(output),
            ):
                result = backend.cmd_flash("device", TEST_CARD_ID, str(image_path))

        messages = [json.loads(line) for line in output.getvalue().splitlines()]
        written = [
            message for message in messages
            if message.get("message", "").startswith("Writing cardBackground")
        ]
        self.assertTrue(result)
        self.assertEqual([message["step"] for message in written], [1, 2, 3])
        self.assertTrue(all(message["total"] == 5 for message in written))
        self.assertEqual(messages[-1]["type"], "success")
        self.assertEqual(messages[-1]["step"], messages[-1]["total"])

    def test_flash_fallback_emits_per_file_progress(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            image_path = Path(temporary) / "card.png"
            image_path.write_bytes(PNG_1X1)
            output = io.StringIO()
            with (
                patch.object(backend, "write_files_batch", return_value=False),
                patch.object(backend, "write_file", return_value=True),
                patch.object(backend, "remove_files", return_value=True),
                redirect_stdout(output),
            ):
                result = backend.cmd_flash("device", TEST_CARD_ID, str(image_path))

        messages = [json.loads(line) for line in output.getvalue().splitlines()]
        fallback = [
            message for message in messages
            if message.get("message", "").startswith("[Fallback] Writing")
        ]
        self.assertTrue(result)
        self.assertEqual(len(fallback), 3)
        self.assertEqual([message["step"] for message in fallback], [1, 2, 3])
        self.assertTrue(all(message["total"] == 5 for message in fallback))
        self.assertEqual(messages[-1]["step"], 5)
        self.assertEqual(messages[-1]["total"], 5)

    def test_flash_reports_failure_when_pdf_conversion_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            image_path = Path(temporary) / "card.png"
            image_path.write_bytes(PNG_1X1)
            write_file = Mock(return_value=True)
            output = io.StringIO()

            with (
                patch.object(backend, "write_file", write_file),
                patch.object(
                    backend,
                    "build_card_assets",
                    side_effect=subprocess.CalledProcessError(1, ["sips"]),
                ),
                redirect_stdout(output),
            ):
                result = backend.cmd_flash("device", TEST_CARD_ID, str(image_path))

        messages = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertFalse(result)
        self.assertEqual(messages[-1]["type"], "error")
        write_file.assert_not_called()


if __name__ == "__main__":
    unittest.main()
