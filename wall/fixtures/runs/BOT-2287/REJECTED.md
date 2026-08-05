# Rejected

The sweep rewrote rounding at three call sites to share one helper, but billing
and payouts round in opposite directions on purpose. Collapsing them is a
pricing decision, not a refactor.
