"""Run the literal incident-console JavaScript against deterministic queue pages."""

from pathlib import Path
import subprocess
import unittest


class BlockConsoleTest(unittest.TestCase):
    def test_pagination_selection_and_read_only_generation(self):
        script = Path(__file__).with_name('block_console.test.cjs')
        result = subprocess.run(['node', '--test', str(script)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
