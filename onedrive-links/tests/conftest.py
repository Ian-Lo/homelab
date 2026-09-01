import re
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import onedrive_links as ol  # noqa: E402


class FakeGraphClient:
    """In-memory stand-in for GraphClient, keyed by Graph path shape."""

    def __init__(self):
        self.items_by_segment = {}  # "/me/drive/{segment}" -> item dict
        self.children = {}  # item id -> list of child item dicts
        self.permissions = {}  # item id -> list of permission dicts
        self.post_calls = []
        self.delete_calls = []
        self.post_response = None

    def register_item(self, path: str, item: dict):
        segment = ol.item_path_segment(path)
        self.items_by_segment[f"/me/drive/{segment}"] = item

    def get(self, path, **kwargs):
        return self.items_by_segment[path]

    def paged_get(self, path):
        m = re.search(r"/me/drive/items/([^/]+)/(children|permissions)$", path)
        item_id, kind = m.group(1), m.group(2)
        store = self.children if kind == "children" else self.permissions
        return store.get(item_id, [])

    def post(self, path, json_body):
        self.post_calls.append((path, json_body))
        return self.post_response

    def delete(self, path):
        self.delete_calls.append(path)


@pytest.fixture
def fake_client():
    return FakeGraphClient()


def make_args(**kwargs):
    return SimpleNamespace(**kwargs)
