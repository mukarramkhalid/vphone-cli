"""Mixin: sandbox hook patches."""

from .kernel_asm import MOV_X0_0, RET


class KernelPatchSandboxMixin:
    def patch_sandbox_hooks(self):
        """Patches 17-26: Stub Sandbox MACF hooks with mov x0,#0; ret.

        Uses mac_policy_ops struct indices from XNU source (xnu-11215+).
        """
        self._log("\n[17-26] Sandbox MACF hooks")

        ops_table = self._find_sandbox_ops_table_via_conf()
        if ops_table is None:
            return False

        HOOK_INDICES = {
            "file_check_mmap": 36,
            "mount_check_mount": 87,
            "mount_check_remount": 88,
            "mount_check_umount": 91,
            "vnode_check_rename": 120,
        }

        sb_start, sb_end = self.sandbox_text
        patched_count = 0

        for hook_name, idx in HOOK_INDICES.items():
            func_off = self._read_ops_entry(ops_table, idx)
            if func_off is None or func_off <= 0:
                self._log(f"  [-] ops[{idx}] {hook_name}: NULL or invalid")
                continue
            if not (sb_start <= func_off < sb_end):
                self._log(
                    f"  [-] ops[{idx}] {hook_name}: foff 0x{func_off:X} "
                    f"outside Sandbox (0x{sb_start:X}-0x{sb_end:X})"
                )
                continue

            self.emit(func_off, MOV_X0_0, f"mov x0,#0 [_hook_{hook_name}]")
            self.emit(func_off + 4, RET, f"ret [_hook_{hook_name}]")
            self._log(f"  [+] ops[{idx}] {hook_name} at foff 0x{func_off:X}")
            patched_count += 1

        return patched_count > 0
