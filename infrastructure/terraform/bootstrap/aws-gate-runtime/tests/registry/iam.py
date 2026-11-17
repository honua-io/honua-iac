"""Fail-closed evaluation of the IAM subset emitted by the gate root."""
import fnmatch


def values(value):
    return value if isinstance(value, list) else [value]


def matches(value, patterns):
    return any(fnmatch.fnmatchcase(value, pattern) for pattern in values(patterns))


def condition_value(operator, actual, expected):
    if operator == "Null":
        return (actual is None) == (str(expected).lower() == "true")
    if operator.endswith("IfExists") and actual is None:
        return True
    operator = operator.removesuffix("IfExists")
    if operator in {"StringLike", "ArnLike", "StringNotLike", "ArnNotLike"}:
        result = actual is not None and matches(actual, expected)
    elif operator in {"StringEquals", "ArnEquals", "StringNotEquals", "ArnNotEquals", "Bool"}:
        result = actual is not None and actual in values(expected)
    else:
        raise ValueError(f"Unsupported condition operator: {operator}")
    return not result if "Not" in operator else result


def applies(statement, request):
    action, resource, context = request
    action_matches = matches(action.lower(), [p.lower() for p in values(
        statement.get("Action", statement.get("NotAction", "*")))])
    resource_matches = matches(resource, statement.get("Resource", statement.get("NotResource", "*")))
    if "NotAction" in statement:
        action_matches = not action_matches
    if "NotResource" in statement:
        resource_matches = not resource_matches
    return action_matches and resource_matches and all(
        condition_value(operator, context.get(key), expected)
        for operator, entries in statement.get("Condition", {}).items()
        for key, expected in entries.items()
    )


def decision(statements, request):
    matched = [s for s in statements if applies(s, request)]
    if any(s["Effect"] == "Deny" for s in matched):
        return "Deny"
    return "Allow" if any(s["Effect"] == "Allow" for s in matched) else "ImplicitDeny"
