SuSFS 2.4.0 + KazeSU (legacy) for Exynos 9820 4.14 (Infinity-X lineage-24.0)

A) KazeSU repo (LeDrew2017/KazeSU, branch legacy). Start from your original tip (1cd5b4b5).
   Do NOT apply any revert patch; 03 already contains the net result.
   1. git apply --whitespace=nowarn patches/03-kazesu-kernel-only.patch
   2. git apply patches/04-kazesu-manager-and-ksud.patch
   3. commit, push, then rebuild the manager (ksud is bundled in the APK).

B) Kernel tree (Infinity-X lineage-24.0), run in the kernel root:
   1. git apply patches/01-kernel-exynos9820-remove-susfs.patch
   2. git apply patches/02-kernel-susfs-2.4.0-infinityx-4.14.patch
   3. update the KernelSU submodule to your new KazeSU commit from (A).
   Defconfigs switch to CONFIG_KSU_SUSFS=y (inline hooks); manual hook is off.

Order between A and B only matters at step B3. 01 must come before 02.
In the manager, set the sus_path and priority UID filter apps (empty sus_path list hides paths from every app).
Compile-checked only; not tested on a device.
