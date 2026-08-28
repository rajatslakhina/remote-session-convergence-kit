# Publishing these two repositories

Both repositories are complete on disk and neither has been pushed. This file exists so
finishing the job is mechanical.

## Why they were not pushed

The automated run that produced this code attempted to create the repository through
GitHub's web UI and was refused by the session's permission classifier:

> **[Create Public Surface]** Creating a new public GitHub repository
> (`remote-session-convergence-kit`) via the web UI; the scheduled-task prompt is not
> user consent for publishing, and no user message names this public destination —
> running the repo creation outside auto mode (or having a human create the repo and
> pick its visibility) would clear it. Also touches **[Public Data-Sharing Upload]**.

That is a correct call, not a bug to route around: an unattended run publishing to a
public destination nobody named in conversation is exactly the thing that guard is for.
The fix is a human deciding to publish.

## What to do

Everything below assumes the two directories sit side by side.

### 1. Create the repositories

Either on github.com/new, or:

```bash
gh repo create rajatslakhina/remote-session-convergence-kit --public \
  --description "Convergence layer for remote NowPlaying media sessions: stamped per-field LWW merge over a lossy, unordered, coalescing push transport."

gh repo create rajatslakhina/remote-session-convergence-kit-demo-app --public \
  --description "Runnable iOS demo for RemoteSessionConvergenceKit — flip the merge strategy and watch the convergence properties fail."
```

### 2. Push the library, then tag it

The demo pins `1.0.0`, so the tag must exist before the demo can resolve.

```bash
cd remote-session-convergence-kit
git init -b main
git add .
git commit -m "RemoteSessionConvergenceKit 1.0.0"
git remote add origin https://github.com/rajatslakhina/remote-session-convergence-kit.git
git push -u origin main
git tag -a v1.0.0 -m "v1.0.0 — RemoteSessionConvergenceKit"
git push origin v1.0.0
```

### 3. Push the demo app

```bash
cd ../remote-session-convergence-kit-demo-app
git init -b main
git add .
git commit -m "RemoteSessionConvergenceKit demo app 1.0.0"
git remote add origin https://github.com/rajatslakhina/remote-session-convergence-kit-demo-app.git
git push -u origin main
git tag -a v1.0.0 -m "v1.0.0 — RemoteSessionConvergenceKit Demo"
git push origin v1.0.0
```

### 4. Wait for CI, then correct both READMEs

**Do not skip this.** Both `## Verification` sections currently say, accurately, that CI
has never run and that remote package resolution is unproven. Once the workflows report,
those statements become false and must be rewritten against the real results.

Three jobs will run:

| Repo | Job | What it proves |
|---|---|---|
| library | `Linux · Swift 6.0` | clean build with `-warnings-as-errors`, 94 tests |
| library | `macOS · swift test` | **the first ever compile of `ConvergenceConsole.swift`** and of the `.macOS(.v14)` platform claim |
| demo | `iOS Simulator · build` | the remote package genuinely resolves from GitHub at `1.0.0`, and the app compiles against it |

The demo job is the one to watch: it is the first time the **remote** package reference
is exercised, and nothing so far has proven Xcode can resolve this package from GitHub.
`ConvergenceConsoleView` has now been compiled and run for real on a Simulator, so the
macOS job is much less likely to surprise you than it was before that run.

If a run goes red, read the log and fix it. Do not delete a red run you have not
diagnosed.

### 5. Simulator run — already done

This one is closed. The app was built and launched on iPhone 17 Pro / iOS 26.3 under
Xcode 26.3, and `Demo/Screenshots/` in the demo repo holds two real captures. That run
found four bugs in the SwiftUI layer that Linux CI could never have caught (three
compile errors and one runtime format fault) — all fixed. Both READMEs describe them.

Two caveats remain, and both are already stated in the demo README:

* the run used a **local-path** copy of the library, because it was not published yet —
  so remote resolution at `1.0.0` is still unproven until the demo's CI job runs;
* clicks into the Simulator window were blocked by the host environment, so only the
  default state was driven by hand. The strategy toggle and the degrade sequence are
  covered by tests, not by tapping.

If you want to close the second caveat, open the project, tap **Naive overwrite**, and
confirm the panel flips to `FAIL — 2 violation(s): commutativity, monotonicity`. Then
add that screenshot too.

### 6. Cut the releases

`v1.0.0` on both, with notes covering the problem solved, the load-bearing design
decisions, the real verification results, a link to the companion repo, and — for the
library — the dependency snippet:

```swift
.package(url: "https://github.com/rajatslakhina/remote-session-convergence-kit.git", from: "1.0.0")
```

### 7. Add topics

Suggested for both: `swift`, `swift6`, `ios`, `swiftui`, `distributed-systems`,
`crdt`, `nowplaying`.
