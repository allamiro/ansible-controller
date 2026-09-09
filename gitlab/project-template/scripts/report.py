"""Publish one aggregate deployment result; never copy secret-bearing logs."""
import sys
from pathlib import Path
from xml.etree import ElementTree as ET


def write_report(rc, directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    failed = rc != 0
    suite = ET.Element('testsuite', name='Ansible deployment', tests='1',
                       failures=str(int(failed)), errors='0')
    case = ET.SubElement(suite, 'testcase', classname='automation',
                         name='Deployment and result transfer')
    message = (f'Deployment channel returned exit code {rc}. '
               'Inspect the restricted job trace and mesh-artifacts for details.')
    if failed:
        ET.SubElement(case, 'failure', message='Deployment or result transfer failed').text = message
    ET.ElementTree(suite).write(directory / 'deployment.xml', encoding='utf-8', xml_declaration=True)
    status = 'FAILED' if failed else 'SUCCEEDED'
    (directory / 'summary.html').write_text(
        '<!doctype html><html lang="en"><meta charset="utf-8">'
        '<title>Ansible deployment result</title><body>'
        f'<h1>Deployment {status}</h1><p>{message}</p>'
        '<p>This is one aggregate execution/transfer check, not a per-host task report.</p>'
        '</body></html>', encoding='utf-8')


if __name__ == '__main__':
    rc = int(sys.argv[1])
    if not 0 <= rc <= 255:
        raise SystemExit('Expected a shell exit code between 0 and 255')
    write_report(rc, 'reports')
