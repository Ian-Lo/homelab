import pytest

import onedrive_links as ol
from conftest import make_args


def _setup_item_with_links(fake_client, links):
    fake_client.register_item("report.pdf", {"id": "item-1"})
    fake_client.permissions["item-1"] = links


def test_cmd_revoke_reports_when_no_links(fake_client, capsys):
    _setup_item_with_links(fake_client, [])

    ol.cmd_revoke(fake_client, make_args(path="report.pdf", permission_id=None, all=False))

    assert capsys.readouterr().out.strip() == "No shared links on this item."
    assert fake_client.delete_calls == []


def test_cmd_revoke_ignores_owner_only_permission(fake_client, capsys):
    _setup_item_with_links(
        fake_client,
        [{"id": "owner-perm", "roles": ["owner"], "link": {"webUrl": "https://1drv.ms/self"}}],
    )

    ol.cmd_revoke(fake_client, make_args(path="report.pdf", permission_id=None, all=True))

    assert capsys.readouterr().out.strip() == "No shared links on this item."
    assert fake_client.delete_calls == []


def test_cmd_revoke_by_permission_id(fake_client, capsys):
    _setup_item_with_links(
        fake_client,
        [
            {"id": "p1", "link": {"type": "view", "webUrl": "https://1drv.ms/a"}},
            {"id": "p2", "link": {"type": "view", "webUrl": "https://1drv.ms/b"}},
        ],
    )

    ol.cmd_revoke(
        fake_client, make_args(path="report.pdf", permission_id="p2", all=False)
    )

    assert fake_client.delete_calls == ["/me/drive/items/item-1/permissions/p2"]
    assert "Revoked p2" in capsys.readouterr().out


def test_cmd_revoke_unknown_permission_id_exits(fake_client):
    _setup_item_with_links(
        fake_client, [{"id": "p1", "link": {"type": "view", "webUrl": "https://1drv.ms/a"}}]
    )

    with pytest.raises(SystemExit):
        ol.cmd_revoke(
            fake_client, make_args(path="report.pdf", permission_id="missing", all=False)
        )

    assert fake_client.delete_calls == []


def test_cmd_revoke_all(fake_client):
    _setup_item_with_links(
        fake_client,
        [
            {"id": "p1", "link": {"type": "view", "webUrl": "https://1drv.ms/a"}},
            {"id": "p2", "link": {"type": "edit", "webUrl": "https://1drv.ms/b"}},
        ],
    )

    ol.cmd_revoke(fake_client, make_args(path="report.pdf", permission_id=None, all=True))

    assert fake_client.delete_calls == [
        "/me/drive/items/item-1/permissions/p1",
        "/me/drive/items/item-1/permissions/p2",
    ]


def test_cmd_revoke_ambiguous_without_flags_prints_prompt_and_deletes_nothing(
    fake_client, capsys
):
    _setup_item_with_links(
        fake_client,
        [{"id": "p1", "link": {"type": "view", "webUrl": "https://1drv.ms/a"}}],
    )

    ol.cmd_revoke(fake_client, make_args(path="report.pdf", permission_id=None, all=False))

    out = capsys.readouterr().out
    assert "Re-run with --permission-id or --all" in out
    assert "[p1]" in out
    assert fake_client.delete_calls == []
