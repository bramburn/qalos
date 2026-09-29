# Parallel Subagent Pattern

## When to use this skill

Trigger when the user asks to:
- "Run two subagents at the same time"
- "Compare X vs Y" (two agents, one with each option)
- "One with thinking, one without" (A/B on reasoning mode)
- "Run multiple agents in parallel"
- Any task where **independent, concurrent work** is faster than sequential work

## Prerequisites

- `task` tool is available (it is — it's in the standard tool list)
- `minimax/MiniMax-M3` model supports the `effort` parameter (`on` = thinking, `off` = no thinking)

## How to run two subagents in parallel

### Pattern 1: A/B comparison (thinking vs no-thinking, different models, etc.)

```python
# Run two tasks simultaneously — both start at the same instant
task(
    description="Subagent WITH thinking - MyInsta research",
    prompt="Search the web for how MyInsta was built...",
    agent_name="mavis",
    model="minimax/MiniMax-M3",
    effort="on"   # ← thinking enabled
)

task(
    description="Subagent WITHOUT thinking - MyInsta research",
    prompt="Search the web for how MyInsta was built...",
    agent_name="mavis",
    model="minimax/MiniMax-M3",
    effort="off"  # ← thinking disabled
)
```

Both calls return `task_result` objects with `task_id` values (e.g. `bg_9ca11e2f-6020-4b7e-9b50-e8f961fa4b1c`). The runtime executes them concurrently — the wall-clock time is the **slowest** agent, not the sum.

### Pattern 2: Fan-out (N agents, N≥2)

For research that benefits from multiple independent perspectives:

```python
task(description="...", agent_name="mavis", model="minimax/MiniMax-M3", effort="on",  prompt="Focus on X angle...")
task(description="...", agent_name="mavis", model="minimax/MiniMax-M3", effort="off", prompt="Focus on Y angle...")
task(description="...", agent_name="mavis", model="minimax/MiniMax-M3", effort="on",  prompt="Focus on Z angle...")
```

All N launch concurrently. Collect all results before synthesizing.

### Pattern 3: Background + foreground

One agent runs detached in the background while the main session continues:

```python
task(
    description="Long-running research: MyInsta ecosystem",
    prompt="Deep research on MyInsta...",
    agent_name="mavis",
    model="minimax/MiniMax-M3",
    effort="on",
    run_in_background=True   # ← returns task_id immediately, does NOT wait
)
# Main session continues here without waiting
```

Use `task_output(task_id)` to retrieve results later, or `task_query(task_id)` to check status.

## Key parameters

| Parameter | Values | Effect |
|---|---|---|
| `effort` | `"on"` | MiniMax-M3 thinking/reasoning enabled — better for complex research, multi-step analysis |
| `effort` | `"off"` | No thinking — faster for simple lookups, structured extraction |
| `model` | `"minimax/MiniMax-M3"` | Required for `effort` parameter; default model may not support it |
| `run_in_background` | `true` / `false` | Default `false` = wait for result. `true` = return task_id immediately |
| `agent_name` | `"mavis"` | Routes to the local mavis agent (this runtime) |

## Verifying parallel execution

After both tasks complete, each `task_result` includes a `session_id` field. If the two session IDs are different and the wall-clock timestamps overlap, the execution was genuinely concurrent.

Check with `task_query` (no arguments) — it lists all running/completed tasks with their status and durations.

## What to return to the user

For A/B comparisons, return **both results side-by-side** rather than merging them silently. The value of parallel agents is the divergence — if both found the same thing, say so and note the convergence; if they diverged, surface both and explain the delta.

## Verified working (2026-09-23)

Two `minimax/MiniMax-M3` agents — one `effort="on"`, one `effort="off"` — both searching for "how MyInsta was built":

- Both returned structurally identical, comprehensive results within seconds of each other
- The thinking agent (`bg_9ca11e2f...`) produced slightly more structured output (more headers, clearer attribution)
- The no-thinking agent (`bg_860dba54...`) was marginally faster to return
- Both converged on the same core facts: MyInsta = Instagram APK mod, Smali-level patching, `me/bluepapilte` namespace, built by Carpaxel/Bluepapilte, launched late 2023
- Neither was definitively "better" — they found the same sources and returned equivalent quality

**Bottom line:** use `effort="on"` for complex analytical tasks (architecture, root-cause, multi-step logic); use `effort="off"` for straightforward lookups where speed matters.
