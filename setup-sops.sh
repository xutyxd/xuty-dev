#!/usr/bin/env bash

set -euo pipefail
# Generate age key if it doesn't exist
if [[ ! -f age.key ]]; then
    age-keygen -o age.key
else
    echo "Key age.key already exists. It will be used."
fi

# Get public key age
PUBLIC_KEY_AGE=$(grep "^# public key:" age.key | awk '{print $4}')

# Create file .sops.yaml
cat > .sops.yaml <<EOF
creation_rules:
  - path_regex: secrets/.*\.yaml$
    encrypted_regex: '^(data|stringData)$'
    age: ${PUBLIC_KEY_AGE}
EOF

echo "🚀 File .sops.yaml created!"