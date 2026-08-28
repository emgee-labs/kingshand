---
name: audience
description: Use when the user invokes /audience or asks what happened while they were away from this session - e.g. "/audience", "audience", "what did I miss", "recap this session", "what have you been doing". Recaps only the visible session events after the user's last real message, then walks them through every decision still visibly unanswered, one at a time. Falls back to survey when /audience is the session's first real user message.
user-invocable: true
version: 1.0.0
---

# Audience

Give the user a concise session-only recap without gathering fresh state.

1. Inspect only conversation or session history already visible to the current Hand.

2. Find the most recent real user-authored message before the current `/audience` invocation. A user
   boundary is an ordinary user-role message. System, tool, and other injected operational
   messages are not user messages. Never infer user authorship merely because a synthetic message
   appears in the user-role transcript.

3. If no prior real user message exists, load `$env:KINGSHAND_HOME\.claude\skills\survey\SKILL.md`
   and follow it exactly. Survey alone owns its gathering, artifact, and response contract. Do not
   restate that contract or combine a session recap with Survey output.

4. If a prior real user message exists, preserve the ordinary recap interval: recap what happened
   after that message and before the current invocation. Include concrete outcomes, landed work,
   failures, decisions made, new decisions needed, and work still running only when those events
   appear in that visible interval. Use user-facing outcome language and preserve every full PR
   URL present in that interval.

5. Additionally inspect the entire session history visible to the current Hand before the
   current invocation for every explicit user decision that remains unanswered, including
   decisions raised before the ordinary recap boundary. A later unrelated user message establishes
   a recap boundary but does not close an earlier decision. Treat a decision as closed only when a
   later visible response substantively resolves it, chooses an option, declines it, grants or
   denies the requested approval, or otherwise directly addresses that decision. Include every
   visibly supported open decision once, and deduplicate by the decision's substance when the
   ordinary interval recap already represents it or its wording differs.

6. The normal recap branch is session-history-only. Do not call Survey, shell commands, fleet
   snapshots, status readers, GitHub or browser APIs, tools, or file reads or writes. Create no
   report, persist nothing, and do not guess current live state beyond the last visible event.

7. If no ordinary events occurred after the previous user message but an older visibly open
   decision exists, report that decision instead of claiming nothing happened. If neither ordinary
   events nor visibly open decisions exist, say directly in one sentence that nothing happened
   after the previous user message.

8. After the normal recap, when the existing visibly open decision inventory contains decisions,
   begin a guided decision-clearing flow by presenting only the single open decision judged most
   impactful by the Hand. Make clear that impact ordering is the Hand's judgement rather
   than a mechanical score. Give enough escalation-quality context to decide easily: the decision,
   why it matters, the options, and a recommendation.

9. When the user answers the presented decision, present the next highest-impact decision from
   that existing inventory in the same form. Continue one decision at a time until none remain,
   without starting this flow when the inventory is empty.

The current `/audience` message is outside the recap interval. A previous `/audience` is a real user
message and may be the next interval boundary. If context compaction makes the prior boundary
unavailable, state that the exact session boundary is unavailable and summarize only visibly
supported events. Compacted history supports an open decision only when both its request and its
still-unanswered status are visible; report uncertainty instead of reconstructing hidden requests
or answers. Do not silently invoke Survey unless this is genuinely the first real user message.
