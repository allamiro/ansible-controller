#!/usr/bin/env python3
"""Provision and verify paid GitLab deployment gates; never weaken existing policy."""
import argparse
import json
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request


def matches(actual, deploy_group, approver_group, approvals):
    deploy = actual.get('deploy_access_levels', [])
    rules = actual.get('approval_rules', [])
    return (len(deploy) == 1 and deploy[0].get('group_id') == deploy_group
            and not deploy[0].get('user_id') and deploy[0].get('access_level') in (None, 40)
            and deploy[0].get('group_inheritance_type', 0) == 0
            and len(rules) == 1 and rules[0].get('group_id') == approver_group
            and not rules[0].get('user_id') and not rules[0].get('access_level')
            and rules[0].get('group_inheritance_type', 0) == 0
            and rules[0].get('required_approvals') == approvals)


def ensure(api, project, environment, deploy_group, approver_group, approvals):
    base = '/projects/' + urllib.parse.quote(project, safe='') + '/protected_environments'
    path = base + '/' + urllib.parse.quote(environment, safe='')
    try:
        actual = api('GET', path)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        api('POST', base, {'name': environment,
            'deploy_access_levels': [{'group_id': deploy_group}],
            'approval_rules': [{'group_id': approver_group, 'required_approvals': approvals}]})
        actual = api('GET', path)
    if not matches(actual, deploy_group, approver_group, approvals):
        raise ValueError(f'{environment}: existing deployment policy differs; reconcile it in GitLab. No protection was removed.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('url')
    parser.add_argument('project')
    parser.add_argument('--token-file', type=Path, default=Path('gitlab/.gitlab-state/pat'))
    parser.add_argument('--deploy-group', type=int, required=True)
    parser.add_argument('--approver-group', type=int, required=True)
    parser.add_argument('--required-approvals', type=int, default=1)
    parser.add_argument('--environment', action='append', required=True)
    args = parser.parse_args()
    if min(args.deploy_group, args.approver_group, args.required_approvals) < 1:
        parser.error('group IDs and required approvals must be positive')
    token = args.token_file.read_text().strip()

    def api(method, path, payload=None):
        request = urllib.request.Request(args.url.rstrip('/') + '/api/v4' + path,
            method=method, data=json.dumps(payload).encode() if payload is not None else None,
            headers={'PRIVATE-TOKEN': token, 'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    for environment in args.environment:
        ensure(api, args.project, environment, args.deploy_group,
               args.approver_group, args.required_approvals)
        print(f'{environment}: deployment and approval groups verified')


if __name__ == '__main__':
    try:
        main()
    except urllib.error.HTTPError as error:
        print(f'Deployment protection API returned HTTP {error.code}. Premium/Ultimate, '
              'CI/CD enabled, and project administration permission are required; '
              'no unprotected fallback was applied.', file=sys.stderr)
        sys.exit(2)
    except (ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
