mod lang;
mod profiles;
mod types;

pub use lang::{detect, detect_from_extension, Lang};
pub use types::Profile;

#[cfg(test)]
mod tests;
