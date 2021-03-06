import pytest
from nab8balld.nab8balld import Nab8Balld
from nabd.tests.utils import close_old_async_connections
from nabd.tests.mock import NabdMockTestCase


@pytest.mark.django_db
class TestNabbookd(NabdMockTestCase):
    def tearDown(self):
        NabdMockTestCase.tearDown(self)
        close_old_async_connections()

    def test_connect(self):
        self.do_test_connect(Nab8Balld)
