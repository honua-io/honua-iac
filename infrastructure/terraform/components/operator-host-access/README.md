# Operator host access inputs

Validates the operator inputs shared by single-host bootstrap roots: SSH source CIDRs (no broad
internet access), the OpenSSH public key and the cost alert email. A root declares the variables,
passes them here and uses the outputs, so the validation policy lives in one place.
