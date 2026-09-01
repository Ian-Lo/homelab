from unittest.mock import MagicMock

import pytest
import requests

import onedrive_links as ol


def make_response(json_body, status_ok=True):
    resp = MagicMock()
    resp.json.return_value = json_body
    if status_ok:
        resp.raise_for_status.return_value = None
    else:
        resp.raise_for_status.side_effect = requests.HTTPError("boom")
    return resp


def test_get_returns_json_and_checks_status():
    client = ol.GraphClient("token")
    client.session = MagicMock()
    client.session.get.return_value = make_response({"id": "1"})

    result = client.get("/me/drive/root")

    client.session.get.assert_called_once_with(f"{ol.GRAPH}/me/drive/root")
    assert result == {"id": "1"}


def test_get_raises_on_http_error():
    client = ol.GraphClient("token")
    client.session = MagicMock()
    client.session.get.return_value = make_response({}, status_ok=False)

    with pytest.raises(requests.HTTPError):
        client.get("/me/drive/root")


def test_post_sends_json_body():
    client = ol.GraphClient("token")
    client.session = MagicMock()
    client.session.post.return_value = make_response({"link": {"webUrl": "u"}})

    result = client.post("/me/drive/items/1/createLink", {"type": "view"})

    client.session.post.assert_called_once_with(
        f"{ol.GRAPH}/me/drive/items/1/createLink", json={"type": "view"}
    )
    assert result == {"link": {"webUrl": "u"}}


def test_delete_checks_status():
    client = ol.GraphClient("token")
    client.session = MagicMock()
    client.session.delete.return_value = make_response({}, status_ok=False)

    with pytest.raises(requests.HTTPError):
        client.delete("/me/drive/items/1/permissions/p1")


def test_paged_get_follows_next_link():
    client = ol.GraphClient("token")
    client.session = MagicMock()
    page1 = make_response(
        {"value": [{"id": "a"}], "@odata.nextLink": "https://graph/page2"}
    )
    page2 = make_response({"value": [{"id": "b"}]})
    client.session.get.side_effect = [page1, page2]

    result = client.paged_get("/me/drive/items/1/children")

    assert result == [{"id": "a"}, {"id": "b"}]
    assert client.session.get.call_count == 2


def test_paged_get_single_page():
    client = ol.GraphClient("token")
    client.session = MagicMock()
    client.session.get.return_value = make_response({"value": [{"id": "a"}]})

    result = client.paged_get("/me/drive/items/1/permissions")

    assert result == [{"id": "a"}]
    assert client.session.get.call_count == 1
