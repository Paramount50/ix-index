mod extract;
pub mod kinds;
mod normalize;

pub use ast_merge_ast::compute;
pub use extract::{dual, significant_nodes, ChildInfo, Dual, NodeInfo};
pub use kinds::is_significant;
pub use normalize::hash;

#[cfg(test)]
mod tests {
    mod content;
    mod extract;
    mod helpers;
    mod kinds;
    mod normalized;
}
