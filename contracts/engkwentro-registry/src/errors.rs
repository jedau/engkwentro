use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegistryError {
    NotImplemented,
    Unauthorized,
    UnknownMatch,
    AlreadyApplied,
    NotTerminal,
}

impl fmt::Display for RegistryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            RegistryError::NotImplemented => "not implemented in v0.1.0",
            RegistryError::Unauthorized => "unauthorized match contract",
            RegistryError::UnknownMatch => "unknown match",
            RegistryError::AlreadyApplied => "result already applied",
            RegistryError::NotTerminal => "settlement is not terminal",
        };
        f.write_str(s)
    }
}

impl From<RegistryError> for String {
    fn from(e: RegistryError) -> Self {
        e.to_string()
    }
}

impl near_sdk::FunctionError for RegistryError {
    fn panic(&self) -> ! {
        near_sdk::env::panic_str(&self.to_string())
    }
}
