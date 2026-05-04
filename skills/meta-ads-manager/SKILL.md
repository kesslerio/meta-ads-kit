---
name: meta-ads-manager
description: "Meta Ads read-only reporting alias for OpenClaw workspaces that already use meta-ads for copy generation. Provides daily checks, campaign performance, winners, bleeders, and fatigue reporting through social-cli."
metadata:
  openclaw:
    emoji: "📣"
    user-invocable: true
    requires:
      tools: ["social"]
      env: []
---

# Meta Ads Manager

This is the OpenClaw alias for the Meta Ads Kit reporting skill.

Use this skill for read-only Meta Ads reporting:

- Daily Meta Ads Check
- Week-over-week spend and conversion-event comparison
- Campaign performance
- Winners and bleeders
- Creative fatigue signals

The local `meta-ads` skill name is already used by ShapeScale ad-copy guidance in some workspaces, so this alias exposes the Meta Ads Kit reporting wrapper as `meta-ads-manager` without overwriting that skill.

## Scripts

```bash
scripts/meta-ads.sh daily-check
scripts/meta-ads.sh wow-events
scripts/meta-ads.sh overview --preset last_7d
scripts/meta-ads.sh custom --level campaign --fields "campaign_name,spend,impressions,clicks,actions,cost_per_action_type"
```

## Safety

This alias is for reporting and analysis. Do not mutate campaigns, ads, ad sets, budgets, uploads, pauses, or resumes from scheduled reporting.
