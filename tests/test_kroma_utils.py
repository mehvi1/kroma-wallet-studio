import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import kroma_utils

VALID = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"

class KromaCardReferenceTests(unittest.TestCase):
    def test_rejects_path_like_or_private_references(self):
        for value in ("../" + VALID, "<private>", "short", "a" * 100):
            self.assertFalse(kroma_utils.valid_card_id(value))
        self.assertTrue(kroma_utils.valid_card_id(VALID))

    def test_saved_references_are_filtered_and_private(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "Application Support" / "Kroma" / "cards.json"
            with patch.object(kroma_utils, "CARDS_STORE_PATH", target):
                kroma_utils.save_cards([VALID, VALID, "../" + VALID])
                self.assertEqual(json.loads(target.read_text()), [VALID])
                self.assertEqual(target.stat().st_mode & 0o777, 0o600)
                self.assertEqual(target.parent.stat().st_mode & 0o777, 0o700)

if __name__ == "__main__":
    unittest.main()
