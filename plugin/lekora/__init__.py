"""Lekora: iOS companion host plugin for Hermes."""

__version__ = "0.1.0"


def register(ctx):
    """Hermes plugin entry point (imported lazily so the package loads without Hermes)."""
    from .plugin import register as _register

    _register(ctx)
