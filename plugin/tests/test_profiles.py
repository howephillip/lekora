from lekora.plugin import LekoraConfig
from lekora.profiles import discover_profiles


def make_profile(root, name):
    home = root / "profiles" / name
    home.mkdir(parents=True)
    (home / "config.yaml").write_text("model: x\n")
    return home


def ids(profiles):
    return [p["profile_id"] for p in profiles]


def test_only_default(fake_hermes_root):
    assert discover_profiles(fake_hermes_root) == [
        {"profile_id": "default", "name": "Default", "avatar": "sparkles"}]


def test_readable_names_without_display_name():
    from lekora.profiles import readable_name
    assert readable_name("default") == "Default"
    assert readable_name("work-bot") == "Work bot"
    assert readable_name("deep_research") == "Deep research"


def test_named_profiles_sorted_after_default(fake_hermes_root):
    make_profile(fake_hermes_root, "work")
    make_profile(fake_hermes_root, "coder")
    assert ids(discover_profiles(fake_hermes_root)) == ["default", "coder", "work"]


def test_display_name_and_description(fake_hermes_root):
    home = make_profile(fake_hermes_root, "work")
    (home / "profile.yaml").write_text(
        "display_name: Work Assistant\ndescription: Handles email and calendar\n")
    (fake_hermes_root / "profile.yaml").write_text("display_name: Home\n")
    default, work = discover_profiles(fake_hermes_root)
    assert default == {"profile_id": "default", "name": "Home", "avatar": "sparkles"}
    assert work == {"profile_id": "work", "name": "Work Assistant", "avatar": "sparkles",
                    "description": "Handles email and calendar"}


def test_skips_deleted_parked_invalid_and_empty(fake_hermes_root):
    make_profile(fake_hermes_root, "live")
    parked = make_profile(fake_hermes_root, "parked")
    (parked / "gateway.parked").write_text("")
    make_profile(fake_hermes_root, "gone")
    (fake_hermes_root / "profiles" / ".deleted" / "gone").mkdir(parents=True)
    (fake_hermes_root / "profiles" / "empty").mkdir()           # no identity files
    (fake_hermes_root / "profiles" / "Bad Name").mkdir()        # not a valid profile id
    (fake_hermes_root / "profiles" / "notes.txt").write_text("") # not a directory
    assert ids(discover_profiles(fake_hermes_root)) == ["default", "live"]


def test_config_rediscovers_on_each_use(fake_hermes_root):
    cfg = LekoraConfig.from_extra(None)
    assert ids(cfg.current_profiles()) == ["default"]
    make_profile(fake_hermes_root, "new")
    assert ids(cfg.current_profiles()) == ["default", "new"]  # no restart needed


def test_pinned_profiles_override_discovery(fake_hermes_root):
    make_profile(fake_hermes_root, "work")
    cfg = LekoraConfig.from_extra({"profiles": [
        {"profile_id": "work", "name": "Work", "description": "Only this one"}]})
    assert cfg.current_profiles() == [
        {"profile_id": "work", "name": "Work", "avatar": "sparkles", "description": "Only this one"}]
