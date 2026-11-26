# Contributing to Telltale

Thanks for helping! Telltale aims to be the nicest-looking menu-bar monitor that costs almost nothing
to run. Every change is weighed against that.

## Ground rules

1. **No dependencies.** One native Swift binary, built with `swiftc` via `build.sh`. No package managers,
   no frameworks beyond what ships with macOS.
2. **Idle cost stays near zero.** With just the icon, Telltale should stay around 13 MB and ~0% CPU.
   Anything that runs while closed must be cheap, opt-in and within the [cost budgets](#cost-budgets).
3. **No per-frame work while the panel is open.** Avoid `repeatForever` animations, blurred shadows on
   live content, and animating values that change every second.
4. **No network access** except features the user explicitly starts (like the speed test). No analytics.
5. **Read-only by default.** Anything that changes the system (fan control, killing processes) must be
   explicit, opt-in and clearly labelled.

## Getting started

```bash
git clone https://github.com/pri-te-sh/Telltale.git
cd Telltale
./build.sh --install          # build, install to ~/Applications and launch
build/Telltale.app/Contents/MacOS/Telltale --selftest   # print one set of readings
```

Useful flags while developing: `--open` (open the panel on launch), `--open-after=<seconds>`, and
`--panel=<memory|cpu|gpu|power|storage|battery|network|devices|thermals|settings>`.

## Measuring cost

Every performance-sensitive PR should include before/after numbers from the measurement script:

```bash
./build.sh
./scripts/measure.sh                     # Telltale alone
./scripts/measure.sh --compare Stats     # side by side with another running app
SECONDS_PER_RUN=120 ./scripts/measure.sh # longer, steadier runs
```

It runs Telltale in four standard configurations, prints a Markdown table (memory = `phys_footprint`,
CPU = % of one core), and restores your settings afterwards.

### Cost budgets

Measured on an Apple Silicon laptop with other apps idle. A PR that pushes any of these over budget
needs a very good reason.

| Configuration | Memory | CPU (one core) |
|---|---|---|
| Panel closed · icon only | ≤ 16 MB | ≤ 0.1% |
| Panel closed · 6 readouts + charts · every 3 s | ≤ 22 MB | ≤ 1% |
| Panel closed · 6 readouts + charts · every 1 s | ≤ 22 MB | ≤ 3% |
| Panel open · overview | ≤ 60 MB | ≤ 5% |

Rules of thumb that keep us there:

- With the panel closed, read only what the menu bar or an alert actually needs.
- Prefer Mach/IOKit/sysctl calls over subprocesses; never spawn a process on a timer while closed.
- Expensive reads (full sensor sweeps, purgeable disk space, CoreWLAN, `NSWorkspace` app lists) belong on a
  slower cadence or only on the page that shows them.
- Don't animate values that change every second, and avoid blurred shadows on live content.

## Pull requests

- Keep PRs focused; one feature or fix per PR.
- Match the existing style (small views, comments that explain *why*).
- Update `README.md` if behaviour, permissions or settings change.
- If the UI changes, regenerate screenshots with `./scripts/screenshots.sh`.
- The **Build** workflow must pass.

## Reporting bugs

Open an issue with your Mac model, macOS version, what you expected, what happened, and the output
of `--selftest`.

## Releasing (maintainers)

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Resources/Info.plist`.
2. Commit, then tag and push: `git tag v0.2.0 && git push origin v0.2.0`.
3. The **Release** workflow builds a universal app and attaches `Telltale-<version>.zip` to a GitHub release.

## Website

The project site lives in `docs/` (a single static `index.html`, no build step). To publish it:
**Settings → Pages → Build and deployment → Deploy from a branch → `main` / `/docs`**.
It is served at https://pri-te-sh.github.io/Telltale/.
