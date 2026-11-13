"""What your agents call you (docs/your-name.md)."""

from tests.test_gateway import env, gw, recv  # noqa: F401  (gw fixture)
from tests.test_history import drain, hello_rev


async def test_your_name_is_kept_here_and_reaches_every_phone(gw, store):
    device_a, tok_a = store.register_device("iPhone")
    device_b, tok_b = store.register_device("iPad")
    a = await hello_rev(gw, store, device_a, tok_a, since_rev=0)
    b = await hello_rev(gw, store, device_b, tok_b, since_rev=0)
    await drain(a)
    await drain(b)
    await a.send(env(store, "user.name.set", {"name": "  Phillip  "}, msg_id="n1"))
    got = await recv(a)
    assert got["type"] == "user.name.set.result" and got["data"] == {"user_name": "Phillip"}
    changed = await recv(b)
    assert changed["type"] == "instance.changed" and changed["data"]["user_name"] == "Phillip"
    assert store.get_user_name() == "Phillip"

    await a.send(env(store, "user.name.set", {"name": "x" * 81}, msg_id="n2"))
    assert (await recv(a))["data"]["code"] == "INVALID_NAME"
    await a.close()
    await b.close()

    # A new phone (or this one after re-setup) gets it.
    device_c, tok_c = store.register_device("New iPhone")
    c = await hello_rev(gw, store, device_c, tok_c, since_rev=0)
    ack = await recv(c)
    assert ack["type"] == "hello.ack" and ack["data"]["user_name"] == "Phillip"
    await c.close()


def test_agents_see_your_name_not_lekora(store):
    # The adapter passes this to Hermes as the message's sender (Hermes' "User:" line).
    from lekora.store import DEFAULT_USER_NAME
    assert store.user_name_for_agents() == DEFAULT_USER_NAME != "Lekora", "not someone called Lekora"
    store.set_user_name("Phillip")
    assert store.user_name_for_agents() == "Phillip"
    store.set_user_name("")
    assert store.user_name_for_agents() == DEFAULT_USER_NAME
