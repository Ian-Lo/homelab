import stat

import pytest

import onedrive_links as ol


def test_get_client_id_from_env(monkeypatch):
    monkeypatch.setenv("ONEDRIVE_LINKS_CLIENT_ID", "env-client-id")
    assert ol.get_client_id() == "env-client-id"


def test_get_client_id_prompts_when_unset(monkeypatch):
    monkeypatch.delenv("ONEDRIVE_LINKS_CLIENT_ID", raising=False)
    monkeypatch.setattr("builtins.input", lambda prompt: "typed-client-id")
    assert ol.get_client_id() == "typed-client-id"


def test_get_client_id_exits_on_empty_input(monkeypatch):
    monkeypatch.delenv("ONEDRIVE_LINKS_CLIENT_ID", raising=False)
    monkeypatch.setattr("builtins.input", lambda prompt: "   ")
    with pytest.raises(SystemExit):
        ol.get_client_id()


def test_save_cache_skips_write_when_unchanged(monkeypatch, tmp_path):
    monkeypatch.setattr(ol, "CONFIG_DIR", tmp_path / "cfg")
    monkeypatch.setattr(ol, "CACHE_FILE", tmp_path / "cfg" / "token_cache.bin")

    class FakeCache:
        has_state_changed = False

    ol.save_cache(FakeCache())
    assert not (tmp_path / "cfg" / "token_cache.bin").exists()


def test_save_cache_writes_with_restricted_perms(monkeypatch, tmp_path):
    config_dir = tmp_path / "cfg"
    cache_file = config_dir / "token_cache.bin"
    monkeypatch.setattr(ol, "CONFIG_DIR", config_dir)
    monkeypatch.setattr(ol, "CACHE_FILE", cache_file)

    class FakeCache:
        has_state_changed = True

        def serialize(self):
            return "serialized-cache-data"

    ol.save_cache(FakeCache())

    assert cache_file.read_text() == "serialized-cache-data"
    mode = stat.S_IMODE(cache_file.stat().st_mode)
    assert mode == stat.S_IRUSR | stat.S_IWUSR


def test_load_cache_deserializes_existing_file(monkeypatch, tmp_path):
    cache_file = tmp_path / "token_cache.bin"
    cache_file.write_text('{"Account": {}}')
    monkeypatch.setattr(ol, "CACHE_FILE", cache_file)

    cache = ol.load_cache()
    assert isinstance(cache, ol.msal.SerializableTokenCache)


def test_load_cache_returns_empty_when_missing(monkeypatch, tmp_path):
    monkeypatch.setattr(ol, "CACHE_FILE", tmp_path / "missing.bin")
    cache = ol.load_cache()
    assert isinstance(cache, ol.msal.SerializableTokenCache)
