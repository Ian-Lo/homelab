import onedrive_links as ol
from conftest import make_args


def test_cmd_list_reports_no_links_when_none_found(fake_client, capsys):
    root = {"id": "root-id", "folder": {}}
    fake_client.register_item("Docs", root)
    fake_client.children["root-id"] = []
    fake_client.permissions["root-id"] = []

    ol.cmd_list(fake_client, make_args(path="Docs"))

    assert capsys.readouterr().out.strip() == "No shared links found."


def test_cmd_list_ignores_owner_only_permission(fake_client, capsys):
    """Regression test: owner permissions carry a bare link.webUrl with no
    type/scope and must not be reported as a real shared link."""
    root = {"id": "root-id", "folder": {}}
    fake_client.register_item("Docs", root)
    fake_client.children["root-id"] = []
    fake_client.permissions["root-id"] = [
        {
            "id": "owner-perm",
            "roles": ["owner"],
            "link": {"webUrl": "https://1drv.ms/owner-self-link"},
        }
    ]

    ol.cmd_list(fake_client, make_args(path="Docs"))

    assert capsys.readouterr().out.strip() == "No shared links found."


def test_cmd_list_reports_real_shared_link(fake_client, capsys):
    root = {"id": "root-id", "folder": {}}
    fake_client.register_item("Docs", root)
    fake_client.children["root-id"] = []
    fake_client.permissions["root-id"] = [
        {
            "id": "perm-1",
            "link": {
                "type": "view",
                "scope": "anonymous",
                "webUrl": "https://1drv.ms/real-link",
            },
        }
    ]

    ol.cmd_list(fake_client, make_args(path="Docs"))

    out = capsys.readouterr().out
    assert "/Docs" in out
    assert "[perm-1] view/anonymous -> https://1drv.ms/real-link" in out


def test_cmd_list_mixed_owner_and_real_link_only_reports_real(fake_client, capsys):
    root = {"id": "root-id", "folder": {}}
    fake_client.register_item("Docs", root)
    fake_client.children["root-id"] = []
    fake_client.permissions["root-id"] = [
        {"id": "owner-perm", "roles": ["owner"], "link": {"webUrl": "https://1drv.ms/self"}},
        {
            "id": "perm-1",
            "link": {"type": "edit", "scope": "anonymous", "webUrl": "https://1drv.ms/real"},
        },
    ]

    ol.cmd_list(fake_client, make_args(path="Docs"))

    out = capsys.readouterr().out
    assert out.count("[perm-1]") == 1
    assert "owner-perm" not in out
