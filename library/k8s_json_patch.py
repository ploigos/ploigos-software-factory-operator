#!/usr/bin/python
# -*- coding: utf-8 -*-

# (c) 2018, Chris Houseknecht <@chouseknecht>
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

from __future__ import absolute_import, division, print_function

__metaclass__ = type


ANSIBLE_METADATA = {'metadata_version': '1.1',
                    'status': ['preview'],
                    'supported_by': 'community'}

DOCUMENTATION = '''

module: k8s_resource

short_description: Manage Kubernetes (k8s) resources

version_added: "2.9"

author:
- "Johnathan Kupferer"

description:
- Use the OpenShift Python client to patch K8s resources.
- Authenticate using either a config file, certificates, password or token.
- Supports check mode.

extends_documentation_fragment:
- k8s_auth_options
- k8s_name_options

options:
  patch:
    description:
    - The patch must be a valid JSON patch list with the following adjustments to support idempotent patching of kubernetes resources.
    - C(remove) operations are silently ignored when the path is not found in the resource definition.
    - C(add) operations are silently ignored when the path is found with the specified value.
    - C(add) operations may specify C(replace=false) to produce an error if the path is set and is different from value.
    - C(test) operations may specify C(state) to define how the test value should be evaluated.
    - Test C(state=equal) means the path value must equal the specified value, the default behavior.
    - Test C(state=unequal) means the path value must not equal the specified value.
    - Test C(state=present) means the path must be present with any value
    - Test C(state=absent) means the path must not be found in the resource.
    - C(test) operations may specify C(operations) as a list of operations to conditionally process if the test condition is true.
    - If a test specifies C(operations) then a failed test does not produce an error.
    - List indexes may be given with a simple key query of the form C([?KEY=='VALUE']) to support for various kubernetes use cases where lists have name keys.
    - The list index query resolves to C(-) (end of list) if it fails to match when adding a value to a list.
    type: list
    version_added: "2.9"

requirements:
  - "python >= 2.7"
  - "openshift >= 0.6"
  - "PyYAML >= 3.11"
'''

EXAMPLES = '''
- name: Set key in ConfigMap if not set
  k8s_json_patch:
    api_version: v1
    kind: ConfigMap
    name: myconf
    patch:
    - op: add
      path: /data/somekey
      value: somevalue

- name: Set ENV_LEVEL environment variable in Deployment
  k8s_json_patch:
    api_version: apps/v1
    kind: Deployment
    name: myapp
    patch:
    - op: default
      path: /spec/template/spec/containers/[?name=='myapp']/env/[?name=='ENV_LEVEL']
      value:
        name: ENV_LEVEL
        value: dev
'''

RETURN = '''
result:
  description:
  - The resources created, deleted, patched, or found already in the configured state.
  returned: success
  type: complex
  contains:
    resource:
      description: The patched resource definition.
      returned: success
      type: complex
'''

import copy
import re
from distutils.version import LooseVersion

from ansible.module_utils.basic import missing_required_lib
from ansible.module_utils.k8s.common import AUTH_ARG_SPEC, COMMON_ARG_SPEC
from ansible.module_utils.k8s.common import KubernetesAnsibleModule

try:
    import yaml
    from openshift.dynamic.exceptions import \
        DynamicApiError, NotFoundError, ForbiddenError
except ImportError:
    # Exceptions handled in common
    pass

class JsonPatchFailException(Exception):
    pass

match_list_search = re.compile(r'\[\?(.*)=\'(.*)\'\]$')
match_num = re.compile(r'\d+$')

def resolve_path(obj, path):
    value = obj
    context = None
    key = None
    matched_path = []
    unmatched_path = copy.deepcopy(path)
    while unmatched_path:
        if not isinstance(value, (dict, list)):
            break
        key = unmatched_path.pop(0)
        context = value
        value = None
        if key == '-' and isinstance(context, list):
            unmatched_path.insert(0, str(len(context)))
            break

        if isinstance(context, dict):
            if key in context:
                matched_path.append(key)
                value = context[key]
                continue
            else:
                unmatched_path.insert(0, key)
                break

        if match_num.match(key):
            key = int(key)
            if key < len(context):
                matched_path.append(str(key))
                value = context[key]
                continue
            else:
                unmatched_path.insert(0, str(key))
                break

        list_search_match = match_list_search.match(key)
        if list_search_match:
            search_key = list_search_match.group(1)
            search_value = list_search_match.group(2)
            n = None
            for i, ci in enumerate(context):
                if isinstance(ci, dict) \
                and ci.get(search_key) == search_value:
                    n = i
                    value = ci
                    break
            if n != None:
                matched_path.append(str(n))
                key = n
                continue
            else:
                unmatched_path.insert(0, key)
                break

        raise JsonPatchFailException('Unable to match path dict key in list {0}'.format(path_from_list(path)))
    return value, context, key, matched_path, unmatched_path

def path_to_list(path):
    return [
        item.replace('~1', '/').replace('~0', '~') for item in path.split('/')[1:]
    ]

def path_from_list(path, last=None):
    if last:
        return '/' + '/'.join(path) + '/' + last
    else:
        return '/' + '/'.join(path)

def _process_patch_add(patch_operation, patched_obj, value, context, matched_path, unmatched_path):
    for item in unmatched_path[:0:-1]:
        if match_num.match(item):
            value = [value]
        else:
            match = match_list_search.match(item)
            if match:
                if not isinstance(value, dict):
                    raise JsonPatchFailException('Invalid placement of list query in path {0}'.format(patch_operation))
                value[match.group(1)] = match.group(2)
                value = [value]
            else:
                value = {item: value}

    if isinstance(context, dict):
        context[unmatched_path[0]] = copy.deepcopy(value)
        processed_path = path_from_list(matched_path, unmatched_path[0])
    else:
        if match_num.match(unmatched_path[0]):
            context.append(copy.deepcopy(value))
            processed_path = path_from_list(matched_path, '-')
        else:
            match = match_list_search.match(unmatched_path[0])
            if not match:
                raise JsonPatchFailException('Unable to add, invalid list index {0}'.format(patch_operation))
            if not isinstance(value, dict):
                raise JsonPatchFailException('Invalid placement of list query in path {0}'.format(patch_operation))
            value[match.group(1)] = match.group(2)
            context.append(copy.deepcopy(value))
            processed_path = path_from_list(matched_path, '-')

    return dict(op='add', path=processed_path, value=value)

def process_patch_add(patch_operation, patched_obj):
    path = path_to_list(patch_operation['path'])
    value = copy.deepcopy(patch_operation.get('value'))
    obj_value, context, key, matched_path, unmatched_path = resolve_path(patched_obj, path)
    if unmatched_path:
        return _process_patch_add(patch_operation, patched_obj, value, context, matched_path, unmatched_path)
    elif value == obj_value:
        # Already present with desired value, nothing to do
        return None
    elif patch_operation.get('replace', True):
        if isinstance(context, list) and key == len(context):
            context.append(value)
        else:
            context[key] = value
        processed_path = path_from_list(matched_path)
        return dict(op='replace', path=processed_path, value=value)
    else:
        raise JsonPatchFailException('Unable to add, path already exists {0}'.format(patch_operation))

def process_patch_copy(patch_operation, patched_obj):
    src_path = path_to_list(patch_operation['from'])
    dst_path = path_to_list(patch_operation['path'])
    src_value, src_context, src_key, src_matched_path, src_unmatched_path = resolve_path(patched_obj, src_path)
    dst_value, dst_context, dst_key, dst_matched_path, dst_unmatched_path = resolve_path(patched_obj, dst_path)
    if src_unmatched_path:
        raise JsonPatchFailException('Unable to copy, from path not found {0}'.format(patch_operation))
    elif src_value == dst_value:
        # Already present with desired value, nothing to do
        return None
    elif dst_unmatched_path:
        # Handle as add to resolve any queries in the destination
        return _process_patch_add(patch_operation, patched_obj, src_value, dst_context, dst_matched_path, dst_unmatched_path)
    else:
        dst_context[dst_key] = src_value
        src_processed_path = path_from_list(src_matched_path)
        dst_processed_path = path_from_list(dst_matched_path)
        return {'op': 'copy', 'path': dst_processed_path, 'from': src_processed_path}

def process_patch_move(patch_operation, patched_obj):
    src_path = path_to_list(patch_operation['from'])
    dst_path = path_to_list(patch_operation['path'])
    src_value, src_context, src_key, src_matched_path, src_unmatched_path = resolve_path(patched_obj, src_path)
    dst_value, dst_context, dst_key, dst_matched_path, dst_unmatched_path = resolve_path(patched_obj, dst_path)
    if src_unmatched_path:
        raise JsonPatchFailException('Unable to move, from path not found {0}'.format(patch_operation))
    elif dst_unmatched_path:
        # Handle as remove then add resolve any queries in the destination
        src_processed_path = path_from_list(src_matched_path)
        del src_context[src_key]
        return [
            dict(op='remove', path=src_processed_path),
            _process_patch_add(patch_operation, patched_obj, src_value, dst_context, dst_matched_path, dst_unmatched_path)
        ]
    else:
        dst_context[dst_key] = src_value
        del src_context[src_key]
        src_processed_path = path_from_list(src_matched_path)
        dst_processed_path = path_from_list(dst_matched_path)
        return {'op': 'copy', 'path': dst_processed_path, 'from': src_processed_path}

def process_patch_remove(patch_operation, patched_obj):
    path = path_to_list(patch_operation['path'])
    obj_value, context, key, matched_path, unmatched_path = resolve_path(patched_obj, path)
    if unmatched_path:
        return None
    else:
        del context[key]
        processed_path = path_from_list(matched_path)
        return dict(op='remove', path=processed_path)

def process_patch_replace(patch_operation, patched_obj):
    path = path_to_list(patch_operation['path'])
    value = copy.deepcopy(patch_operation.get('value'))
    obj_value, context, key, matched_path, unmatched_path = resolve_path(patched_obj, path)
    if unmatched_path:
        raise JsonPatchFailException('Unable to replace, path not found {0}'.format(patch_operation))
    elif value == obj_value:
        # Already present with desired value, nothing to do
        return None
    else:
        context[key] = value
        processed_path = path_from_list(matched_path)
        return dict(op='replace', path=processed_path, value=value)

def process_patch_test(patch_operation, patched_obj):
    path = path_to_list(patch_operation['path'])
    value = patch_operation.get('value')
    allowed_states = patch_operation.get('state', ['equal'])
    if not isinstance(allowed_states, list):
        allowed_states = [allowed_states]
    obj_value, context, key, matched_path, unmatched_path = resolve_path(patched_obj, path)
    if unmatched_path:
        if 'absent' in allowed_states:
            return None
        else:
            raise JsonPatchFailException('Test failed, path not found {0}'.format(patch_operation))
    elif 'equal' in allowed_states and value == obj_value:
        return dict(op='test', path=path_from_list(matched_path), value=value)
    elif 'present' in allowed_states:
        return None
    elif 'unequal' in allowed_states and value != obj_value:
        return None
    else:
        raise JsonPatchFailException('Test failed {0}'.format(patch_operation))

def process_patch(json_patch, existing):
    processed_patch = []
    patched_obj = copy.deepcopy(existing)
    patch_operations = copy.deepcopy(json_patch)

    while patch_operations:
        patch_operation = patch_operations.pop(0)

        op = patch_operation.get('op')
        if op == 'add':
            patch_operation = process_patch_add(patch_operation, patched_obj)
        elif op == 'copy':
            patch_operation = process_patch_copy(patch_operation, patched_obj)
        elif op == 'move':
            patch_operation = process_patch_move(patch_operation, patched_obj)
        elif op == 'remove':
            patch_operation = process_patch_remove(patch_operation, patched_obj)
        elif op == 'replace':
            patch_operation = process_patch_replace(patch_operation, patched_obj)
        elif op == 'test':
            test_operations = patch_operation.get('operations')
            test_path = patch_operation.get('path')
            try:
                patch_operation = process_patch_test(patch_operation, patched_obj)
                if test_operations:
                    # Set path for operations if unset
                    for operation in test_operations:
                        if 'path' not in operation:
                            operation['path'] = test_path
                    # Add test operations to the beginning of patch operations list
                    test_operations.extend(patch_operations)
                    patch_operations = test_operations
            except JsonPatchFailException:
                if test_operations == None:
                    raise
                else:
                    patch_operation = None
        else:
            raise JsonPatchFailException('No op in {0}'.format(patch_operation))

        if patch_operation:
            if isinstance(patch_operation, list):
                processed_patch.extend(patch_operation)
            else:
                processed_patch.append(patch_operation)

    return processed_patch, patched_obj

class KubernetesJsonPatchModule(KubernetesAnsibleModule):
    @property
    def argspec(self):
        argument_spec = copy.deepcopy(COMMON_ARG_SPEC)
        argument_spec.update(copy.deepcopy(AUTH_ARG_SPEC))
        argument_spec['patch'] = dict(
            type='list',
            default=[],
        )
        return argument_spec

    def __init__(self, *args, **kwargs):
        self.client = None

        KubernetesAnsibleModule.__init__(
            self, *args,
            supports_check_mode=True,
            **kwargs
        )

        self.kind = self.params.get('kind')
        self.api_version = self.params.get('api_version')
        self.name = self.params.get('name')
        self.namespace = self.params.get('namespace')
        self.patch = self.params.get('patch')

        if LooseVersion(self.openshift_version) < LooseVersion("0.6.2"):
            self.fail_json(msg=missing_required_lib("openshift >= 0.6.2"))

    def execute_module(self):
        self.client = self.get_api_client()
        resource = self.find_resource(self.kind, self.api_version, fail=True)
        params = dict(name = self.name)
        if self.namespace:
            params['namespace'] = self.namespace
        try:
            existing = resource.get(**params).to_dict()
        except (DynamicApiError, ForbiddenError, NotFoundError):
            self.fail_json(
                msg='Failed to retrieve requested object: {0}'.format(exc.body),
                error=exc.status, status=exc.status, reason=exc.reason
            )

        try:
            processed_patch, patched_obj = process_patch(self.patch, existing)
        except JsonPatchFailException as e:
            self.fail_json(
                msg='Failed processing json_patch: {0}'.format(e)
            )

        # If no changes in the processed patch, then just apply
        if not processed_patch:
            self.exit_json(changed=False, resource=existing)
        # For check mode, just return locally patched object
        if self.check_mode:
            self.exit_json(changed=True, resource=patched_obj, json_patch=processed_patch)
        try:
            k8s_obj = resource.patch(processed_patch, content_type='application/json-patch+json', **params).to_dict()
            self.exit_json(changed=True, resource=k8s_obj, json_patch=processed_patch)
        except DynamicApiError as exc:
            self.fail_json(
                msg="Failed to patch object: {0}".format(exc.body),
                error=exc.status, status=exc.status, reason=exc.reason
            )


def main():
    KubernetesJsonPatchModule().execute_module()

if __name__ == '__main__':
    main()
