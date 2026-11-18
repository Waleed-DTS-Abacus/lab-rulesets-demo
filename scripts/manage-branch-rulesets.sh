
#!/usr/bin/env bash
set -euo pipefail

CSV_FILE="${1:?Usage: $0 <config.csv>}"

# Check dependencies
for cmd in gh jq; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: Missing dependency: $cmd" >&2
        exit 1
    }
done

[[ -f "$CSV_FILE" ]] || {
    echo "ERROR: CSV not found: $CSV_FILE" >&2
    exit 1
}

expected_header="owner,repo,branch,ruleset_name,enforcement,require_pr,required_approvals,block_force_push,block_deletion,required_status_check"
# Remove UTF-8 BOM and Windows CRLF
header=$(head -n 1 "$CSV_FILE")
header="${header#$'\xef\xbb\xbf'}"
header="${header%$'\r'}"

[[ "$header" == "$expected_header" ]] || {
    echo "ERROR: Invalid CSV header" >&2
    exit 1
}

validate_bool() {
    [[ "$1" == "true" || "$1" == "false" ]]
}

# Store validated rows before making API changes
declare -a validated_rows=()
declare -A seen_rulesets=()

echo "PHASE 1: Validating all CSV rows..."

line_number=1

while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number += 1))

    line="${line%$'\r'}"
    [[ -z "$line" ]] && continue

    # This CSV format uses simple, unquoted values.
    # Reject unsupported commas/extra columns.
    comma_count="${line//[^,]/}"
    if [[ ${#comma_count} -ne 9 ]]; then
        echo "ERROR: Invalid number of CSV columns at line $line_number" >&2
        exit 1
    fi

    IFS=, read -r owner repo branch ruleset_name enforcement require_pr required_approvals block_force_push block_deletion required_status_check <<< "$line"

    if [[ -z "$owner" || -z "$repo" || -z "$branch" || -z "$ruleset_name" ]]; then
        echo "ERROR: Missing required CSV value at line $line_number" >&2
        exit 1
    fi

    [[ "$enforcement" =~ ^(active|disabled|evaluate)$ ]] || {
        echo "ERROR: Invalid enforcement at line $line_number: $enforcement" >&2
        exit 1
    }

    for value in "$require_pr" "$block_force_push" "$block_deletion"; do
        validate_bool "$value" || {
            echo "ERROR: Invalid boolean at line $line_number: $value" >&2
            exit 1
        }
    done

    [[ "$required_approvals" =~ ^[0-9]+$ ]] || {
        echo "ERROR: Invalid required_approvals at line $line_number" >&2
        exit 1
    }

    if (( 10#$required_approvals > 6 )); then
        echo "ERROR: required_approvals exceeds GitHub limit at line $line_number" >&2
        exit 1
    fi

    if [[ "$require_pr" == "false" && "$required_approvals" != "0" ]]; then
        echo "ERROR: Approvals require a pull request rule at line $line_number" >&2
        exit 1
    fi

    key="$owner/$repo/$ruleset_name"

    if [[ -n "${seen_rulesets[$key]:-}" ]]; then
        echo "ERROR: Duplicate ruleset at line $line_number" >&2
        exit 1
    fi

    seen_rulesets["$key"]=1
    validated_rows+=("$line")

    echo "VALID: line $line_number ($ruleset_name)"

done < <(tail -n +2 "$CSV_FILE")

if [[ ${#validated_rows[@]} -eq 0 ]]; then
    echo "ERROR: CSV contains no configuration rows" >&2
    exit 1
fi

echo "PASS: All ${#validated_rows[@]} CSV rows validated."
echo ""
echo "PHASE 2: Applying GitHub Rulesets..."

for line in "${validated_rows[@]}"; do
    IFS=, read -r owner repo branch ruleset_name enforcement require_pr required_approvals block_force_push block_deletion required_status_check <<< "$line"

    echo "Processing $owner/$repo -> $branch ($ruleset_name)"

    rules=$(jq -n \
        --argjson require_pr "$require_pr" \
        --argjson approvals "$required_approvals" \
        --argjson force "$block_force_push" \
        --argjson deletion "$block_deletion" \
        --arg check "$required_status_check" '
        [
            (if $require_pr then
                {
                    type: "pull_request",
                    parameters: {
                        required_approving_review_count: $approvals,
                        dismiss_stale_reviews_on_push: false,
                        require_code_owner_review: false,
                        require_last_push_approval: false,
                        required_review_thread_resolution: false
                    }
                }
            else empty end),

            (if $force then
                {type: "non_fast_forward"}
            else empty end),

            (if $deletion then
                {type: "deletion"}
            else empty end),

            (if $check != "" then
                {
                    type: "required_status_checks",
                    parameters: {
                        strict_required_status_checks_policy: false,
                        do_not_enforce_on_create: false,
                        required_status_checks: [
                            {context: $check}
                        ]
                    }
                }
            else empty end)
        ]')

    payload=$(jq -n \
        --arg name "$ruleset_name" \
        --arg branch "refs/heads/$branch" \
        --arg enforcement "$enforcement" \
        --argjson rules "$rules" '
        {
            name: $name,
            target: "branch",
            enforcement: $enforcement,
            bypass_actors: [],
            conditions: {
                ref_name: {
                    include: [$branch],
                    exclude: []
                }
            },
            rules: $rules
        }')

    api="repos/$owner/$repo/rulesets"

    existing=$(gh api "$api" | jq -r \
        --arg name "$ruleset_name" \
        '.[] | select(.name == $name) | .id')

    if [[ -n "$existing" ]]; then
        echo "UPDATE: $ruleset_name (ID: $existing)"

        echo "$payload" | gh api --method PUT "$api/$existing" \
            --input - --jq '{id, name, enforcement}'
    else
        echo "CREATE: $ruleset_name"

        echo "$payload" | gh api --method POST "$api" \
            --input - --jq '{id, name, enforcement}'
    fi

    echo "--------------------------------"
done

echo "SUCCESS: All CSV rulesets processed"
