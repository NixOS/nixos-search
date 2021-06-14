use serde::{Deserialize, Serialize};

/// All system keys supported by nix
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum System {
    #[serde(rename = "aarch64-linux")]
    Aarch64Linux,
    #[serde(rename = "armv5tel-linux")]
    Armv5telLinux,
    #[serde(rename = "armv6l-linux")]
    Armv6lLinux,
    #[serde(rename = "armv7a-linux")]
    Armv7aLinux,
    #[serde(rename = "armv7l-linux")]
    Armv7lLinux,
    #[serde(rename = "mipsel-linux")]
    MipselLinux,
    #[serde(rename = "i686-cygwin")]
    I686Cygwin,
    #[serde(rename = "i686-freebsd")]
    I686Freebsd,
    #[serde(rename = "i686-linux")]
    I686Linux,
    #[serde(rename = "i686-netbsd")]
    I686Netbsd,
    #[serde(rename = "i686-openbsd")]
    I686Openbsd,
    #[serde(rename = "x86_64-cygwin")]
    X86_64Cygwin,
    #[serde(rename = "x86_64-freebsd")]
    X86_64Freebsd,
    #[serde(rename = "x86_64-linux")]
    X86_64Linux,
    #[serde(rename = "x86_64-netbsd")]
    X86_64Netbsd,
    #[serde(rename = "x86_64-openbsd")]
    X86_64Openbsd,
    #[serde(rename = "x86_64-solaris")]
    X86_64Solaris,
    #[serde(rename = "x86_64-darwin")]
    X86_64Darwin,
    #[serde(rename = "i686-darwin")]
    I686Darwin,
    #[serde(rename = "aarch64-darwin")]
    Aarch64Darwin,
    #[serde(rename = "armv7a-darwin")]
    Armv7aDarwin,
    #[serde(rename = "x86_64-windows")]
    X86_64Windows,
    #[serde(rename = "i686-windows")]
    I686Windows,
    #[serde(rename = "wasm64-wasi")]
    Wasm64Wasi,
    #[serde(rename = "wasm32-wasi")]
    Wasm32Wasi,
    #[serde(rename = "x86_64-redox")]
    X86_64Redox,
    #[serde(rename = "powerpc64le-linux")]
    Powerpc64leLinux,
    #[serde(rename = "powerpc64-linux")]
    Powerpc64Linux,
    #[serde(rename = "riscv32-linux")]
    Riscv32Linux,
    #[serde(rename = "riscv64-linux")]
    Riscv64Linux,
    #[serde(rename = "arm-none")]
    ArmNone,
    #[serde(rename = "armv6l-none")]
    Armv6lNone,
    #[serde(rename = "aarch64-none")]
    Aarch64None,
    #[serde(rename = "avr-none")]
    AvrNone,
    #[serde(rename = "i686-none")]
    I686None,
    #[serde(rename = "x86_64-none")]
    X86_64None,
    #[serde(rename = "powerpc-none")]
    PowerpcNone,
    #[serde(rename = "msp430-none")]
    Msp430None,
    #[serde(rename = "riscv64-none")]
    Riscv64None,
    #[serde(rename = "riscv32-none")]
    Riscv32None,
    #[serde(rename = "vc4-none")]
    Vc4None,
    #[serde(rename = "js-ghcjs")]
    JsGhcjs,
    #[serde(rename = "aarch64-genode")]
    Aarch64Genode,
    #[serde(rename = "x86_64-genode")]
    X86_64Genode,
}

#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub struct InstancePlatform {
    system: System,
    version: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn serialize() {
        assert_eq!(
            serde_json::ser::to_string(&System::Aarch64Darwin).unwrap(),
            "\"aarch64-darwin\""
        )
    }

    #[test]
    fn deserialize() {
        assert_eq!(
            serde_json::de::from_str::<System>("\"aarch64-linux\"").unwrap(),
            System::Aarch64Linux
        )
    }
}
