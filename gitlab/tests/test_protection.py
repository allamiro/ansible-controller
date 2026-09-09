"""Paid deployment policy provisioning, including fail-closed error handling."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock
from urllib.error import HTTPError

spec = importlib.util.spec_from_file_location('protection', Path(__file__).parents[1] / 'protect-environments.py')
protection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(protection)


class ProtectionTests(unittest.TestCase):
    def setUp(self):
        self.policy = {'deploy_access_levels': [{'group_id': 10, 'access_level': 40}],
                       'approval_rules': [{'group_id': 20, 'required_approvals': 2}]}

    def test_matching_policy_is_preserved(self):
        api = Mock(return_value=self.policy)
        protection.ensure(api, 'group/project', 'prod-mesh', 10, 20, 2)
        api.assert_called_once_with('GET', '/projects/group%2Fproject/protected_environments/prod-mesh')

    def test_missing_policy_is_created_and_read_back(self):
        api = Mock(side_effect=[HTTPError('', 404, '', {}, None), {}, self.policy])
        protection.ensure(api, 'group/project', 'prod-mesh', 10, 20, 2)
        self.assertEqual([c.args[0] for c in api.call_args_list], ['GET', 'POST', 'GET'])
        self.assertEqual(api.call_args_list[1].args[2]['approval_rules'],
                         [{'group_id': 20, 'required_approvals': 2}])

    def test_ce_or_permission_error_never_falls_back(self):
        api = Mock(side_effect=HTTPError('', 403, '', {}, None))
        with self.assertRaises(HTTPError):
            protection.ensure(api, 'group/project', 'prod-mesh', 10, 20, 2)
        self.assertEqual(api.call_count, 1)

    def test_drift_never_removes_protection(self):
        self.policy['deploy_access_levels'].append({'access_level': 30})
        api = Mock(return_value=self.policy)
        with self.assertRaisesRegex(ValueError, 'No protection was removed'):
            protection.ensure(api, 'group/project', 'prod-mesh', 10, 20, 2)
        self.assertEqual(api.call_count, 1)
