# Publishing

## One-time setup

1. **Create the CurseForge project** and get its numeric id from the *About
   Project* box on its page.
2. **Put the id in the TOC.** Uncomment the line in `NextMob.toc` and fill it
   in:

   ```
   ## X-Curse-Project-ID: 1234567
   ```

   Until that is set, a tagged release still builds the zip and creates the
   GitHub release — the CurseForge upload is simply skipped.
3. **Add the secret.** Repository → Settings → Secrets and variables → Actions:

   | Secret | Where it comes from | Required |
   |---|---|---|
   | `CF_API_KEY` | CurseForge → account settings → API tokens | yes, for CurseForge |
   | `WAGO_API_TOKEN` | Wago, if you also publish there | no |
   | `WOWI_API_TOKEN` | WoWInterface, if you also publish there | no |

   `GITHUB_TOKEN` is provided by Actions; nothing to add.
4. **Upload the description and the icon.** Neither is set by the packager.
   Paste `curseforge-description.md` into the project page, and upload
   `media/icon-400.png` as the project avatar (CurseForge wants a square image,
   400x400 or larger). Tick the **Forever** game flavour; it is far less
   crowded than Retail.

   The icon is generated, not hand-drawn, so it can be re-rendered at any size:

   ```
   python3 -I tools/make-icon.py media/icon-400.png 400
   ```

   Edit `tools/make-icon.py` to change it — colours are named constants at the
   top, and the geometry is in 400px units scaled by `s`.

## Cutting a release

The version comes from the tag, and only tags on `main` publish.

1. Update `## Version:` in `NextMob.toc` and add a `CHANGELOG.md` section.
2. Merge to `main`.
3. Tag it — annotated, named for the version and nothing else:

   ```
   git tag -a 1.0 -m "1.0"
   git push origin 1.0
   ```

The release workflow compiles every Lua file, runs all seven test suites, and
only then packages and uploads. A tag that is not an ancestor of `main` is
refused before anything is built.

## Running the checks locally

```
lua tools/run-tests.lua .
```
