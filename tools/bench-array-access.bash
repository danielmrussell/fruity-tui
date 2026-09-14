#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  How much does it cost to look something up?
#
#  The framework addresses almost all of its state by CONTROL NAME — FT_ABSOLUTE_X[$name],
#  FT_TYPE[$name], the cascade caches — which means a string hash on every access.
#  The span renderer proposes integer control ids and stride-addressed flat arrays
#  instead. This measures whether that is actually worth doing.
#
#  Every case runs the same loop shape, and the empty-loop baseline is subtracted,
#  so what is reported is the cost of the access itself.
#
#      bash tools/bench-array-access.bash [iterations]
# ─────────────────────────────────────────────────────────────────────────────
set -u

iterations=${1:-100000}
entry_count=1000

declare -a integer_keyed=()
declare -A string_keyed=()
declare -A composite_keyed=()

for (( entry = 0; entry < entry_count; entry++ )); do
    integer_keyed[entry]=$entry
    string_keyed[control$entry]=$entry
    composite_keyed["control$entry"$'\x1f'"color"]=$entry
done

# Microseconds, fork-free (bash 5 exposes EPOCHREALTIME as seconds.microseconds).
now_microseconds() { local stamp=${EPOCHREALTIME/./}; printf '%s' "$stamp"; }

baseline_microseconds=0

# measure LABEL -- runs the named case and reports its per-operation cost
measure() {
    local label=$1 case_function=$2
    local started finished elapsed per_operation_nanoseconds
    started=$(now_microseconds)
    "$case_function"
    finished=$(now_microseconds)
    elapsed=$(( finished - started - baseline_microseconds ))
    (( elapsed < 0 )) && elapsed=0
    per_operation_nanoseconds=$(( elapsed * 1000 / iterations ))
    printf '  %-46s %6d ms total   %5d ns/op\n' \
           "$label" "$(( elapsed / 1000 ))" "$per_operation_nanoseconds"
}

case_empty_loop() {
    local index value
    for (( index = 0; index < iterations; index++ )); do value=$index; done
}
# The fair pair: one read, constant key, no arithmetic in either case.
case_integer_subscript_constant() {
    local index value
    for (( index = 0; index < iterations; index++ )); do value=${integer_keyed[500]}; done
}
case_integer_subscript_variable() {
    local index value id=500
    for (( index = 0; index < iterations; index++ )); do value=${integer_keyed[id]}; done
}
case_string_key_constant() {
    local index value
    for (( index = 0; index < iterations; index++ )); do value=${string_keyed[control500]}; done
}
case_integer_subscript() {
    local index value
    for (( index = 0; index < iterations; index++ )); do value=${integer_keyed[index % 1000]}; done
}
case_integer_subscript_with_stride() {
    local index value
    for (( index = 0; index < iterations; index++ )); do value=${integer_keyed[(index % 30) * 32 + 1]}; done
}
case_string_key_from_variable() {
    local index value key=control500
    for (( index = 0; index < iterations; index++ )); do value=${string_keyed[$key]}; done
}
case_string_key_built_each_time() {
    local index value
    for (( index = 0; index < iterations; index++ )); do value=${string_keyed[control$(( index % 1000 ))]}; done
}
case_composite_string_key() {
    local index value key=control500
    for (( index = 0; index < iterations; index++ )); do value=${composite_keyed["$key"$'\x1f'"color"]}; done
}
case_integer_subscript_in_arithmetic() {
    local index value
    for (( index = 0; index < iterations; index++ )); do (( value = integer_keyed[index % 1000] + 1 )); done
}
case_string_key_in_arithmetic() {
    local index value key=control500
    for (( index = 0; index < iterations; index++ )); do (( value = string_keyed[$key] + 1 )); done
}
case_four_reads_one_name() {          # what a paint does: several arrays, same control
    local index a b c d key=control500
    for (( index = 0; index < iterations; index++ )); do
        a=${string_keyed[$key]}; b=${string_keyed[$key]}
        c=${string_keyed[$key]}; d=${string_keyed[$key]}
    done
}
case_four_reads_one_integer_id() {
    local index a b c d id=500
    for (( index = 0; index < iterations; index++ )); do
        a=${integer_keyed[id]}; b=${integer_keyed[id]}
        c=${integer_keyed[id]}; d=${integer_keyed[id]}
    done
}

printf 'array access — %d iterations, %d entries\n\n' "$iterations" "$entry_count"

started=$(now_microseconds); case_empty_loop; finished=$(now_microseconds)
baseline_microseconds=$(( finished - started ))
printf '  %-46s %6d ms total   (subtracted from every case below)\n\n' \
       "empty loop (baseline)" "$(( baseline_microseconds / 1000 ))"

echo "  — like for like: one read, constant key, no arithmetic —"
measure "integer subscript, literal"               case_integer_subscript_constant
measure "integer subscript, from variable"         case_integer_subscript_variable
measure "string key, literal"                      case_string_key_constant
measure "string key, from variable"                case_string_key_from_variable
echo
echo "  — with the arithmetic / construction each pattern really needs —"
measure "integer subscript + modulo"               case_integer_subscript
measure "integer subscript, stride arithmetic"     case_integer_subscript_with_stride
measure "integer subscript inside (( ))"           case_integer_subscript_in_arithmetic
measure "string key, rebuilt each time"            case_string_key_built_each_time
measure "string key inside (( ))"                  case_string_key_in_arithmetic
measure "composite string key (cascade pattern)"   case_composite_string_key
echo
echo "  — what a paint actually does: several arrays, same control —"
measure "4 reads by control NAME"                  case_four_reads_one_name
measure "4 reads by integer ID"                    case_four_reads_one_integer_id
measure "4 reads by control NAME (again)"          case_four_reads_one_name
measure "4 reads by integer ID (again)"            case_four_reads_one_integer_id
