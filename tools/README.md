# Toolchain

Nothing in here is tracked: the jars are fetched by hand and found through
the `tla2tools.jar` symlink in every `tla/` directory (`ln -s
../../../tools/tla2tools.jar`), or through `TLA2TOOLS=`.

| file | what | where from |
|---|---|---|
| `tla2tools.jar` | TLC 2.19, used for every model | https://github.com/tlaplus/tlaplus/releases |
| `tla2tools-1.8.0.jar` | the TLC that `kernel/work.mount.gp_on_demand.proposal/trace/` needs for the trace specs (`JsonDeserialize`) | https://github.com/tlaplus/tlaplus/releases |
| `CommunityModules-deps.jar` | the TLA+ community modules the trace specs load | https://github.com/tlaplus/CommunityModules/releases |

herd7 and klitmus7 (herdtools7 >= 7.58, Debian `herdtools7`) run the litmus
tests against the kernel tree's `tools/memory-model`; Dartagnan and CBMC
are built or unpacked per the `RESUME.md`/`README.md` next to their
harnesses.
