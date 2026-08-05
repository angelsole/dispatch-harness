# Rejected

Sessions move to Redis but nothing evicts them: the TTL is never set, so a
restart leaks every session forever. That needs a design decision, not a patch.
