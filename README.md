# zotero-cite.koplugin

A [KOReader](https://github.com/koreader/koreader) plugin that adds references to your
[Zotero](https://www.zotero.org) library straight from the document you are reading.

## Features

- **DOI links**: tapping a `doi:` or `doi.org` link offers an "Add to Zotero" action.
- **Highlighted text**: selecting text that contains a DOI, or that looks like a citation,
  adds an "Add to Zotero" button to the highlight dialog. Plain citations are matched
  against Crossref and you pick the right result.
- **Preview before adding**: title, authors, source, type, DOI and abstract are shown
  before the item is created.
- **Duplicate detection**: warns if the item is already in your library and lists the
  collections it belongs to.
- **Collections**: choose the target collection; the last one used is remembered per library.

Metadata is resolved through doi.org content negotiation (Crossref / DataCite) and mapped to
the matching Zotero item type and fields.

## Installation

1. Download `zotero-cite.koplugin-<version>.zip` from the
   [latest release](https://github.com/jaeusamio/zotero-cite.koplugin/releases/latest).
2. Extract it into KOReader's `plugins/` directory, so you end up with
   `plugins/zotero-cite.koplugin/`.
3. Restart KOReader.

## Configuration

Open **Tools > Zotero cite** in the main menu.

- **Set API key and library**: enter a Zotero API key with write access
  ([create one here](https://www.zotero.org/settings/keys)), the library type (`user` or
  `group`) and the user or group ID.
- **Use Zotero plugin account**: if you already use
  [zotero.koplugin](https://github.com/stelzch/zotero.koplugin), its account is picked up
  automatically (read-only) and its local cache is used for collections and duplicate
  checks. Setting your own key overrides it; this entry switches back.

## Releases

Pushing a `v*` tag that points to a commit on `main` builds the plugin zip and publishes a
GitHub release with the commits since the previous tag as changelog:

```sh
git tag v0.1.0
git push origin v0.1.0
```
