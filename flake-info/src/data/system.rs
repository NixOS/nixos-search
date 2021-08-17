use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum System {
    Plain(String),
    Detailed { cpu: Cpu, kernel: Kernel },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Cpu {
    family: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Kernel {
    name: String,
}

impl ToString for System {
    fn to_string(&self) -> String {
        match self {
            System::Plain(system) => system.to_owned(),
            System::Detailed { cpu, kernel } => format!("{}-{}", cpu.family, kernel.name),
        }
    }
}

#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub struct InstancePlatform {
    system: System,
    version: String,
}

#[cfg(test)]
mod tests {
    use super::*;
}
