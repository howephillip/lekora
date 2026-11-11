"""Files both ways (docs/files.md)."""

import asyncio
import base64
import json
from pathlib import Path

import pytest

from lekora import files as files_module
from lekora.files import CHUNK_BYTES, FileError, FileStore
from lekora.gateway import Gateway
from lekora.hermes_files import inbound_media, send_file_tool
from tests.test_gateway import PROFILES, env, recv
from tests.test_history import drain, hello_rev


@pytest.fixture
def file_store(store, tmp_path):
    return FileStore(tmp_path / "lekora-files", store)


@pytest.fixture
async def fgw(store, file_store):
    """A gateway with files, whose stand-in Hermes records what it was given."""
    got = []

    async def dispatch(profile_id, text, message_id, files=None):
        got.append((profile_id, text, files))

    g = Gateway(store, dispatch, lambda: PROFILES, host="127.0.0.1", auth_timeout=0.4)
    g.files = file_store
    g.received = got
    await g.start()
    yield g
    await g.stop()


async def phone(gw, store):
    device, tok = store.register_device("iPhone")
    ws = await hello_rev(gw, store, device, tok, since_rev=0)
    await drain(ws)
    return ws


async def ask(ws, store, type_, data, profile="coder", msg_id=None):
    await ws.send(env(store, type_, data, profile_id=profile, msg_id=msg_id or type_))
    return await recv(ws)


async def upload(ws, store, name, data: bytes, mime="", profile="coder"):
    begun = (await ask(ws, store, "file.upload.begin", {"name": name, "mime": mime, "size": len(data)}, profile))["data"]
    file_id, size = begun["file_id"], begun["chunk_size"]
    for offset in range(0, len(data), size):
        got = await ask(ws, store, "file.upload.chunk", {
            "file_id": file_id, "offset": offset,
            "data": base64.b64encode(data[offset:offset + size]).decode()}, profile, msg_id=f"c{offset}")
        assert got["data"]["received"] == min(offset + size, len(data))
    return (await ask(ws, store, "file.upload.end", {"file_id": file_id}, profile))["data"]["file"]


# ---- on disk ------------------------------------------------------------------------

def test_upload_in_pieces_and_read_back(file_store):
    data = bytes(range(256)) * 3000  # bigger than one piece
    begun = file_store.begin_upload("coder", "../../evil/report.pdf", "application/pdf", len(data))
    fid = begun["file_id"]
    sent = 0
    while sent < len(data):
        piece = data[sent:sent + CHUNK_BYTES]
        sent = file_store.write_chunk("coder", fid, sent, base64.b64encode(piece).decode())
    done = file_store.finish_upload("coder", fid)
    assert done == {"file_id": fid, "name": "report.pdf", "mime": "application/pdf", "size": len(data), "kind": "document"}
    row = file_store.ready(fid)
    assert file_store.path_of(row).read_bytes() == data
    assert file_store.path_of(row).parent.parent.parent == file_store.root, "inside lekora-files/<agent>/<id>/"
    back, offset = b"", 0
    while True:
        part = file_store.read_chunk(fid, offset)
        back += base64.b64decode(part["data"])
        offset += len(base64.b64decode(part["data"]))
        if part["done"]:
            break
    assert back == data
    assert file_store.usage() == {"bytes": len(data), "count": 1}


def test_upload_checks(file_store, monkeypatch):
    with pytest.raises(FileError) as too_big:
        file_store.begin_upload("coder", "huge.mov", "video/quicktime", 100 * 1024 * 1024 + 1)
    assert too_big.value.code == "FILE_TOO_LARGE"
    fid = file_store.begin_upload("coder", "a.txt", "text/plain", 4)["file_id"]
    with pytest.raises(FileError):
        file_store.write_chunk("coder", fid, 2, base64.b64encode(b"ab").decode())  # out of order
    with pytest.raises(FileError):
        file_store.write_chunk("assistant", fid, 0, base64.b64encode(b"ab").decode())  # another agent's
    with pytest.raises(FileError):
        file_store.write_chunk("coder", fid, 0, base64.b64encode(b"abcdef").decode())  # more than announced
    file_store.write_chunk("coder", fid, 0, base64.b64encode(b"ab").decode())
    with pytest.raises(FileError):
        file_store.finish_upload("coder", fid)  # not all there
    with pytest.raises(FileError):
        file_store.ready(fid)
    assert file_store.usage()["count"] == 0


def test_kinds_and_names():
    assert files_module.kind_of("image/heic") == "image"
    assert files_module.kind_of("application/pdf") == "document"
    assert files_module.safe_name("/etc/passwd") == "passwd"
    assert files_module.safe_name(".hidden") == "hidden"
    assert files_module.guess_mime("photo.jpg") == "image/jpeg"


def test_stale_uploads_are_cleaned(file_store, clock):
    fid = file_store.begin_upload("coder", "a.txt", "text/plain", 10)["file_id"]
    clock.advance(hours=25)
    assert file_store.clean_stale_uploads() == 1
    assert file_store.store.get_file(fid) is None


def test_agent_files_are_kept(file_store, tmp_path):
    made = tmp_path / "chart.png"
    made.write_bytes(b"\x89PNG fake")
    got = file_store.add_agent_file("coder", made)
    assert got["kind"] == "image" and got["name"] == "chart.png"
    made.unlink()  # Hermes' cache is cleared later: the copy stays
    assert file_store.path_of(file_store.ready(got["file_id"])).read_bytes() == b"\x89PNG fake"
    with pytest.raises(FileError):
        file_store.add_agent_file("coder", tmp_path / "missing.pdf")


def test_deleting_an_agent_moves_its_files_to_the_backup(file_store, tmp_path):
    made = tmp_path / "notes.md"
    made.write_text("hi")
    got = file_store.add_agent_file("coder", made)
    backup = tmp_path / "backups" / "coder-lekora-files"
    file_store.move_profile("coder", backup)
    assert (backup / got["file_id"] / "notes.md").read_text() == "hi"
    assert file_store.usage()["count"] == 0


# ---- over the connection ------------------------------------------------------------------

async def test_send_files_with_a_message(fgw, store):
    ws = await phone(fgw, store)
    other = await phone(fgw, store)
    photo = await upload(ws, store, "IMG_1.jpg", b"\xff\xd8\xff jpeg", "image/jpeg")
    doc = await upload(ws, store, "notes.txt", b"hello", "text/plain")
    assert photo["kind"] == "image" and doc["kind"] == "document"
    await ws.send(env(store, "chat.send", {"text": "", "files": [photo["file_id"], doc["file_id"]]},
                      profile_id="coder", msg_id="m1"))
    echo = await recv(ws)
    assert echo["data"]["files"] == [photo, doc] and echo["data"]["client_id"] == "m1"
    assert (await recv(other))["data"]["files"] == [photo, doc], "every phone sees them"
    for _ in range(50):
        if fgw.received:
            break
        await asyncio.sleep(0.02)
    profile, text, given = fgw.received[0]
    assert profile == "coder" and text == ""
    assert [g["name"] for g in given] == ["IMG_1.jpg", "notes.txt"]
    assert Path(given[0]["path"]).read_bytes() == b"\xff\xd8\xff jpeg"
    # The files come back with history too.
    await ws.send(env(store, "history.fetch", {"limit": 5}, profile_id="coder", msg_id="h"))
    page = await recv(ws)
    assert page["data"]["messages"][-1]["files"] == [photo, doc]
    await ws.close()
    await other.close()


async def test_send_refuses_bad_files(fgw, store):
    ws = await phone(fgw, store)
    mine = await upload(ws, store, "a.txt", b"x", profile="assistant")
    await ws.send(env(store, "chat.send", {"text": "hi", "files": [mine["file_id"]]}, profile_id="coder", msg_id="m1"))
    assert (await recv(ws))["data"]["code"] == "UNKNOWN_FILE", "another agent's file"
    await ws.send(env(store, "chat.send", {"text": "hi", "files": ["f_nope"] * 11}, profile_id="coder", msg_id="m2"))
    assert (await recv(ws))["data"]["code"] == "INVALID_FILE"
    got = await ask(ws, store, "file.upload.begin", {"name": "big.mov", "size": 200 * 1024 * 1024})
    assert got["data"]["code"] == "FILE_TOO_LARGE"
    await ws.close()


async def test_read_and_usage(fgw, store):
    ws = await phone(fgw, store)
    sent = await upload(ws, store, "a.bin", b"\x00\x01\x02")
    got = await ask(ws, store, "file.read", {"file_id": sent["file_id"], "offset": 0})
    assert base64.b64decode(got["data"]["data"]) == b"\x00\x01\x02" and got["data"]["done"]
    assert (await ask(ws, store, "file.read", {"file_id": "f_nope", "offset": 0}, msg_id="r2"))["data"]["code"] == "UNKNOWN_FILE"
    assert (await ask(ws, store, "files.usage", {}))["data"] == {"bytes": 3, "count": 1}
    await ws.close()


async def test_agent_files_reach_the_phone(fgw, store, tmp_path):
    ws = await phone(fgw, store)
    made = tmp_path / "report.pdf"
    made.write_bytes(b"%PDF-1.7")
    described = fgw.files.add_agent_file("coder", made)
    await fgw.publish_files("coder", [described], "Here's the report")
    got = await recv(ws)
    assert got["data"]["role"] == "assistant" and got["data"]["text"] == "Here's the report"
    assert got["data"]["files"][0]["name"] == "report.pdf"
    await ws.close()


# ---- into Hermes, and the tool -------------------------------------------------------------

def test_inbound_media_like_telegram(tmp_path):
    photo, notes, pdf = tmp_path / "p.jpg", tmp_path / "notes.md", tmp_path / "r.pdf"
    photo.write_bytes(b"jpeg")
    notes.write_text("# Plan\nramen")
    pdf.write_bytes(b"%PDF")
    cached = []

    def cache(data, name, mime):
        cached.append(name)
        kind = "image" if mime.startswith("image/") else "document"
        return f"/cache/{name}", mime or "application/octet-stream", kind

    media = inbound_media("Look", [
        {"path": str(photo), "name": "p.jpg", "mime": "image/jpeg"},
        {"path": str(notes), "name": "notes.md", "mime": "text/markdown"},
        {"path": str(pdf), "name": "r.pdf", "mime": "application/pdf"},
    ], cache)
    assert media.media_urls == ["/cache/p.jpg", "/cache/notes.md", "/cache/r.pdf"]
    assert media.media_types == ["image/jpeg", "text/markdown", "application/pdf"]
    assert media.media_text_inlined == [False, True, False]
    assert media.text == "[Content of notes.md]:\n# Plan\nramen\n\nLook"
    assert media.message_kind == "photo"


def test_inbound_media_skips_what_hermes_refuses(tmp_path):
    f = tmp_path / "x.jpg"
    f.write_bytes(b"x")
    media = inbound_media("", [{"path": str(f), "name": "x.jpg", "mime": "image/jpeg"}], lambda d, n, m: None)
    assert media.media_urls == [] and media.message_kind == "text"


def test_send_file_tool(tmp_path):
    made = tmp_path / "out.csv"
    made.write_text("a,b")
    sent = []
    loop = asyncio.new_event_loop()
    import threading
    thread = threading.Thread(target=loop.run_forever, daemon=True)
    thread.start()

    async def deliver(chat_id, path, caption, name):
        sent.append((chat_id, path, caption, name))

    try:
        def run(args, platform="lekora", validate=lambda p: p if Path(p).is_file() else None):
            return json.loads(send_file_tool(args, platform=platform, chat_id="coder", deliver=deliver,
                                             loop=loop, validate=validate))
        assert run({"path": str(made)}, platform="telegram")["success"] is False
        assert "isn't a file" in run({"path": str(tmp_path / "nope")})["error"]
        assert run({"path": ""})["success"] is False
        ok = run({"path": str(made), "caption": "Your data"})
        assert ok["success"] is True and sent == [("coder", str(made), "Your data", None)]
    finally:
        loop.call_soon_threadsafe(loop.stop)
        thread.join(2)


async def test_service_keeps_agent_files_in_lekora_files(tmp_path, fake_hermes_root):
    from lekora.plugin import LekoraConfig, LekoraService
    from tests.test_plugin import FakeHermes
    cfg = LekoraConfig(db_path=str(tmp_path / "lekora.db"), listen_host="127.0.0.1",
                       hermes_root=str(fake_hermes_root),
                       profiles=[{"profile_id": "coder", "name": "Coder", "avatar": "terminal"}])
    svc = LekoraService(FakeHermes(), cfg, hermes_version="0.22.5")
    await svc.start()
    try:
        made = tmp_path / "plot.png"
        made.write_bytes(b"\x89PNG")
        seq = await svc.handle_agent_file("coder", made, "A plot")
        event = svc.store.get_event(seq)
        assert event.payload["text"] == "A plot" and event.payload["files"][0]["name"] == "plot.png"
        row = svc.gateway.files.ready(event.payload["files"][0]["file_id"])
        assert str(svc.gateway.files.path_of(row)).startswith(str(fake_hermes_root / "lekora-files"))
    finally:
        await svc.stop()
