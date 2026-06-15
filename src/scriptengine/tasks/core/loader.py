import functools
import importlib
import json
import logging
import os
import pathlib
import sysconfig

try:
    from importlib.metadata import entry_points
except ModuleNotFoundError:  # Python prior to 3.8
    from importlib_metadata import entry_points

from scriptengine.exceptions import ScriptEngineTaskLoaderError


def _cache_path():
    user_cache = pathlib.Path(os.environ.get("XDG_CACHE_HOME", "~/.cache")).expanduser()
    return user_cache / "scriptengine" / "tasks.cache.json"


def _site_mtime():
    site = sysconfig.get_path("purelib")
    try:
        return os.stat(site).st_mtime
    except OSError:
        return 0


def _load_ep_cache():
    """Return {name: value} from disk cache if still valid, else None."""
    p = _cache_path()
    try:
        data = json.loads(p.read_text())
        if data.get("mtime") == _site_mtime():
            return data["tasks"]
    except (OSError, KeyError, json.JSONDecodeError):
        pass
    return None


def _save_ep_cache(tasks_by_name):
    """Write {name: value} to disk cache, keyed on site-packages mtime."""
    p = _cache_path()
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps({"mtime": _site_mtime(), "tasks": tasks_by_name}))
    except OSError:
        pass  # silently skip if still not writable


def _discover_entry_points():
    """Scan entry_points(group='scriptengine.tasks') and return {name: value}."""
    try:
        eps = entry_points(group="scriptengine.tasks")
    except TypeError:  # importlib.metadata prior to Python 3.10
        eps = set(entry_points().get("scriptengine.tasks", []))

    result = {}
    for ep in eps:
        if ep.name not in result:
            result[ep.name] = ep.value
        else:
            existing_mod = result[ep.name].partition(":")[0]
            clashing_mod = ep.value.partition(":")[0]
            logging.getLogger("se.task.loader").error(
                f'Same task name "{ep.name}" defined in modules '
                f'"{existing_mod}" and "{clashing_mod}"'
            )
            raise ScriptEngineTaskLoaderError
    return result


# The load function goes through entry points, searching for ScriptEngine
# tasks. Since the function can be called quite frequently and modules are
# *usually* not loaded while SE is run, the result is cached.
# Note that this means that dynamic module loading is *not supported*!
@functools.lru_cache(maxsize=None)
def load():
    # Try fast disk cache first (avoids entry_points() scan on every run)
    ep_map = _load_ep_cache()
    if ep_map is None:
        ep_map = _discover_entry_points()
        _save_ep_cache(ep_map)

    loaded_tasks = {}
    for name, value in ep_map.items():
        module_name, _, attr = value.partition(":")
        module = importlib.import_module(module_name)
        loaded_tasks[name] = getattr(module, attr)

    return loaded_tasks


def load_and_register():
    loaded_tasks = load()
    for name, task in loaded_tasks.items():
        task.register_name(name)
    return loaded_tasks
