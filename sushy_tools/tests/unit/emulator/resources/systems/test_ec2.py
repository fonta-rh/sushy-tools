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
from unittest import mock

from oslotest import base

from sushy_tools.emulator.resources.systems import ec2driver
from sushy_tools import error


class Ec2DriverTestCase(base.BaseTestCase):

    INSTANCE_ID_1 = 'i-0abc123def456'
    INSTANCE_ID_2 = 'i-0def456abc789'
    NAME_1 = 'master-0'
    NAME_2 = 'master-1'

    def setUp(self):
        super().setUp()
        self.boto3_patcher = mock.patch('boto3.client', autospec=True)
        self.boto3_mock = self.boto3_patcher.start()
        self.ec2_client = self.boto3_mock.return_value

        config = {
            'SUSHY_EMULATOR_AWS_REGION': 'us-east-1',
        }
        test_driver_class = ec2driver.Ec2Driver.initialize(
            config, mock.MagicMock())
        self.test_driver = test_driver_class()

    def tearDown(self):
        self.boto3_patcher.stop()
        super().tearDown()

    def _make_instance(self, instance_id, name, state='running'):
        return {
            'InstanceId': instance_id,
            'Tags': [{'Key': 'Name', 'Value': name}],
            'State': {'Name': state}
        }

    def _make_describe_response(self, *instances):
        return {
            'Reservations': [{'Instances': list(instances)}]
        }

    def _make_empty_response(self):
        return {'Reservations': []}

    # --- module-level ---

    def test_is_loaded(self):
        self.assertTrue(ec2driver.is_loaded)

    # --- driver property ---

    def test_driver_property(self):
        self.assertEqual('<ec2>', self.test_driver.driver)

    # --- initialize ---

    def test_initialize_creates_ec2_client(self):
        self.boto3_mock.assert_called_with(
            'ec2', region_name='us-east-1')

    def test_initialize_with_credentials(self):
        self.boto3_mock.reset_mock()
        config = {
            'SUSHY_EMULATOR_AWS_REGION': 'eu-west-1',
            'SUSHY_EMULATOR_AWS_ACCESS_KEY': 'AKIAIOSFODNN7EXAMPLE',
            'SUSHY_EMULATOR_AWS_SECRET_KEY': 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
        }
        ec2driver.Ec2Driver.initialize(config, mock.MagicMock())
        self.boto3_mock.assert_called_once_with(
            'ec2',
            region_name='eu-west-1',
            aws_access_key_id='AKIAIOSFODNN7EXAMPLE',
            aws_secret_access_key='wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY')

    # --- systems property ---

    def test_systems(self):
        inst1 = self._make_instance(self.INSTANCE_ID_1, self.NAME_1)
        inst2 = self._make_instance(self.INSTANCE_ID_2, self.NAME_2)
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst1, inst2)

        systems = self.test_driver.systems

        self.assertEqual([self.INSTANCE_ID_1, self.INSTANCE_ID_2], systems)

    def test_systems_multiple_reservations(self):
        inst1 = self._make_instance(self.INSTANCE_ID_1, self.NAME_1)
        inst2 = self._make_instance(self.INSTANCE_ID_2, self.NAME_2)
        response = {
            'Reservations': [
                {'Instances': [inst1]},
                {'Instances': [inst2]},
            ]
        }
        self.ec2_client.describe_instances.return_value = response

        systems = self.test_driver.systems

        self.assertEqual([self.INSTANCE_ID_1, self.INSTANCE_ID_2], systems)

    def test_systems_with_tag_filter(self):
        self.boto3_mock.reset_mock()
        config = {
            'SUSHY_EMULATOR_AWS_REGION': 'us-east-1',
            'SUSHY_EMULATOR_AWS_FILTER_TAG': 'cluster',
            'SUSHY_EMULATOR_AWS_FILTER_VALUE': 'my-cluster',
        }
        test_driver_class = ec2driver.Ec2Driver.initialize(
            config, mock.MagicMock())
        test_driver = test_driver_class()

        inst1 = self._make_instance(self.INSTANCE_ID_1, self.NAME_1)
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst1)

        systems = test_driver.systems

        self.assertEqual([self.INSTANCE_ID_1], systems)
        self.ec2_client.describe_instances.assert_called_with(
            Filters=[{'Name': 'tag:cluster', 'Values': ['my-cluster']}])

    def test_systems_empty(self):
        self.ec2_client.describe_instances.return_value = \
            self._make_empty_response()

        systems = self.test_driver.systems

        self.assertEqual([], systems)

    # --- uuid ---

    def test_uuid_by_instance_id(self):
        inst1 = self._make_instance(self.INSTANCE_ID_1, self.NAME_1)
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst1)

        result = self.test_driver.uuid(self.INSTANCE_ID_1)
        expected = str(uuidlib.uuid5(ec2driver.EC2_UUID_NAMESPACE,
                                     self.INSTANCE_ID_1))
        self.assertEqual(expected, result)
        uuidlib.UUID(result)

    def test_uuid_by_name(self):
        inst1 = self._make_instance(self.INSTANCE_ID_1, self.NAME_1)
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst1)

        result = self.test_driver.uuid(self.NAME_1)
        expected = str(uuidlib.uuid5(ec2driver.EC2_UUID_NAMESPACE,
                                     self.INSTANCE_ID_1))
        self.assertEqual(expected, result)

    def test_uuid_not_found(self):
        self.ec2_client.describe_instances.return_value = \
            self._make_empty_response()

        self.assertRaises(error.NotFound,
                          self.test_driver.uuid, 'nonexistent')

    # --- name ---

    def test_name_by_instance_id(self):
        inst1 = self._make_instance(self.INSTANCE_ID_1, self.NAME_1)
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst1)

        name = self.test_driver.name(self.INSTANCE_ID_1)
        self.assertEqual(self.NAME_1, name)

    def test_name_not_found(self):
        self.ec2_client.describe_instances.return_value = \
            self._make_empty_response()

        self.assertRaises(error.NotFound,
                          self.test_driver.name, 'nonexistent')

    def test_name_no_name_tag(self):
        inst = {
            'InstanceId': self.INSTANCE_ID_1,
            'Tags': [{'Key': 'env', 'Value': 'prod'}],
            'State': {'Name': 'running'}
        }
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        name = self.test_driver.name(self.INSTANCE_ID_1)
        self.assertEqual(self.INSTANCE_ID_1, name)

    def test_name_no_tags(self):
        inst = {
            'InstanceId': self.INSTANCE_ID_1,
            'State': {'Name': 'running'}
        }
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        name = self.test_driver.name(self.INSTANCE_ID_1)
        self.assertEqual(self.INSTANCE_ID_1, name)

    # --- get_power_state ---

    def test_get_power_state_running(self):
        inst = self._make_instance(self.INSTANCE_ID_1, self.NAME_1, 'running')
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        state = self.test_driver.get_power_state(self.INSTANCE_ID_1)
        self.assertEqual('On', state)

    def test_get_power_state_stopped(self):
        inst = self._make_instance(self.INSTANCE_ID_1, self.NAME_1, 'stopped')
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        state = self.test_driver.get_power_state(self.INSTANCE_ID_1)
        self.assertEqual('Off', state)

    def test_get_power_state_stopping(self):
        inst = self._make_instance(self.INSTANCE_ID_1, self.NAME_1, 'stopping')
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        state = self.test_driver.get_power_state(self.INSTANCE_ID_1)
        self.assertEqual('Off', state)

    def test_get_power_state_pending(self):
        inst = self._make_instance(self.INSTANCE_ID_1, self.NAME_1, 'pending')
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        state = self.test_driver.get_power_state(self.INSTANCE_ID_1)
        self.assertEqual('On', state)

    def test_get_power_state_shutting_down(self):
        inst = self._make_instance(self.INSTANCE_ID_1, self.NAME_1,
                                   'shutting-down')
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        state = self.test_driver.get_power_state(self.INSTANCE_ID_1)
        self.assertEqual('Off', state)

    def test_get_power_state_terminated(self):
        inst = self._make_instance(self.INSTANCE_ID_1, self.NAME_1,
                                   'terminated')
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        self.assertRaises(error.FishyError,
                          self.test_driver.get_power_state,
                          self.INSTANCE_ID_1)

    # --- set_power_state ---

    def test_set_power_state_on(self):
        inst = self._make_instance(self.INSTANCE_ID_1, self.NAME_1, 'stopped')
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        self.test_driver.set_power_state(self.INSTANCE_ID_1, 'On')

        self.ec2_client.start_instances.assert_called_once_with(
            InstanceIds=[self.INSTANCE_ID_1])

    def test_set_power_state_on_already_running(self):
        inst = self._make_instance(self.INSTANCE_ID_1, self.NAME_1, 'running')
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        self.test_driver.set_power_state(self.INSTANCE_ID_1, 'On')

        self.ec2_client.start_instances.assert_not_called()

    def test_set_power_state_force_on(self):
        inst = self._make_instance(self.INSTANCE_ID_1, self.NAME_1, 'stopped')
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        self.test_driver.set_power_state(self.INSTANCE_ID_1, 'ForceOn')

        self.ec2_client.start_instances.assert_called_once_with(
            InstanceIds=[self.INSTANCE_ID_1])

    def test_set_power_state_force_off(self):
        inst = self._make_instance(self.INSTANCE_ID_1, self.NAME_1, 'running')
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        self.test_driver.set_power_state(self.INSTANCE_ID_1, 'ForceOff')

        self.ec2_client.stop_instances.assert_called_once_with(
            InstanceIds=[self.INSTANCE_ID_1], Force=True)

    def test_set_power_state_force_off_already_off(self):
        inst = self._make_instance(self.INSTANCE_ID_1, self.NAME_1, 'stopped')
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        self.test_driver.set_power_state(self.INSTANCE_ID_1, 'ForceOff')

        self.ec2_client.stop_instances.assert_not_called()

    def test_set_power_state_graceful_shutdown(self):
        inst = self._make_instance(self.INSTANCE_ID_1, self.NAME_1, 'running')
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        self.test_driver.set_power_state(self.INSTANCE_ID_1,
                                         'GracefulShutdown')

        self.ec2_client.stop_instances.assert_called_once_with(
            InstanceIds=[self.INSTANCE_ID_1], Force=False)

    def test_set_power_state_force_restart(self):
        inst = self._make_instance(self.INSTANCE_ID_1, self.NAME_1, 'running')
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        self.test_driver.set_power_state(self.INSTANCE_ID_1, 'ForceRestart')

        self.ec2_client.reboot_instances.assert_called_once_with(
            InstanceIds=[self.INSTANCE_ID_1])

    def test_set_power_state_graceful_restart(self):
        inst = self._make_instance(self.INSTANCE_ID_1, self.NAME_1, 'running')
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        self.test_driver.set_power_state(self.INSTANCE_ID_1,
                                         'GracefulRestart')

        self.ec2_client.reboot_instances.assert_called_once_with(
            InstanceIds=[self.INSTANCE_ID_1])

    def test_set_power_state_nmi_raises(self):
        inst = self._make_instance(self.INSTANCE_ID_1, self.NAME_1, 'running')
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        self.assertRaises(error.FishyError,
                          self.test_driver.set_power_state,
                          self.INSTANCE_ID_1, 'Nmi')

    # --- boot device ---

    def test_get_boot_device(self):
        inst = self._make_instance(self.INSTANCE_ID_1, self.NAME_1)
        self.ec2_client.describe_instances.return_value = \
            self._make_describe_response(inst)

        device = self.test_driver.get_boot_device(self.INSTANCE_ID_1)
        self.assertEqual('Hdd', device)

    def test_set_boot_device_noop(self):
        self.test_driver.set_boot_device(self.INSTANCE_ID_1, 'Pxe')
