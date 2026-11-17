"""Group unresolved permissions without treating known gaps as authorization."""
from collections import Counter


def unresolved(rows):
    fields = ("type", "handler", "action", "decision")
    counts = Counter(tuple(row[key] for key in fields) for row in rows
                     if row["decision"] not in {"Allow", "NotApplicable"})
    return [{**dict(zip(fields, key)), "count": count} for key, count in sorted(counts.items())]
