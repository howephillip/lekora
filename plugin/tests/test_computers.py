"""Several Hermes computers in one app: the computer's name (docs/multiple-instances.md)."""

from lekora import store as store_module
from tests.test_gateway import env, gw, recv  # noqa: F401  (gw fixture)
from tests.test_history import drain, hello_rev


def test_name_defaults_to_the_machine(store, monkeypatch):
    monkeypatch.setattr("socket.gethostname", lambda: "omacron.local")
    assert store.get_instance_name() == "omacron"
    store.set_instance_name("Home Server")  # the plugin setting
    assert store.get_instance_name() == "Home Server"
    store.rename_instance("Office Pi")       # chosen in the app
    store.set_instance_name("Home Server")  # the setting is applied again at the next start
    assert store.get_instance_name() == "Office Pi", "the app's choice wins"


def test_machine_name_fallback(monkeypatch):
    monkeypatch.setattr("socket.gethostname", lambda: "")
    assert store_module.machine_name() == "Hermes"


async def test_rename_reaches_every_phone(gw, store):
    device_a, tok_a = store.register_device("iPhone")
    device_b, tok_b = store.register_device("iPad")
    a = await hello_rev(gw, store, device_a, tok_a, since_rev=0)
    b = await hello_rev(gw, store, device_b, tok_b, since_rev=0)
    await drain(a)
    await drain(b)
    await a.send(env(store, "instance.rename", {"name": "  Office   Pi "}, msg_id="r1"))
    got = await recv(a)
    assert got["type"] == "instance.rename.result" and got["id"] == "r1"
    assert got["data"] == {"instance_name": "Office Pi"}
    changed = await recv(b)
    assert changed["type"] == "instance.changed" and changed["data"]["instance_name"] == "Office Pi"
    assert store.get_instance_name() == "Office Pi"

    await a.send(env(store, "instance.rename", {"name": "   "}, msg_id="r2"))
    assert (await recv(a))["data"]["code"] == "INVALID_NAME"
    await a.send(env(store, "instance.rename", {"name": "x" * 41}, msg_id="r3"))
    assert (await recv(a))["data"]["code"] == "INVALID_NAME"
    await a.close()
    await b.close()


async def test_new_phones_get_the_name(gw, store):
    store.rename_instance("Office Pi")
    device, tok = store.register_device("iPhone")
    ws = await hello_rev(gw, store, device, tok, since_rev=0)
    ack = await recv(ws)
    assert ack["type"] == "hello.ack" and ack["data"]["instance_name"] == "Office Pi"
    await ws.close()
