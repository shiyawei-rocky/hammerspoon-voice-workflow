# Docs Index

## Governance and architecture
- `PROJECT_GOVERNANCE.md`
  - asset grading, change gates, and entropy-control rules
- `architecture-map.md`
  - runtime/module map and recommended reading order
- `onboarding.md`
  - fastest path for a new maintainer to understand the repo
- `ASR_PROVIDER_DECISION.md`
  - ASR provider selection and architecture notes
- `reliability_scoring.md`
  - reliability scoring method
- `public-safe-export.md`
  - explains the public/private boundary of this repository

## Behavioral contracts
- `hotkey_responsibilities.md`
  - what each hotkey entry is supposed to do, and what it must not do
- `prompt_contracts.md`
  - semantic contract of the main prompt families
- `eval_score_template.md`
  - lightweight evaluation template for regression checks

## Typical local helper scripts
- `python3 ~/.hammerspoon/scripts/build_knowledge_assets.py --days 30`
- `python3 ~/.hammerspoon/scripts/f5_report.py --days 7`
- `python3 ~/.hammerspoon/scripts/reliability_score.py --days 7 --json`

## Notes
- This docs folder mixes architecture, governance, and public-safe operating guidance.
- If a document mentions local-only assets, treat those as private environment references rather than public repo guarantees.
