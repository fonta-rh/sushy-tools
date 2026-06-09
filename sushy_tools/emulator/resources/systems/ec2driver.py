#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

import uuid as uuidlib

from sushy_tools.emulator.resources.systems.base import AbstractSystemsDriver
from sushy_tools import error

EC2_UUID_NAMESPACE = uuidlib.UUID('a4e6b3c1-2f8d-4e5a-9c1b-7d3f6e8a2b0c')

try:
    import boto3
except ImportError:
    boto3 = None

is_loaded = bool(boto3)

EC2_POWER_STATE_MAP = {
    'running': 'On',
    'pending': 'On',
    'stopped': 'Off',
    'stopping': 'Off',
    'shutting-down': 'Off',
}


class Ec2Driver(AbstractSystemsDriver):
    """EC2 bare metal systems driver"""

    @classmethod
    def initialize(cls, config, logger, *args, **kwargs):
        cls._config = config
        cls._logger = logger

        region = config.get('SUSHY_EMULATOR_AWS_REGION', 'us-east-1')
        client_kwargs = {'region_name': region}

        access_key = config.get('SUSHY_EMULATOR_AWS_ACCESS_KEY')
        secret_key = config.get('SUSHY_EMULATOR_AWS_SECRET_KEY')
        if access_key and secret_key:
            client_kwargs['aws_access_key_id'] = access_key
            client_kwargs['aws_secret_access_key'] = secret_key

        cls._ec2 = boto3.client('ec2', **client_kwargs)

        cls._filter_tag = config.get('SUSHY_EMULATOR_AWS_FILTER_TAG')
        cls._filter_value = config.get('SUSHY_EMULATOR_AWS_FILTER_VALUE')

        return cls

    def _get_tag_filters(self):
        if self._filter_tag and self._filter_value:
            return [{'Name': 'tag:%s' % self._filter_tag,
                     'Values': [self._filter_value]}]
        return None

    def _flatten_reservations(self, response):
        instances = []
        for reservation in response.get('Reservations', []):
            instances.extend(reservation.get('Instances', []))
        return instances

    def _get_name_tag(self, instance):
        for tag in instance.get('Tags', []):
            if tag['Key'] == 'Name':
                return tag['Value']
        return instance['InstanceId']

    def _get_instance(self, identity):
        filters = self._get_tag_filters()
        kwargs = {}
        if filters:
            kwargs['Filters'] = filters

        response = self._ec2.describe_instances(**kwargs)
        instances = self._flatten_reservations(response)

        for inst in instances:
            if inst['InstanceId'] == identity:
                return inst
            if self._get_name_tag(inst) == identity:
                return inst

        raise error.NotFound(
            'EC2 instance %s not found' % identity)

    @property
    def driver(self):
        return '<ec2>'

    @property
    def systems(self):
        filters = self._get_tag_filters()
        kwargs = {}
        if filters:
            kwargs['Filters'] = filters

        response = self._ec2.describe_instances(**kwargs)
        instances = self._flatten_reservations(response)
        return [inst['InstanceId'] for inst in instances]

    def uuid(self, identity):
        instance = self._get_instance(identity)
        return str(uuidlib.uuid5(EC2_UUID_NAMESPACE, instance['InstanceId']))

    def name(self, identity):
        instance = self._get_instance(identity)
        return self._get_name_tag(instance)

    def get_power_state(self, identity):
        instance = self._get_instance(identity)
        ec2_state = instance['State']['Name']

        redfish_state = EC2_POWER_STATE_MAP.get(ec2_state)
        if redfish_state is None:
            raise error.FishyError(
                'EC2 instance %s is in unsupported state: %s'
                % (identity, ec2_state))

        return redfish_state

    def set_power_state(self, identity, state):
        instance = self._get_instance(identity)
        instance_id = instance['InstanceId']
        ec2_state = instance['State']['Name']
        is_on = ec2_state in ('running', 'pending')

        if state in ('On', 'ForceOn'):
            if not is_on:
                self._ec2.start_instances(InstanceIds=[instance_id])

        elif state == 'ForceOff':
            if is_on:
                self._ec2.stop_instances(
                    InstanceIds=[instance_id], Force=True)

        elif state == 'GracefulShutdown':
            if is_on:
                self._ec2.stop_instances(
                    InstanceIds=[instance_id], Force=False)

        elif state in ('ForceRestart', 'GracefulRestart'):
            if is_on:
                self._ec2.reboot_instances(InstanceIds=[instance_id])

        elif state == 'Nmi':
            raise error.FishyError(
                'Nmi is not supported on EC2')

        else:
            raise error.FishyError(
                'Unknown ResetType "%s"' % state)

    def get_boot_device(self, identity):
        return 'Hdd'

    def set_boot_device(self, identity, boot_source):
        self._logger.warning(
            'set_boot_device is a no-op on EC2 (requested: %s)', boot_source)
