import importlib.util
import tempfile
import unittest
from pathlib import Path
from xml.etree import ElementTree as ET

spec = importlib.util.spec_from_file_location('report', Path(__file__).resolve().parents[1] / 'scripts/report.py')
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class ReportTests(unittest.TestCase):
    def test_success_and_failures(self):
        for rc in (0, 2, 4, 124, 255):
            with self.subTest(rc=rc), tempfile.TemporaryDirectory() as tmp:
                report.write_report(rc, tmp)
                root = ET.parse(Path(tmp) / 'deployment.xml').getroot()
                self.assertEqual(root.attrib['failures'], str(int(rc != 0)))
                self.assertEqual(len(root.findall('testcase')), 1)
                self.assertEqual(root.find('testcase/failure') is not None, rc != 0)
                html = (Path(tmp) / 'summary.html').read_text()
                self.assertIn('FAILED' if rc else 'SUCCEEDED', html)
                self.assertNotIn('<script', html)

class WrapperTests(unittest.TestCase):
    def test_preserves_execution_and_report_failures(self):
        import shutil
        import subprocess
        source = Path(__file__).resolve().parents[1] / 'scripts'
        for execution_rc, break_report, expected in ((0, False, 0), (4, False, 4), (0, True, 2), (124, True, 124)):
            with self.subTest(execution_rc=execution_rc, break_report=break_report), tempfile.TemporaryDirectory() as tmp:
                scripts = Path(tmp) / 'scripts'
                scripts.mkdir()
                shutil.copy(source / 'deploy.sh', scripts)
                shutil.copy(source / 'report.py', scripts)
                (scripts / 'ctl-ci.sh').write_text(f'exit {execution_rc}\n')
                if break_report:
                    (scripts / 'report.py').write_text('raise SystemExit(1)\n')
                result = subprocess.run(['bash', 'scripts/deploy.sh'], cwd=tmp, capture_output=True)
                self.assertEqual(result.returncode, expected)


if __name__ == "__main__":
    unittest.main()
