"""Validates LLM-proposed plans against the action allowlist.

The validator never trusts the LLM: every action is checked for a known type,
strictly-typed parameters and blocked patterns before it can reach the Mac.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from pydantic import ValidationError

from app.policy.permissions import ACTION_SPECS, ActionType, PressKeyParams, Risk

MAX_ACTIONS = 8


class PlanValidationError(ValueError):
    """Raised when a proposed plan is not acceptable."""


@dataclass(frozen=True)
class ValidatedAction:
    type: ActionType
    parameters: dict[str, Any]
    risk: Risk
    retry_safe: bool
    description: str

    @property
    def requires_approval(self) -> bool:
        return self.risk is Risk.CONFIRM


@dataclass(frozen=True)
class ValidatedPlan:
    summary: str
    actions: list[ValidatedAction]
    unsupported_reason: str | None = None


def validate_action(raw: Any, index: int = 0) -> ValidatedAction:
    if not isinstance(raw, dict):
        raise PlanValidationError(f"Step {index + 1} is not an object")
    try:
        action_type = ActionType(raw.get("type"))
    except ValueError:
        raise PlanValidationError(
            f"Step {index + 1} uses an unsupported action: {raw.get('type')!r}"
        ) from None

    spec = ACTION_SPECS[action_type]
    params_raw = raw.get("parameters") or {}
    try:
        params = spec.params.model_validate(params_raw)
    except ValidationError as exc:
        error = exc.errors()[0]
        field = ".".join(str(part) for part in error.get("loc", ())) or "parameters"
        if error.get("type") == "missing":
            detail = f"is missing “{field}”"
        else:
            reason = str(error.get("msg", "invalid value")).removeprefix("Value error, ")
            detail = f"has an invalid “{field}”: {reason}"
        raise PlanValidationError(f"Step {index + 1} ({action_type.value}) {detail}.") from None

    if isinstance(params, PressKeyParams) and params.is_blocked():
        raise PlanValidationError(
            f"Step {index + 1} uses a blocked keyboard shortcut"
        )

    return ValidatedAction(
        type=action_type,
        parameters=params.model_dump(exclude_none=True),
        risk=spec.risk,
        retry_safe=spec.retry_safe,
        description=spec.describe(params),
    )


def validate_plan(raw: Any) -> ValidatedPlan:
    if not isinstance(raw, dict):
        raise PlanValidationError("The plan is not a JSON object")

    actions_raw = raw.get("actions", [])
    if not isinstance(actions_raw, list):
        raise PlanValidationError("The plan's actions must be a list")
    if len(actions_raw) > MAX_ACTIONS:
        raise PlanValidationError(f"The plan has more than {MAX_ACTIONS} steps")

    summary = str(raw.get("summary") or "").strip()[:200]
    reason = raw.get("unsupported_reason")
    reason = str(reason).strip()[:300] if reason else None

    actions = [validate_action(a, i) for i, a in enumerate(actions_raw)]
    return ValidatedPlan(summary=summary, actions=actions, unsupported_reason=reason)
