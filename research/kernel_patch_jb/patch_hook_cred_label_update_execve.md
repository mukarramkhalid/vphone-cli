# C23 `patch_hook_cred_label_update_execve`

## 1) How the Patch Works
- Source: `scripts/patchers/kernel_jb_patch_hook_cred_label.py`.
- Locator strategy:
  1. Resolve `vnode_getattr` (symbol or string-near function).
  2. Find sandbox `mac_policy_ops` table from Seatbelt policy metadata.
  3. Pick cred-label execve hook entry from early ops indices by function-size heuristic.
- Patch action (inline trampoline):
  - Replace the first instruction (PACIBSP) of the original hook with `B cave`.
  - Cave shellcode runs PACIBSP first (relocated), then:
    - builds inline `vfs_context` via `mrs tpidr_el1` (current_thread),
    - calls `vnode_getattr`,
    - propagates uid/gid into new credential,
    - updates csflags with CS_VALID,
    - `B hook+4` to resume original function at second instruction (STP).
  - No ops table pointer modification — avoids chained fixup integrity issues.

## 2) Expected Outcome
- Interpose sandbox cred-label execve hook with custom ownership/credential propagation logic.

## 3) Target
- Ops table: `mac_policy_ops` at `0xFFFFFE0007A58488` (discovered via mac_policy_conf)
- Hook index: 18 (largest function in ops[0:29], 4040 bytes)
  - Original hook: `sub_FFFFFE00093BDB64` (Sandbox `hook..execve()` handler)
  - Contains: sandbox profile evaluation, container assignment, entitlement processing
- Inline trampoline at hook function entry + shellcode cave in __TEXT_EXEC.

## 4) IDA MCP Evidence

### Ops table structure
- `mac_policy_conf` at `0xFFFFFE0007A58428`:
  - +0: `0xFE00075FF33D` → "Sandbox" (mpc_name)
  - +8: `0xFE00075FD493` → "Seatbelt sandbox policy" (mpc_fullname)
  - +32: `0xFE0007A58488` → mpc_ops (ops table pointer)
- Ops table entries (non-null in first 30):
  - [6]: `0xFE00093BDB58` (12 bytes)
  - [7]: `0xFE00093B0C04` (36 bytes)
  - [11]: `0xFE00093B0B68` (156 bytes)
  - [13]: `0xFE00093B0B5C` (12 bytes)
  - [18]: `0xFE00093BDB64` (4040 bytes) ← **selected by size heuristic**
  - [19]: `0xFE00093B0AE8` (116 bytes)
  - [29]: `0xFE00093B0830` (696 bytes)

### vnode_getattr
- String-related hit: xref `0xFE00084C08EC` → function start `0xFE00084C0718`

### Original hook prologue
```
FFFFFE00093BDB64  PACIBSP          ; ← replaced with B cave
FFFFFE00093BDB68  STP X28,X27,[SP,#-0x60]!
FFFFFE00093BDB6C  STP X26,X25,[SP,#0x10]
...
```

### Chained fixup format (reference, NO LONGER MODIFIED)
- Ops table entries use auth rebase (bit63=1):
  - auth=1, key=IA (0), addrDiv=0
  - ops[18] diversity=0xEC79, next=2, target=0x023B9B64
- Kernel loader signs with IA + diversity from fixup metadata.
- Dispatch code uses a DIFFERENT PAC discriminator (e.g., 0x8550).
- **Cannot rewrite ops table pointer** — the fixup diversity doesn't match
  dispatch discriminator, and modifying chained fixup entries breaks
  kernelcache integrity, causing PAC failures in unrelated kexts.

## 5) Bug History

### Bug 1: Non-executable code cave (PANIC)
The code cave was allocated in `__PRELINK_TEXT` segment. While marked R-X in the
Mach-O, this segment is **non-executable at runtime** on ARM64e due to
KTRR (Kernel Text Read-only Region) enforcement. The cave ended up at a low
file offset (e.g. 0x5440) in __PRELINK_TEXT padding, which at runtime maps to a
non-executable page.

**Panic**: "Kernel instruction fetch abort at pc 0xfffffe004761d440"

**Fix**: Modified `_find_code_cave()` in `kernel_jb_base.py` to only search
`__TEXT_EXEC` and `__TEXT_BOOT_EXEC` segments. `__PRELINK_TEXT` excluded.

### Bug 2: Ops table pointer rewrite breaks chained fixups (PAC PANIC)
The approach of modifying the ops table pointer (preserving upper 32 auth bits,
replacing lower 32 target bits) breaks the kernelcache's chained fixup integrity.
This causes PAC failures in completely UNRELATED kexts (e.g., AppleImage4).

**Panic**: "PAC failure from kernel with IA key while branching to x8 at pc
0xfffffe00314f4770" — the crash was in AppleImage4:__text, not in sandbox code.

**Root cause analysis**:
- The kernelcache uses a fileset Mach-O with chained fixup pointers in __DATA.
- Each fixup entry includes auth metadata (key, diversity, next chain link).
- Modifying ANY entry in the chain appears to break the integrity check for the
  entire segment/chain, causing ALL chained fixup resolutions to fail or corrupt.
- Result: PAC-signed pointers throughout the kernel get wrong values → PAC auth
  fails at unrelated dispatch sites.
- Additionally verified: ops[18] diversity=0xEC79 does NOT match the dispatch
  discriminator (x17=0x8550 at the crash site), confirming the pointer encoding
  doesn't match how it's consumed.

**Fix**: Switched from ops table pointer rewrite to **inline trampoline**.
Replace PACIBSP at function entry with `B cave`. The cave runs PACIBSP first
(relocated instruction), performs ownership propagation, then `B hook+4` to
resume the original function. Uses only PC-relative B/BL instructions —
no PAC involvement, no chained fixup modification.

## 6) Current Implementation
- 47 patches: 46 shellcode instructions in __TEXT_EXEC cave + 1 trampoline
  (B cave replacing PACIBSP at hook function entry).
- Cave at file offset 0xAB1720 (inside __TEXT_EXEC).
- No ops table modification.

## 7) Risk Assessment
- **Medium**: Inline function entry trampoline + shellcode is standard hooking.
  Risk is in shellcode correctness (register save/restore, stack alignment,
  vnode_getattr argument setup).
- Mitigated by: dynamic function-size heuristic for hook identification,
  __TEXT_EXEC-restricted code cave, PACIBSP relocation preserving PAC semantics,
  full register save/restore around ownership propagation code.
