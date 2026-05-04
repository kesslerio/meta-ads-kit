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
#   meta-ads.sh custom [--account act_123] [--level ad] [--fields ...] [--breakdowns ...]

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

ACCOUNT=$(normalize_act "$ACCOUNT")
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
  local args=()
  [[ -n "$ACCOUNT_ARG" ]] && args+=("$ACCOUNT_ARG")
  [[ -n "$PRESET" ]] && args+=(--preset "$PRESET")
  [[ -n "$LEVEL" ]] && args+=(--level "$LEVEL")
  [[ -n "$FIELDS" ]] && args+=(--fields "$FIELDS")
  [[ -n "$BREAKDOWNS" ]] && args+=(--breakdowns "$BREAKDOWNS")
  [[ -n "$LIMIT" ]] && args+=(--limit "$LIMIT")

  run_social_table marketing insights "${args[@]}"
}

# ============================================
# REPORT: wow-events
# ============================================
report_wow_events() {
  local current_file previous_file total_file
  current_file="/tmp/meta-ads-current-7d-$$.json"
  total_file="/tmp/meta-ads-total-14d-$$.json"
  previous_file="/tmp/meta-ads-previous-7d-$$.json"

  echo "Meta Ads Week-over-Week Events"
  [[ -n "$ACCOUNT" ]] && echo "Account: $ACCOUNT"
  echo "================================"
  echo ""
  echo "Current window: last_7d"
  echo "Previous window: prior 7 days, derived from last_14d minus last_7d"
  echo ""

  social --no-banner marketing insights $ACCOUNT_ARG \
    --preset last_7d --level account --json \
    --fields "spend,actions,cost_per_action_type" \
    2>/dev/null > "$current_file" || true

  social --no-banner marketing insights $ACCOUNT_ARG \
    --preset last_14d --level account --json \
    --fields "spend,actions,cost_per_action_type" \
    2>/dev/null > "$total_file" || true

  if [[ ! -s "$current_file" || ! -s "$total_file" ]]; then
    echo "No Meta insights data available for WoW event comparison"
    rm -f "$current_file" "$total_file" "$previous_file"
    return 1
  fi

  jq -n --slurpfile current "$current_file" --slurpfile total "$total_file" '
    def firstrow($x): (($x[0] // []) | if type == "array" then .[0] else . end) // {};
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
      metrics: [
        metric("InitiateCheckout"; "initiate_checkout"),
        metric("Purchase"; "purchase"),
        metric("Lead"; "lead"),
        metric("Demo Request (Schedule)"; "offsite_conversion.custom.931521642127214")
      ]
    }
  ' > "$previous_file"

  jq -r '
    def money($v): "$" + (($v // 0) | tonumber | .*100 | round / 100 | tostring);
    def pct($current; $previous):
      if ($previous // 0) == 0 then
        if ($current // 0) == 0 then "0%" else "new" end
      else
        (((($current - $previous) / $previous) * 10000 | round / 100) | tostring) + "%"
      end;
    def cpa($spend; $count):
      if ($count // 0) == 0 then "n/a" else money($spend / $count) end;

    . as $root |
    "Spend:\n" +
    "  Current: " + money($root.current_spend) + "\n" +
    "  Previous: " + money($root.previous_spend) + "\n" +
    "  WoW: " + pct($root.current_spend; $root.previous_spend) + "\n\n" +
    "Events:\n" +
    ([
      $root.metrics[] |
      "  " + .label + "\n" +
      "    Current: " + (.current_count | tostring) + " at " + cpa($root.current_spend; .current_count) + "\n" +
      "    Previous: " + (.previous_count | tostring) + " at " + cpa($root.previous_spend; .previous_count) + "\n" +
      "    WoW count: " + pct(.current_count; .previous_count)
    ] | join("\n"))
  ' "$previous_file"

  rm -f "$current_file" "$total_file" "$previous_file"
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
  wow-events|events-wow|weekly-events) report_wow_events ;;
  custom)                             report_custom ;;
  *)
    echo "Unknown mode: $MODE" >&2
    echo "Available: daily-check, overview, campaigns, top-creatives, bleeders, winners, fatigue-check, wow-events, custom" >&2
    exit 1
    ;;
esac
