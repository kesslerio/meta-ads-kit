#!/usr/bin/env bash
# meta-ads.sh — Pull Meta Ads data via social-cli
#
# Usage:
#   meta-ads.sh daily-check [--account act_123]
#   meta-ads.sh overview [--account act_123] [--preset last_7d]
#   meta-ads.sh campaigns [--account act_123] [--status ACTIVE]
#   meta-ads.sh top-creatives [--account act_123] [--preset last_7d] [--limit 10]
#   meta-ads.sh bleeders [--account act_123] [--preset last_7d] [--cpa-threshold 50]
#   meta-ads.sh winners [--account act_123] [--preset last_7d]
#   meta-ads.sh fatigue-check [--account act_123]
#   meta-ads.sh wow-events [--account act_123] [--preset last_7d|last_28d]
#   meta-ads.sh four-week-funnel [--account act_123] [--as-of YYYY-MM-DD]
#   meta-ads.sh custom [--account act_123] [--level ad] [--fields ...] [--breakdowns ...] [--since YYYY-MM-DD --until YYYY-MM-DD]

set -euo pipefail

# Check social-cli is installed
if ! command -v social &>/dev/null; then
  echo "ERROR: social-cli not installed. Run: npm install -g @vishalgojha/social-cli" >&2
  exit 1
fi

# Defaults
MODE="${1:-daily-check}"
shift 2>/dev/null || true
ACCOUNT="${META_AD_ACCOUNT:-}"
PRESET="last_7d"
LIMIT=25
STATUS=""
CPA_THRESHOLD=""
LEVEL=""
FIELDS=""
BREAKDOWNS=""
SINCE=""
UNTIL=""
COMPARE_SINCE=""
COMPARE_UNTIL=""
AS_OF=""

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --account)    ACCOUNT="$2"; shift 2 ;;
    --preset)     PRESET="$2"; shift 2 ;;
    --limit)      LIMIT="$2"; shift 2 ;;
    --status)     STATUS="$2"; shift 2 ;;
    --cpa-threshold) CPA_THRESHOLD="$2"; shift 2 ;;
    --level)      LEVEL="$2"; shift 2 ;;
    --fields)     FIELDS="$2"; shift 2 ;;
    --breakdowns) BREAKDOWNS="$2"; shift 2 ;;
    --since)      SINCE="$2"; shift 2 ;;
    --until)      UNTIL="$2"; shift 2 ;;
    --compare-since) COMPARE_SINCE="$2"; shift 2 ;;
    --compare-until) COMPARE_UNTIL="$2"; shift 2 ;;
    --as-of)      AS_OF="$2"; shift 2 ;;
    *)            echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Normalize account ID
normalize_act() {
  local act="$1"
  if [[ -n "$act" && ! "$act" =~ ^act_ ]]; then
    echo "act_${act}"
  else
    echo "$act"
  fi
}

get_default_account() {
  if [[ -f "$HOME/.social-cli/config.json" ]]; then
    jq -r '.profiles[.activeProfile].defaults.marketingAdAccountId // empty' \
      "$HOME/.social-cli/config.json" 2>/dev/null || true
  fi
}

ACCOUNT=$(normalize_act "$ACCOUNT")
if [[ -z "$ACCOUNT" ]]; then
  ACCOUNT="$(normalize_act "$(get_default_account)")"
fi
ACCOUNT_ARG=""
[[ -n "$ACCOUNT" ]] && ACCOUNT_ARG="$ACCOUNT"

# Helper: run social command with --json and suppress banner
run_social() {
  social --no-banner "$@" --json 2>/dev/null
}

# Helper: strip social-cli chrome while preserving actionable API errors.
filter_social_output() {
  grep -v "token gymnastics" | grep -v "Chaos Craft"
}

# Helper: run social command with table output
run_social_table() {
  if [[ "${1:-}" == "marketing" && "${2:-}" == "status" ]]; then
    social --no-banner "$@" 2>&1 | filter_social_output
  else
    social --no-banner "$@" --table 2>&1 | filter_social_output
  fi
}

fmt_num() { printf "%'d" "${1:-0}" 2>/dev/null || echo "${1:-0}"; }
fmt_money() { printf "$%'.2f" "${1:-0}" 2>/dev/null || echo "\$${1:-0}"; }
fmt_pct() { printf "%.1f%%" "${1:-0}" 2>/dev/null || echo "${1:-0}%"; }

require_date() {
  local value="$1"
  local label="$2"
  if [[ ! "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "ERROR: $label must be YYYY-MM-DD, got: $value" >&2
    exit 2
  fi
}

date_offset() {
  date -d "$1 $2 days" +%F
}

date_epoch_utc() {
  TZ=UTC date -d "$1" +%s
}

resolve_current_window() {
  local preset="$1"
  local as_of="${AS_OF:-$(date +%F)}"
  require_date "$as_of" "--as-of"

  if [[ -n "$SINCE" || -n "$UNTIL" ]]; then
    [[ -n "$SINCE" && -n "$UNTIL" ]] || {
      echo "ERROR: --since and --until must be provided together" >&2
      exit 2
    }
    require_date "$SINCE" "--since"
    require_date "$UNTIL" "--until"
    echo "$SINCE $UNTIL"
    return
  fi

  case "$preset" in
    today)     echo "$as_of $as_of" ;;
    yesterday)
      local yesterday
      yesterday="$(date_offset "$as_of" -1)"
      echo "$yesterday $yesterday"
      ;;
    last_7d)   echo "$(date_offset "$as_of" -6) $as_of" ;;
    last_28d)  echo "$(date_offset "$as_of" -27) $as_of" ;;
    last_30d)  echo "$(date_offset "$as_of" -29) $as_of" ;;
    last_90d)  echo "$(date_offset "$as_of" -89) $as_of" ;;
    *)
      echo "ERROR: unsupported preset for comparison report: $preset" >&2
      exit 2
      ;;
  esac
}

resolve_previous_window() {
  local current_since="$1"
  local current_until="$2"

  if [[ -n "$COMPARE_SINCE" || -n "$COMPARE_UNTIL" ]]; then
    [[ -n "$COMPARE_SINCE" && -n "$COMPARE_UNTIL" ]] || {
      echo "ERROR: --compare-since and --compare-until must be provided together" >&2
      exit 2
    }
    require_date "$COMPARE_SINCE" "--compare-since"
    require_date "$COMPARE_UNTIL" "--compare-until"
    echo "$COMPARE_SINCE $COMPARE_UNTIL"
    return
  fi

  local days previous_until previous_since
  days=$(( ($(date_epoch_utc "$current_until") - $(date_epoch_utc "$current_since")) / 86400 + 1 ))
  previous_until="$(date_offset "$current_since" -1)"
  previous_since="$(date_offset "$previous_until" "$((1 - days))")"
  echo "$previous_since $previous_until"
}

get_meta_token() {
  if [[ -n "${META_TOKEN:-}" ]]; then
    echo "$META_TOKEN"
    return
  fi

  if [[ -f "$HOME/.social-cli/config.json" ]]; then
    jq -r '.profiles[.activeProfile].tokens.facebook // .meta_access_token // .access_token // empty' \
      "$HOME/.social-cli/config.json" 2>/dev/null || true
  fi
}

require_graph_context() {
  if [[ -z "$ACCOUNT" ]]; then
    echo "ERROR: explicit date-window reports require --account or META_AD_ACCOUNT" >&2
    exit 2
  fi
}

run_graph_insights_json() {
  local output="$1"
  local since="$2"
  local until="$3"
  local level="${4:-account}"
  local fields="${5:-spend,actions,cost_per_action_type}"
  local breakdowns="${6:-}"
  local limit="${7:-500}"
  local token account_id time_range query url

  require_graph_context
  token="$(get_meta_token)"
  if [[ -z "$token" ]]; then
    echo "WARN: no Meta token found in META_TOKEN or ~/.social-cli/config.json" >&2
    return 1
  fi

  account_id="${ACCOUNT#act_}"
  time_range="$(jq -nc --arg since "$since" --arg until "$until" '{since:$since,until:$until}')"
  query="fields=$(jq -nr --arg v "$fields" '$v|@uri')"
  query="${query}&level=$(jq -nr --arg v "$level" '$v|@uri')"
  query="${query}&time_range=$(jq -nr --arg v "$time_range" '$v|@uri')"
  query="${query}&limit=$(jq -nr --arg v "$limit" '$v|@uri')"
  if [[ -n "$breakdowns" ]]; then
    query="${query}&breakdowns=$(jq -nr --arg v "$breakdowns" '$v|@uri')"
  fi

  url="https://graph.facebook.com/v19.0/act_${account_id}/insights?${query}&access_token=${token}"
  curl -sf "$url" > "$output"
}

run_social_insights_json() {
  local output="$1"
  local preset="$2"
  local level="${3:-account}"
  local fields="${4:-spend,actions,cost_per_action_type}"
  local breakdowns="${5:-}"
  local limit="${6:-500}"

  local args=(marketing insights)
  [[ -n "$ACCOUNT_ARG" ]] && args+=("$ACCOUNT_ARG")
  args+=(--preset "$preset" --level "$level" --json --export "$output" --export-format json --fields "$fields" --limit "$limit")
  [[ -n "$breakdowns" ]] && args+=(--breakdowns "$breakdowns")

  social --no-banner "${args[@]}" >/dev/null 2>/dev/null
}

detect_demo_booked_action_type() {
  local token account_id response

  token="$(get_meta_token)"
  [[ -z "$token" || -z "$ACCOUNT" ]] && return 1

  account_id="${ACCOUNT#act_}"
  response="$(curl -sf "https://graph.facebook.com/v19.0/act_${account_id}/customconversions?fields=id,name,custom_event_type,rule&limit=500&access_token=${token}" 2>/dev/null || true)"
  [[ -z "$response" ]] && return 1

  echo "$response" | jq -r '
    .data[]? |
    select((.rule | tostring | test("invitee_meeting_scheduled"; "i")) and (.rule | tostring | test("demo"; "i"))) |
    "offsite_conversion.custom.\(.id)"
  ' | head -1
}

# ============================================
# REPORT: daily-check (The 5 Daily Questions)
# ============================================
report_daily_check() {
  echo "═══════════════════════════════════════"
  echo "  META ADS — DAILY CHECK"
  echo "  The 5 Questions That Matter"
  [[ -n "$ACCOUNT" ]] && echo "  Account: $ACCOUNT"
  echo "═══════════════════════════════════════"
  echo ""

  # Q1: What's my spend vs yesterday?
  echo "① SPEND: Am I on track?"
  echo "---"
  social --no-banner marketing status $ACCOUNT_ARG 2>&1 | filter_social_output | grep -v "^$" || echo "  Meta auth failed. Run: social auth login --oauth --long-lived --scope ads_read,ads_management,read_insights"
  echo ""

  # Q2: Which campaigns are active and what's their status?
  echo "② CAMPAIGNS: What's running?"
  echo "---"
  social --no-banner marketing campaigns $ACCOUNT_ARG --status ACTIVE --table 2>&1 | filter_social_output | head -20 || echo "  No active campaigns found"
  echo ""

  # Q3: What are the insights for last 7 days?
  echo "③ PERFORMANCE: Last 7 days"
  echo "---"
  social --no-banner marketing insights $ACCOUNT_ARG --preset last_7d --level campaign --table 2>&1 | filter_social_output | head -20 || echo "  No insights data"
  echo ""

  # Q4: Ad-level performance (find bleeders and winners)
  echo "④ AD PERFORMANCE: Winners & losers"
  echo "---"
  local tmpfile="/tmp/meta-ads-insights-$$.json"
  social --no-banner marketing insights $ACCOUNT_ARG --preset last_7d --level ad --json --fields "ad_name,spend,impressions,clicks,cpc,ctr,actions,cost_per_action_type" 2>/dev/null > "$tmpfile" || true

  if [[ -s "$tmpfile" ]]; then
    # Top spenders
    echo "  Top spending ads (last 7d):"
    jq -r '
      if type == "array" then
        sort_by(-.spend) | .[0:5][] |
        "  • \(.ad_name // "Unknown") — $\(.spend // 0) spend, \(.ctr // "?")% CTR, $\(.cpc // "?") CPC"
      elif .data then
        .data | sort_by(-.spend) | .[0:5][] |
        "  • \(.ad_name // "Unknown") — $\(.spend // 0) spend, \(.ctr // "?")% CTR, $\(.cpc // "?") CPC"
      else
        "  No ad-level data available"
      end
    ' "$tmpfile" 2>/dev/null || echo "  Parsing insights..."
    rm -f "$tmpfile"
  else
    echo "  No ad-level insights available"
  fi
  echo ""

  # Q5: Creative fatigue signals
  echo "⑤ CREATIVE: Any fatigue signals?"
  echo "---"
  echo "  Check daily breakdown for CTR decline over time:"
  social --no-banner marketing insights $ACCOUNT_ARG --preset last_7d --level ad --time-increment 1 --table --fields "ad_name,impressions,ctr,cpc,frequency" 2>&1 | filter_social_output | head -15 || echo "  No daily breakdown available"
  echo ""
  echo "  ↑ Watch for: CTR dropping day-over-day, frequency >3, CPC rising"
}

# ============================================
# REPORT: overview
# ============================================
report_overview() {
  echo "Meta Ads Overview — ${PRESET}"
  [[ -n "$ACCOUNT" ]] && echo "Account: $ACCOUNT"
  echo "================================"
  echo ""

  # Account status
  echo "Account Status:"
  run_social_table marketing status $ACCOUNT_ARG
  echo ""

  # Insights
  echo "Performance Summary:"
  run_social_table marketing insights $ACCOUNT_ARG --preset "$PRESET" --level account
  echo ""

  # Campaign breakdown
  echo "By Campaign:"
  run_social_table marketing insights $ACCOUNT_ARG --preset "$PRESET" --level campaign
}

# ============================================
# REPORT: campaigns
# ============================================
report_campaigns() {
  echo "Active Campaigns"
  [[ -n "$ACCOUNT" ]] && echo "Account: $ACCOUNT"
  echo "================================"
  echo ""

  local status_filter=""
  [[ -n "$STATUS" ]] && status_filter="--status $STATUS"

  run_social_table marketing campaigns $ACCOUNT_ARG $status_filter
}

# ============================================
# REPORT: top-creatives
# ============================================
report_top_creatives() {
  echo "Top Creatives — ${PRESET}"
  [[ -n "$ACCOUNT" ]] && echo "Account: $ACCOUNT"
  echo "================================"
  echo ""

  run_social_table marketing insights $ACCOUNT_ARG --preset "$PRESET" --level ad --fields "ad_name,spend,impressions,clicks,ctr,cpc,actions,cost_per_action_type"
}

# ============================================
# REPORT: bleeders (high spend, low performance)
# ============================================
report_bleeders() {
  echo "🩸 Potential Bleeders — ${PRESET}"
  [[ -n "$ACCOUNT" ]] && echo "Account: $ACCOUNT"
  echo "================================"
  echo ""
  echo "Ads with high spend and poor CTR/CPC (candidates for pause):"
  echo ""

  local tmpfile="/tmp/meta-ads-bleeders-$$.json"
  social --no-banner marketing insights $ACCOUNT_ARG --preset "$PRESET" --level ad --json --fields "ad_name,adset_name,campaign_name,spend,impressions,clicks,ctr,cpc,actions,cost_per_action_type,frequency" 2>/dev/null > "$tmpfile" || true

  if [[ -s "$tmpfile" ]]; then
    jq -r '
      def parse_num: if . == null then 0 elif type == "string" then (tonumber? // 0) else . end;
      (if type == "array" then . elif .data then .data else [] end) |
      map(select(.spend | parse_num > 0)) |
      sort_by(-(.spend | parse_num)) |
      .[] |
      select((.ctr | parse_num) < 1.0 or (.frequency | parse_num) > 3.5) |
      "⚠️  \(.ad_name // "Unknown")\n   Campaign: \(.campaign_name // "?")\n   Spend: $\(.spend) | CTR: \(.ctr)% | CPC: $\(.cpc) | Freq: \(.frequency)\n"
    ' "$tmpfile" 2>/dev/null || echo "No bleeders detected (or data format unexpected)"
    rm -f "$tmpfile"
  else
    echo "No insights data available"
  fi
}

# ============================================
# REPORT: winners (high ROAS / low CPA)
# ============================================
report_winners() {
  echo "🏆 Winners — ${PRESET}"
  [[ -n "$ACCOUNT" ]] && echo "Account: $ACCOUNT"
  echo "================================"
  echo ""
  echo "Top performing ads by CTR and efficiency:"
  echo ""

  local tmpfile="/tmp/meta-ads-winners-$$.json"
  social --no-banner marketing insights $ACCOUNT_ARG --preset "$PRESET" --level ad --json --fields "ad_name,adset_name,campaign_name,spend,impressions,clicks,ctr,cpc,actions,cost_per_action_type" 2>/dev/null > "$tmpfile" || true

  if [[ -s "$tmpfile" ]]; then
    jq -r '
      def parse_num: if . == null then 0 elif type == "string" then (tonumber? // 0) else . end;
      (if type == "array" then . elif .data then .data else [] end) |
      map(select(.spend | parse_num > 0)) |
      sort_by(-(.ctr | parse_num)) |
      .[0:10][] |
      "🏆 \(.ad_name // "Unknown")\n   Campaign: \(.campaign_name // "?")\n   Spend: $\(.spend) | CTR: \(.ctr)% | CPC: $\(.cpc) | Clicks: \(.clicks)\n"
    ' "$tmpfile" 2>/dev/null || echo "No data (or format unexpected)"
    rm -f "$tmpfile"
  else
    echo "No insights data available"
  fi
}

# ============================================
# REPORT: fatigue-check
# ============================================
report_fatigue_check() {
  echo "😴 Creative Fatigue Check — Last 7 days (daily)"
  [[ -n "$ACCOUNT" ]] && echo "Account: $ACCOUNT"
  echo "================================"
  echo ""
  echo "Watching for: frequency >3, CTR declining day-over-day, CPC rising"
  echo ""

  run_social_table marketing insights $ACCOUNT_ARG --preset last_7d --level ad --time-increment 1 --fields "ad_name,date_start,impressions,ctr,cpc,frequency"
}

# ============================================
# REPORT: custom
# ============================================
report_custom() {
  local level="${LEVEL:-account}"
  local fields="${FIELDS:-spend,impressions,clicks,ctr,cpc,cpm}"

  if [[ -n "$SINCE" || -n "$UNTIL" ]]; then
    [[ -n "$SINCE" && -n "$UNTIL" ]] || {
      echo "ERROR: --since and --until must be provided together" >&2
      exit 2
    }
    require_date "$SINCE" "--since"
    require_date "$UNTIL" "--until"

    local tmpfile="/tmp/meta-ads-custom-$$.json"
    run_graph_insights_json "$tmpfile" "$SINCE" "$UNTIL" "$level" "$fields" "$BREAKDOWNS" "$LIMIT"
    jq . "$tmpfile"
    rm -f "$tmpfile"
    return
  fi

  local args=()
  [[ -n "$ACCOUNT_ARG" ]] && args+=("$ACCOUNT_ARG")
  [[ -n "$PRESET" ]] && args+=(--preset "$PRESET")
  [[ -n "$level" ]] && args+=(--level "$level")
  [[ -n "$fields" ]] && args+=(--fields "$fields")
  [[ -n "$BREAKDOWNS" ]] && args+=(--breakdowns "$BREAKDOWNS")
  [[ -n "$LIMIT" ]] && args+=(--limit "$LIMIT")

  run_social_table marketing insights "${args[@]}"
}

# ============================================
# REPORT: event comparisons
# ============================================
format_event_comparison() {
  local comparison_file="$1"

  jq -r '
    def money($v): "$" + (($v // 0) | tonumber | .*100 | round / 100 | tostring);
    def pct($current; $previous):
      if $previous == null then "unavailable"
      elif ($previous // 0) == 0 then
        if ($current // 0) == 0 then "0%" else "new" end
      else
        (((($current - $previous) / $previous) * 10000 | round / 100) | tostring) + "%"
      end;
    def delta($current; $previous):
      if $previous == null then "unavailable"
      else
        (($current // 0) - ($previous // 0)) as $d |
        if $d > 0 then "+" + ($d | tostring) else ($d | tostring) end
      end;
    def cpa($spend; $count):
      if $spend == null or $count == null or ($count // 0) == 0 then "n/a" else money($spend / $count) end;
    def maybe_num($v): if $v == null then "unavailable" else ($v | tostring) end;

    . as $root |
    "Spend:\n" +
    "  Current: " + money($root.current_spend) + "\n" +
    "  Previous: " + (if $root.previous_spend == null then "unavailable" else money($root.previous_spend) end) + "\n" +
    "  Change: " + pct($root.current_spend; $root.previous_spend) + "\n\n" +
    "Traffic:\n" +
    "  Impressions: " + maybe_num($root.current_impressions) + " vs " + maybe_num($root.previous_impressions) + " (" + delta($root.current_impressions; $root.previous_impressions) + ", " + pct($root.current_impressions; $root.previous_impressions) + ")\n" +
    "  Clicks: " + maybe_num($root.current_clicks) + " vs " + maybe_num($root.previous_clicks) + " (" + delta($root.current_clicks; $root.previous_clicks) + ", " + pct($root.current_clicks; $root.previous_clicks) + ")\n\n" +
    "Events:\n" +
    ([
      $root.metrics[] |
      if .unavailable then
        "  " + .label + "\n" +
        "    Status: " + .unavailable
      else
        "  " + .label + "\n" +
        "    Current: " + (.current_count | tostring) + " at " + cpa($root.current_spend; .current_count) + "\n" +
        "    Previous: " + (if .previous_count == null then "unavailable" else (.previous_count | tostring) + " at " + cpa($root.previous_spend; .previous_count) end) + "\n" +
        "    Count change: " + delta(.current_count; .previous_count) + " (" + pct(.current_count; .previous_count) + ")"
      end
    ] | join("\n")) +
    (if $root.fallback_note then "\n\nData note: " + $root.fallback_note else "" end)
  ' "$comparison_file"
}

render_event_comparison_social_fallback() {
  local title="$1"
  local current_since="$2"
  local current_until="$3"
  local previous_since="$4"
  local previous_until="$5"
  local fallback_preset="$6"
  local current_file total_file comparison_file total_preset

  current_file="/tmp/meta-ads-current-social-$$.json"
  total_file="/tmp/meta-ads-total-social-$$.json"
  comparison_file="/tmp/meta-ads-event-comparison-social-$$.json"

  echo "$title"
  [[ -n "$ACCOUNT" ]] && echo "Account: $ACCOUNT"
  echo "================================"
  echo ""
  echo "Current window: ${current_since} to ${current_until}"
  echo "Previous window: ${previous_since} to ${previous_until}"
  echo ""

  case "$fallback_preset" in
    last_7d) total_preset="last_14d" ;;
    last_28d) total_preset="" ;;
    *)
      echo "No Graph token available, and social-cli fallback does not support ${fallback_preset} comparisons."
      rm -f "$current_file" "$total_file" "$comparison_file"
      return 1
      ;;
  esac

  if ! run_social_insights_json "$current_file" "$fallback_preset" account "spend,impressions,clicks,actions,cost_per_action_type" "" 500; then
    echo "No Meta insights data available from social-cli fallback"
    rm -f "$current_file" "$total_file" "$comparison_file"
    return 1
  fi

  if [[ -n "$total_preset" ]]; then
    run_social_insights_json "$total_file" "$total_preset" account "spend,impressions,clicks,actions,cost_per_action_type" "" 500 || true
  fi

  if [[ -n "$total_preset" && -s "$total_file" ]]; then
    jq -n --slurpfile current "$current_file" --slurpfile total "$total_file" '
      def firstrow($x): (($x[0] // []) | if type == "array" then .[0] elif .data then .data[0] else . end) // {};
      def num: if . == null then 0 elif type == "string" then (tonumber? // 0) else . end;
      def action($row; $name):
        ($row.actions // [] | map(select(.action_type == $name)) | .[0].value // 0) | num;
      def metric($label; $action):
        {
          label: $label,
          action_type: $action,
          current_count: action(firstrow($current); $action),
          previous_count: (action(firstrow($total); $action) - action(firstrow($current); $action))
        };
      firstrow($current) as $c |
      firstrow($total) as $t |
      {
        current_spend: ($c.spend | num),
        previous_spend: (($t.spend | num) - ($c.spend | num)),
        current_impressions: ($c.impressions | num),
        previous_impressions: (($t.impressions | num) - ($c.impressions | num)),
        current_clicks: ($c.clicks | num),
        previous_clicks: (($t.clicks | num) - ($c.clicks | num)),
        fallback_note: "Used social-cli preset exports because no directly readable Graph token was available; Demo Booked custom-conversion discovery is unavailable without Graph access.",
        metrics: [
          metric("InitiateCheckout"; "initiate_checkout"),
          metric("Purchase"; "purchase"),
          metric("Lead"; "lead"),
          metric("Demo Request (Schedule)"; "offsite_conversion.custom.931521642127214"),
          {
            label: "Demo Booked (Calendly / Qualified Booking)",
            action_type: null,
            current_count: null,
            previous_count: null,
            unavailable: "No Graph token available for custom-conversion discovery."
          }
        ]
      }
    ' > "$comparison_file"
  else
    jq -n --slurpfile current "$current_file" '
      def firstrow($x): (($x[0] // []) | if type == "array" then .[0] elif .data then .data[0] else . end) // {};
      def num: if . == null then 0 elif type == "string" then (tonumber? // 0) else . end;
      def action($row; $name):
        ($row.actions // [] | map(select(.action_type == $name)) | .[0].value // 0) | num;
      def metric($label; $action):
        {
          label: $label,
          action_type: $action,
          current_count: action(firstrow($current); $action),
          previous_count: null
        };
      firstrow($current) as $c |
      {
        current_spend: ($c.spend | num),
        previous_spend: null,
        current_impressions: ($c.impressions | num),
        previous_impressions: null,
        current_clicks: ($c.clicks | num),
        previous_clicks: null,
        fallback_note: "Used social-cli current-window export because no directly readable Graph token was available; prior-window comparison requires Graph date windows.",
        metrics: [
          metric("InitiateCheckout"; "initiate_checkout"),
          metric("Purchase"; "purchase"),
          metric("Lead"; "lead"),
          metric("Demo Request (Schedule)"; "offsite_conversion.custom.931521642127214"),
          {
            label: "Demo Booked (Calendly / Qualified Booking)",
            action_type: null,
            current_count: null,
            previous_count: null,
            unavailable: "No Graph token available for custom-conversion discovery."
          }
        ]
      }
    ' > "$comparison_file"
  fi

  format_event_comparison "$comparison_file"
  rm -f "$current_file" "$total_file" "$comparison_file"
}

render_event_comparison() {
  local title="$1"
  local current_since="$2"
  local current_until="$3"
  local previous_since="$4"
  local previous_until="$5"
  local fallback_preset="${6:-}"
  local current_file previous_file comparison_file
  local demo_booked_action="${META_DEMO_BOOKED_ACTION_TYPE:-}"

  current_file="/tmp/meta-ads-current-events-$$.json"
  previous_file="/tmp/meta-ads-previous-events-$$.json"
  comparison_file="/tmp/meta-ads-event-comparison-$$.json"

  if [[ -z "$demo_booked_action" ]]; then
    demo_booked_action="$(detect_demo_booked_action_type || true)"
  fi

  if ! run_graph_insights_json \
    "$current_file" "$current_since" "$current_until" account \
    "spend,impressions,clicks,actions,cost_per_action_type" "" 500; then
    rm -f "$current_file" "$previous_file" "$comparison_file"
    render_event_comparison_social_fallback "$title" "$current_since" "$current_until" "$previous_since" "$previous_until" "$fallback_preset"
    return
  fi

  if ! run_graph_insights_json \
    "$previous_file" "$previous_since" "$previous_until" account \
    "spend,impressions,clicks,actions,cost_per_action_type" "" 500; then
    rm -f "$current_file" "$previous_file" "$comparison_file"
    render_event_comparison_social_fallback "$title" "$current_since" "$current_until" "$previous_since" "$previous_until" "$fallback_preset"
    return
  fi

  echo "$title"
  [[ -n "$ACCOUNT" ]] && echo "Account: $ACCOUNT"
  echo "================================"
  echo ""
  echo "Current window: ${current_since} to ${current_until}"
  echo "Previous window: ${previous_since} to ${previous_until}"
  echo ""

  if [[ ! -s "$current_file" || ! -s "$previous_file" ]]; then
    echo "No Meta insights data available for event comparison"
    rm -f "$current_file" "$previous_file" "$comparison_file"
    return 1
  fi

  jq -n --slurpfile current "$current_file" --slurpfile previous "$previous_file" '
    def firstrow($x): (($x[0] // []) | if type == "array" then .[0] elif .data then .data[0] else . end) // {};
    def num: if . == null then 0 elif type == "string" then (tonumber? // 0) else . end;
    def action($row; $name):
      ($row.actions // [] | map(select(.action_type == $name)) | .[0].value // 0) | num;
    def metric($label; $action):
      {
        label: $label,
        action_type: $action,
        current_count: action(firstrow($current); $action),
        previous_count: action(firstrow($previous); $action)
      };
    firstrow($current) as $c |
    firstrow($previous) as $p |
    {
      current_spend: ($c.spend | num),
      previous_spend: ($p.spend | num),
      current_impressions: ($c.impressions | num),
      previous_impressions: ($p.impressions | num),
      current_clicks: ($c.clicks | num),
      previous_clicks: ($p.clicks | num),
      metrics: [
        metric("InitiateCheckout"; "initiate_checkout"),
        metric("Purchase"; "purchase"),
        metric("Lead"; "lead"),
        metric("Demo Request (Schedule)"; "offsite_conversion.custom.931521642127214"),
        if $demoBookedAction == "" then
          {
            label: "Demo Booked (Calendly / Qualified Booking)",
            action_type: null,
            current_count: null,
            previous_count: null,
            unavailable: "No attributed custom conversion found. Audience rule exists for invitee_meeting_scheduled where event_type_name contains demo, but audiences do not produce cost-per-event insight actions."
          }
        else
          metric("Demo Booked (Calendly / Qualified Booking)"; $demoBookedAction)
        end
      ]
    }
  ' --arg demoBookedAction "$demo_booked_action" > "$comparison_file"

  format_event_comparison "$comparison_file"

  rm -f "$current_file" "$previous_file" "$comparison_file"
}

report_event_comparison_for_preset() {
  local current_window previous_window current_since current_until previous_since previous_until
  current_window="$(resolve_current_window "$PRESET")"
  read -r current_since current_until <<< "$current_window"
  previous_window="$(resolve_previous_window "$current_since" "$current_until")"
  read -r previous_since previous_until <<< "$previous_window"
  render_event_comparison "Meta Ads Funnel Event Comparison" "$current_since" "$current_until" "$previous_since" "$previous_until" "$PRESET"
}

report_four_week_funnel() {
  PRESET="last_28d"
  report_event_comparison_for_preset
}

# ============================================
# Dispatch
# ============================================
case "$MODE" in
  daily-check|daily|check|5questions) report_daily_check ;;
  overview)                           report_overview ;;
  campaigns)                          report_campaigns ;;
  top-creatives|creatives)            report_top_creatives ;;
  bleeders|losers)                    report_bleeders ;;
  winners|tops)                       report_winners ;;
  fatigue-check|fatigue)              report_fatigue_check ;;
  wow-events|events-wow|weekly-events) report_event_comparison_for_preset ;;
  four-week-funnel|4week-funnel|four-week-events|28d-events) report_four_week_funnel ;;
  custom)                             report_custom ;;
  *)
    echo "Unknown mode: $MODE" >&2
    echo "Available: daily-check, overview, campaigns, top-creatives, bleeders, winners, fatigue-check, wow-events, four-week-funnel, custom" >&2
    exit 1
    ;;
esac
