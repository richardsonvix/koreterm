---
name: feedback-discoverability
description: When adding features, check the basic create/duplicate flows are reachable from where the user works (tab and new-tab menus), and say so when they are missing
metadata:
  type: feedback
---

On 2026-11-19 the user said "vacilo, heim? você nem para falar. Não tem opção para criar conexão RDP do zero, nem mesmo duplicar uma existente."

New RDP connections could only be made from a right-click menu in Settings > Profiles. RDP profiles had no duplicate at all. Several RDP features had been built on top without anyone noticing the gap.

**Why:** the user works from the tab and new-tab menus, so a flow hidden in Settings does not exist for them. They expect gaps like this to be pointed out, not discovered by them.

**How to apply:** when touching a feature area, check that create, edit, duplicate and delete are reachable from the menus the user uses. Mention any missing basic flow in the report, even if it was not asked for.
