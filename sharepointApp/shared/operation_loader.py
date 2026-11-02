"""Discover and load the single retained operation blueprint."""

from importlib import util
from pathlib import Path
from types import ModuleType
from typing import Any


def discover_selected_operation(app_root: Path) -> Path:
    descriptor_paths = sorted(
        app_root.glob("operations/**/trigger-config.json"),
        key=lambda path: path.as_posix(),
    )
    if len(descriptor_paths) != 1:
        raise RuntimeError(
            "Expected exactly one retained operation descriptor under operations/, "
            f"but found {len(descriptor_paths)}."
        )

    operation_root = descriptor_paths[0].parent
    if not (operation_root / "function.py").is_file():
        raise RuntimeError(
            "The retained operation descriptor must be next to function.py."
        )

    return operation_root


def _load_module(module_path: Path) -> ModuleType:
    module_name = f"_connector_operation_{module_path.parent.name}"
    spec = util.spec_from_file_location(module_name, module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError("Unable to load the retained connector operation.")

    module = util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_selected_blueprint(app_root: Path) -> Any:
    operation_root = discover_selected_operation(app_root)
    module = _load_module(operation_root / "function.py")
    blueprint = getattr(module, "bp", None)
    if blueprint is None:
        raise RuntimeError("The retained operation must export a 'bp' blueprint.")

    return blueprint
