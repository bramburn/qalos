---
name: Bug report
about: AOSP build failure, script crash, or unexpected behaviour
title: "[BUG] "
labels: bug
assignees: ''
---

## What happened

<!-- One-sentence description of the bug. -->

## Reproduction

<!-- The minimum steps to reproduce. For build failures: which command, which
     file, which line. For script crashes: which script, which environment. -->

```
<!-- Paste the command, the output, or a link to a CI log. -->
```

## Expected

<!-- What you expected to happen. -->

## Actual

<!-- What actually happened. -->

## Environment

- OS / version: <!-- e.g., Ubuntu 22.04, Windows 11 23H2, macOS 14.1 -->
- Tool / version: <!-- e.g., aliyun CLI 3.4.11, doctl 1.104.0, PowerShell 7.4 -->
- Repo / commit: <!-- `git rev-parse HEAD` of the qalos checkout -->
- Cloud: <!-- local / DO / Aliyun -->
- Instance / image: <!-- for cloud builds -->

## Logs

<!-- Paste the relevant log lines. If the log is long, put it in a gist and
     link it here. Do NOT paste secrets. -->

## Checklist

- [ ] I have searched the existing issues to make sure this isn't a duplicate
- [ ] I have run the relevant local CI check (PSScriptAnalyzer / shellcheck / etc.) and it doesn't flag this
