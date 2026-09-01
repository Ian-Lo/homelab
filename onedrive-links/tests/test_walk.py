import onedrive_links as ol


def test_item_path_segment_root():
    assert ol.item_path_segment("") == "root"


def test_item_path_segment_nested_path():
    assert ol.item_path_segment("Documents/Report.pdf") == "root:/Documents/Report.pdf:"


def test_item_path_segment_strips_slashes():
    assert ol.item_path_segment("/Documents/") == "root:/Documents:"


def test_walk_items_yields_root_and_children(fake_client):
    root = {"id": "root-id", "folder": {}}
    child_file = {"id": "child-1", "name": "a.txt"}
    child_folder = {"id": "child-2", "name": "sub", "folder": {}}
    grandchild = {"id": "grandchild-1", "name": "b.txt"}

    fake_client.register_item("Docs", root)
    fake_client.children["root-id"] = [child_file, child_folder]
    fake_client.children["child-2"] = [grandchild]

    results = list(ol.walk_items(fake_client, "Docs"))

    assert results == [
        (root, "Docs"),
        (child_file, "Docs/a.txt"),
        (child_folder, "Docs/sub"),
        (grandchild, "Docs/sub/b.txt"),
    ]


def test_walk_items_leaf_file_has_no_children_lookup(fake_client):
    leaf = {"id": "file-id"}
    fake_client.register_item("Docs/report.pdf", leaf)

    results = list(ol.walk_items(fake_client, "Docs/report.pdf"))

    assert results == [(leaf, "Docs/report.pdf")]


def test_walk_items_from_drive_root(fake_client):
    root = {"id": "root-id", "folder": {}}
    fake_client.register_item("", root)
    fake_client.children["root-id"] = []

    results = list(ol.walk_items(fake_client, ""))

    assert results == [(root, "")]
