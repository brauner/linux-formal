# Mounts

Models of fs/namespace.c and fs/pnode.c: the mount tree, how changes to
it propagate, and the reference counts and locks around it. `core/`
models the mount code itself, the others model specific changes to it.

| Model | What it models | Status |
|---|---|---|
| [`core/`](core/) | the propagation algebra against the documentation, a mount's reference count, the RCU path walk, do_lock_mount(), WRITE_HOLD and the lifetime of a mount namespace | mainline, at v7.3-rc3 |
| [`ownership/`](ownership/) | who owns an unmounted mount: the reference count cycle a loop device can close, and four answers to it | mainline, at v7.3-rc3; three of the answers not merged |
| [`covers/`](covers/) | mainline's answer: the cover an unmounted mount leaves on its unmounted parent instead of staying attached, and the lookups that find it | mainline |
| [`shrink-submounts/`](shrink-submounts/) | shrink_submounts() taking the automounts below a mount down during a synchronous umount | mainline |
| [`vacant/`](vacant/) | the vacant-mount series: unmounted mounts keep their own reference and are vacated in place | not merged |
| [`vacant-root-by-root/`](vacant-root-by-root/) | the vacant-mount series with propagate_umount() handing the unmounted set back root by root | not merged |
| [`gp-on-demand-proposal/`](gp-on-demand-proposal/) | unmounting without a grace period when nothing else holds the mounts | proposed |
| [`gp-on-demand/`](gp-on-demand/) | the same series in its first shapes | not merged |
