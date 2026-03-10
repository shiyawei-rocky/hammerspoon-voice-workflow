# Public-Safe Export Policy

This repository is a sanitized export of a larger private working setup.

## Why some files are intentionally missing
The private system includes assets that should not be published directly, such as:
- personal or organization-specific API credentials
- transcripts, logs, and operational history
- private memory / knowledge assets
- private prompt libraries
- glossary / terminology assets tied to real work
- machine-specific configuration values

## What this public repo preserves
- runtime code structure
- service/module boundaries
- governance and architecture notes
- public-safe example config
- public-safe example prompt assets
- evaluation and responsibility documents

## What this public repo does not guarantee
This is **not** a fully reproducible turnkey clone of the private working environment. It is instead a public-safe reference implementation and architecture export.

To make it runnable, a user must provide their own:
- `config.lua`
- `prompts/prompts.json`
- `prompts/glossary.txt`
- model endpoints / keys / keychain setup
- any private knowledge or memory data they choose to maintain locally

## Release gate for future public exports
Before publishing, verify at minimum:
1. No keys, tokens, or secrets.
2. No transcripts, logs, or private memory assets.
3. No private glossary / terminology payloads.
4. Example config and example prompts exist.
5. README clearly explains public-vs-private boundary.
