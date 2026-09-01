import onedrive_links as ol
from conftest import make_args


def test_cmd_create_sends_minimal_body(fake_client, capsys):
    fake_client.register_item("report.pdf", {"id": "item-1"})
    fake_client.post_response = {
        "link": {"webUrl": "https://1drv.ms/new-link", "type": "view", "scope": "anonymous"}
    }

    ol.cmd_create(
        fake_client,
        make_args(path="report.pdf", type="view", scope="anonymous", password=None, expiration=None),
    )

    path, body = fake_client.post_calls[0]
    assert path == "/me/drive/items/item-1/createLink"
    assert body == {"type": "view", "scope": "anonymous"}

    out = capsys.readouterr().out
    assert "Created: https://1drv.ms/new-link" in out
    assert "type=view scope=anonymous" in out


def test_cmd_create_includes_password_and_expiration_when_set(fake_client):
    fake_client.register_item("report.pdf", {"id": "item-1"})
    fake_client.post_response = {"link": {"webUrl": "u"}}

    ol.cmd_create(
        fake_client,
        make_args(
            path="report.pdf",
            type="edit",
            scope="anonymous",
            password="s3cret",
            expiration="2026-12-31T00:00:00Z",
        ),
    )

    _, body = fake_client.post_calls[0]
    assert body == {
        "type": "edit",
        "scope": "anonymous",
        "password": "s3cret",
        "expirationDateTime": "2026-12-31T00:00:00Z",
    }


def test_cmd_create_omits_password_and_expiration_when_unset(fake_client):
    fake_client.register_item("report.pdf", {"id": "item-1"})
    fake_client.post_response = {"link": {"webUrl": "u"}}

    ol.cmd_create(
        fake_client,
        make_args(path="report.pdf", type="view", scope="anonymous", password=None, expiration=None),
    )

    _, body = fake_client.post_calls[0]
    assert "password" not in body
    assert "expirationDateTime" not in body
