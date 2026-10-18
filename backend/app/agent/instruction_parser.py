"""Normalizes user instructions before they reach the planner."""

from __future__ import annotations

import re
import unicodedata

MAX_INSTRUCTION_LENGTH = 1000
_WHITESPACE = re.compile(r"\s+")


class InstructionError(ValueError):
    pass


def normalize_instruction(text: str) -> str:
    """Strip control characters, collapse whitespace and enforce length limits."""
    cleaned = "".join(
        ch for ch in text if ch in "\t\n" or unicodedata.category(ch)[0] != "C"
    )
    cleaned = _WHITESPACE.sub(" ", cleaned).strip()
    if not cleaned:
        raise InstructionError("Instruction is empty")
    if len(cleaned) > MAX_INSTRUCTION_LENGTH:
        raise InstructionError(
            f"Instruction is longer than {MAX_INSTRUCTION_LENGTH} characters"
        )
    return cleaned
