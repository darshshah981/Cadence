# TextEdit surface probe

This standalone development probe checks three production boundaries on one
synthetic saved TextEdit document: a verified opaque document identity,
exact insertion, and selected-text capture followed by exact replacement.
It does not use the microphone, a writing model, Compose memory, or personal
documents.

From the repository root:

```sh
bash tools/ComposeTextEditSurfaceProbe/run.sh --check
bash tools/ComposeTextEditSurfaceProbe/run.sh --run
```

`--check` builds the current Debug module and probe without opening an app.
`--run` needs an unlocked desktop and Accessibility trust for the actual probe
executable. It creates a fresh synthetic file under `/tmp`, asks macOS to open
that file in a new TextEdit instance, verifies the owned process, exact app
path, focused editor and document URL, and sets a known caret position. The
probe checks the production adapter, posts through production insertion, then
polls TextEdit's accessibility value for the exact expected synthetic result.
It selects a known phrase, captures it through the opted-in production reader,
revalidates the selection, posts a replacement through the guarded insertion
path, and checks the exact result again.
It terminates only the process returned by its own launch request. Temporary
synthetic files are left for the OS to clear; no user file is altered.

Each `--run` writes an immutable content-free report under
`Build/ComposeRoadmap/U17-textedit-surface/run.*/report.json`, including failed
and blocked attempts. It binds the observed result to source, Debug library
and probe hashes. `--run` exits nonzero unless the
exact readbacks pass. The wrapper scans its evidence directory for privacy
canaries. A passing development probe is narrower than signed installed-app
certification and does not test model-written replacements or memory behavior.
