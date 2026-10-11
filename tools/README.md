# Tools

Nothing in here but this README is tracked. The jars are fetched by
hand, and every `tla/` directory finds TLC through a `tla2tools.jar`
symlink or through `TLA2TOOLS=`. From inside a `tla/` directory:

    ln -s "$(git rev-parse --show-toplevel)/tools/tla2tools.jar"

| file | what | where from |
|---|---|---|
| `tla2tools.jar` | TLC 2.19 of 08 August 2024, used for every model | https://github.com/tlaplus/tlaplus/releases |
| `tla2tools-1.8.0.jar` | the TLC the trace specs of `kernel/mount/gp-on-demand-proposal/trace/` need, because the community modules don't load into 2.19 | https://github.com/tlaplus/tlaplus/releases |
| `CommunityModules-deps.jar` | the TLA+ community modules the trace specs load for their JSON reader | https://github.com/tlaplus/CommunityModules/releases |

Everything else comes from the distribution or is built as the README
next to the harness that needs it says:

- Java 17 or newer for TLC.
- herd7 and klitmus7 from herdtools7 7.58 (Debian: `herdtools7`) for
  the litmus tests, run against the `tools/memory-model` directory of a
  kernel tree.
- CBMC 6.6.0 for the `cbmc/` harnesses.
- Dartagnan from Dat3M, built with JDK 21 and Maven, and clang-19 for
  the `dat3m/` harness.
