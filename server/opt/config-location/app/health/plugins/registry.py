from __future__ import annotations

from collections import defaultdict
from collections.abc import Iterable

from .base import ConfigPlugin, Plugin
from .types import PluginKind


class PluginRegistry:
    def __init__(self) -> None:
        self._plugins: dict[str, Plugin] = {}
        self._kinds: dict[PluginKind, list[str]] = defaultdict(list)

    def register(self, plugin: Plugin) -> None:
        name = getattr(plugin, "plugin_name", "").strip()

        if not name:
            raise ValueError("plugin_name is required")

        if name in self._plugins:
            raise ValueError(
                f"plugin already registered: {name}"
            )

        kind = getattr(plugin, "plugin_kind", None)

        if not isinstance(kind, PluginKind):
            raise ValueError(
                f"invalid plugin kind for {name}"
            )

        self._plugins[name] = plugin
        self._kinds[kind].append(name)

    def load(self, plugins: Iterable[Plugin]) -> None:
        for plugin in plugins:
            self.register(plugin)

    def get(self, name: str) -> Plugin:
        return self._plugins[name]

    def by_kind(
        self,
        kind: PluginKind,
    ) -> tuple[Plugin, ...]:
        return tuple(
            self._plugins[name]
            for name in self._kinds.get(kind, ())
        )

    def supporting(
        self,
        kind: PluginKind,
        config_type: str,
    ) -> tuple[ConfigPlugin, ...]:

        result = []

        for plugin in self.by_kind(kind):
            if (
                isinstance(plugin, ConfigPlugin)
                and plugin.supports(config_type)
            ):
                result.append(plugin)

        return tuple(result)

    def all(self) -> tuple[Plugin, ...]:
        return tuple(self._plugins.values())
