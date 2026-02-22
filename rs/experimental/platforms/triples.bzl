load("@rules_rust//rust/platform:triple.bzl", "triple")
load(
    "@rules_rust//rust/platform:triple_mappings.bzl",
    _triple_to_constraint_set = "triple_to_constraint_set",
)

_WINDOWS_ABI_CONSTRAINTS = {
    "gnu": "@rules_rs//rs/experimental/platforms/constraints:windows_gnu",
    "gnullvm": "@rules_rs//rs/experimental/platforms/constraints:windows_gnullvm",
    "msvc": "@rules_rs//rs/experimental/platforms/constraints:windows_msvc",
}

def triple_to_constraint_set(target_triple):
    constraints = _triple_to_constraint_set(target_triple)
    t = triple(target_triple)

    if t.system in ("linux", "nixos"):
        if t.abi == "musl" or "musl" in target_triple:
            # Rustc passes `-no-pie` on musl so make sure we align.
            constraints.append("@llvm//constraints/libc:musl")
            constraints.append("@llvm//constraints/pie:off")
        else:
            constraints.append("@llvm//constraints/libc:gnu.2.28")
    elif t.system == "windows":
        constraints.append(_WINDOWS_ABI_CONSTRAINTS[t.abi])

    return constraints

SUPPORTED_EXEC_TRIPLES = [
    "x86_64-unknown-linux-gnu",
    "aarch64-unknown-linux-gnu",
    "x86_64-pc-windows-msvc",
    "aarch64-pc-windows-msvc",
    "x86_64-apple-darwin",
    "aarch64-apple-darwin",
]

# See https://doc.rust-lang.org/beta/rustc/platform-support.html
SUPPORTED_TARGET_TRIPLES = [
    # Tier 1
    "aarch64-apple-darwin",            # ARM64 macOS (11.0+, Big Sur+)
    "aarch64-pc-windows-msvc",         # ARM64 Windows MSVC
    "aarch64-unknown-linux-gnu",       # ARM64 Linux (kernel 4.1+, glibc 2.17+)
    "i686-pc-windows-msvc",            # 32-bit MSVC (Windows 10+, Windows Server 2016+, Pentium 4) 1 2
    "i686-unknown-linux-gnu",          # 32-bit Linux (kernel 3.2+, glibc 2.17+, Pentium 4) 1
    "x86_64-pc-windows-gnu",           # 64-bit MinGW (Windows 10+, Windows Server 2016+)
    "x86_64-pc-windows-msvc",          # 64-bit MSVC (Windows 10+, Windows Server 2016+)
    "x86_64-unknown-linux-gnu",        # 64-bit Linux (kernel 3.2+, glibc 2.17+)

    # Tier 2 with host tools
    "aarch64-pc-windows-gnullvm",      # ARM64 MinGW (Windows 10+), LLVM ABI
    "aarch64-unknown-linux-musl",      # ARM64 Linux with musl 1.2.5
    # "aarch64-unknown-linux-ohos",      # ARM64 OpenHarmony
    "arm-unknown-linux-gnueabi",       # Armv6 Linux (kernel 3.2+, glibc 2.17)
    "arm-unknown-linux-gnueabihf",     # Armv6 Linux, hardfloat (kernel 3.2+, glibc 2.17)
    "armv7-unknown-linux-gnueabihf",   # Armv7-A Linux, hardfloat (kernel 3.2+, glibc 2.17)
    # "armv7-unknown-linux-ohos",        # Armv7-A OpenHarmony
    #"loongarch64-unknown-linux-gnu",   # LoongArch64 Linux, LP64D ABI (kernel 5.19+, glibc 2.36), LSX required
    #"loongarch64-unknown-linux-musl",  # LoongArch64 Linux, LP64D ABI (kernel 5.19+, musl 1.2.5), LSX required
    "i686-pc-windows-gnu",             # 32-bit MinGW (Windows 10+, Windows Server 2016+, Pentium 4) 1 2
    "powerpc-unknown-linux-gnu",       # PowerPC Linux (kernel 3.2+, glibc 2.17)
    "powerpc64-unknown-linux-gnu",     # PPC64 Linux (kernel 3.2+, glibc 2.17)
    "powerpc64le-unknown-linux-gnu",   # PPC64LE Linux (kernel 3.10+, glibc 2.17)
    "powerpc64le-unknown-linux-musl",  # PPC64LE Linux (kernel 4.19+, musl 1.2.5)
    "riscv64gc-unknown-linux-gnu",     # RISC-V Linux (kernel 4.20+, glibc 2.29)
    "s390x-unknown-linux-gnu",         # S390x Linux (kernel 3.2+, glibc 2.17)
    "x86_64-apple-darwin",             # 64-bit macOS (10.12+, Sierra+)
    "x86_64-pc-windows-gnullvm",       # 64-bit x86 MinGW (Windows 10+), LLVM ABI
    "x86_64-unknown-freebsd",          # 64-bit x86 FreeBSD
    #"x86_64-unknown-illumos",          # illumos
    "x86_64-unknown-linux-musl",       # 64-bit Linux with musl 1.2.5
    # "x86_64-unknown-linux-ohos",       # x86_64 OpenHarmony
    
    "x86_64-unknown-netbsd",           # NetBSD/amd64
    #"x86_64-pc-solaris",               # 64-bit x86 Solaris 11.4
    #"sparcv9-sun-solaris",             # SPARC V9 Solaris 11.4

    # Tier 2 without host tools
    "aarch64-apple-ios",               # ✓ ARM64 iOS
    "aarch64-apple-ios-macabi",        # ✓ Mac Catalyst on ARM64
    "aarch64-apple-ios-sim",           # ✓ Apple iOS Simulator on ARM64
    "aarch64-linux-android",           # ✓ ARM64 Android
    "aarch64-unknown-fuchsia",         # ✓ ARM64 Fuchsia
    "aarch64-unknown-none",            # * Bare ARM64, hardfloat
    "aarch64-unknown-none-softfloat",  # * Bare ARM64, softfloat
    "aarch64-unknown-uefi",            # ? ARM64 UEFI
    "arm-linux-androideabi",           # ✓ Armv6 Android
    "arm-unknown-linux-musleabi",      # ✓ Armv6 Linux with musl 1.2.5
    "arm-unknown-linux-musleabihf",    # ✓ Armv6 Linux with musl 1.2.5, hardfloat
    #"arm64ec-pc-windows-msvc",         # ✓ Arm64EC Windows MSVC
    #"armv5te-unknown-linux-gnueabi",   # ✓ Armv5TE Linux (kernel 4.4+, glibc 2.23)
    #"armv5te-unknown-linux-musleabi",  # ✓ Armv5TE Linux with musl 1.2.5
    "armv7-linux-androideabi",         # ✓ Armv7-A Android
    "armv7-unknown-linux-gnueabi",     # ✓ Armv7-A Linux (kernel 4.15+, glibc 2.27)
    "armv7-unknown-linux-musleabi",    # ✓ Armv7-A Linux with musl 1.2.5
    "armv7-unknown-linux-musleabihf",  # ✓ Armv7-A Linux with musl 1.2.5, hardfloat
    #"armv7a-none-eabi",                # * Bare Armv7-A
    #"armv7a-none-eabihf",              # * Bare Armv7-A, hardfloat
    #"armv7r-none-eabi",                # * Bare Armv7-R
    #"armv7r-none-eabihf",              # * Bare Armv7-R, hardfloat
    #"armv8r-none-eabihf",              # * Bare Armv8-R, hardfloat
    #"i586-unknown-linux-gnu",          # ✓ 32-bit Linux (kernel 3.2+, glibc 2.17, original Pentium) 3
    #"i586-unknown-linux-musl",         # ✓ 32-bit Linux (musl 1.2.5, original Pentium) 3
    "i686-linux-android",              # ✓ 32-bit x86 Android (Pentium 4 plus various extensions) 1
    "i686-pc-windows-gnullvm",         # ✓ 32-bit x86 MinGW (Windows 10+, Pentium 4), LLVM ABI 1
    "i686-unknown-freebsd",            # ✓ 32-bit x86 FreeBSD (Pentium 4) 1
    "i686-unknown-linux-musl",         # ✓ 32-bit Linux with musl 1.2.5 (Pentium 4) 1
    "i686-unknown-uefi",               # ? 32-bit UEFI (Pentium 4, softfloat) 2
    #"loongarch64-unknown-none",        # * LoongArch64 Bare-metal (LP64D ABI)
    #"loongarch64-unknown-none-softfloat", # * LoongArch64 Bare-metal (LP64S ABI)
    #"nvptx64-nvidia-cuda",             # * –emit=asm generates PTX code that runs on NVIDIA GPUs
    # "riscv32i-unknown-none-elf",       # * Bare RISC-V (RV32I ISA)
    # "riscv32im-unknown-none-elf",      # * Bare RISC-V (RV32IM ISA)
    # "riscv32imac-unknown-none-elf",    # * Bare RISC-V (RV32IMAC ISA)
    # "riscv32imafc-unknown-none-elf",   # * Bare RISC-V (RV32IMAFC ISA)
    "riscv32imc-unknown-none-elf",     # * Bare RISC-V (RV32IMC ISA)
    "riscv64gc-unknown-linux-musl",    # ✓ RISC-V Linux (kernel 4.20+, musl 1.2.5)
    "riscv64gc-unknown-none-elf",      # * Bare RISC-V (RV64IMAFDC ISA)
    # "riscv64im-unknown-none-elf",      # * Bare RISC-V (RV64IM ISA)
    # "riscv64imac-unknown-none-elf",    # * Bare RISC-V (RV64IMAC ISA)
    # "sparc64-unknown-linux-gnu",       # ✓ SPARC Linux (kernel 4.4+, glibc 2.23)
    "thumbv6m-none-eabi",              # * Bare Armv6-M
    "thumbv7em-none-eabi",             # * Bare Armv7E-M
    "thumbv7em-none-eabihf",           # * Bare Armv7E-M, hardfloat
    "thumbv7m-none-eabi",              # * Bare Armv7-M
    # "thumbv7neon-linux-androideabi",   # ✓ Thumb2-mode Armv7-A Android with NEON
    # "thumbv7neon-unknown-linux-gnueabihf", # ✓ Thumb2-mode Armv7-A Linux with NEON (kernel 4.4+, glibc 2.23)
    # "thumbv8m.base-none-eabi",          # * Bare Armv8-M Baseline
    "thumbv8m.main-none-eabi",          # * Bare Armv8-M Mainline
    "thumbv8m.main-none-eabihf",        # * Bare Armv8-M Mainline, hardfloat
    "wasm32-unknown-emscripten",        # ✓ WebAssembly via Emscripten
    "wasm32-unknown-unknown",           # ✓ WebAssembly
    "wasm32-wasip1",                    # ✓ WebAssembly with WASIp1
    "wasm32-wasip1-threads",            # ✓ WebAssembly with WASI Preview 1 and threads
    "wasm32-wasip2",                    # ✓ WebAssembly with WASIp2
    # "wasm32v1-none",                    # * WebAssembly limited to 1.0 features and no imports
    "x86_64-apple-ios",                 # ✓ 64-bit x86 iOS
    "x86_64-apple-ios-macabi",          # ✓ Mac Catalyst on x86_64
    #"x86_64-fortanix-unknown-sgx",      # ✓ Fortanix ABI for 64-bit Intel SGX
    "x86_64-linux-android",             # ✓ 64-bit x86 Android
    "x86_64-unknown-fuchsia",           # ✓ 64-bit x86 Fuchsia
    #"x86_64-unknown-linux-gnux32",      # ✓ 64-bit Linux (x32 ABI) (kernel 4.15+, glibc 2.27)
    "x86_64-unknown-none",              # * Freestanding/bare-metal x86_64, softfloat
    #"x86_64-unknown-redox",             # ✓ Redox OS
    "x86_64-unknown-uefi",              # ? 64-bit UEFI

    # No Tier3 support.
]
