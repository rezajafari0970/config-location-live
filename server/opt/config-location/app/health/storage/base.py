from __future__ import annotations

from abc import ABC, abstractmethod

from ..core.models import HealthResult


class HealthResultStore(ABC):

    @abstractmethod
    def save(
        self,
        result: HealthResult,
    ) -> None:
        raise NotImplementedError

    @abstractmethod
    def get(
        self,
        config_id: str,
    ) -> HealthResult | None:
        raise NotImplementedError
