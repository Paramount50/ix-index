use std::process::Command;

use serde_json::Value;

fn run_binary(spec: &str) -> (std::process::Output, tempfile::TempDir) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("spec.json");
    std::fs::write(&path, spec).unwrap();
    let bin = env!("CARGO_BIN_EXE_dag-runner");
    let output = Command::new(bin)
        .arg("--output")
        .arg("json")
        .arg(&path)
        .output()
        .expect("spawn dag-runner");
    (output, dir)
}

fn parse_events(stdout: &[u8]) -> Vec<Value> {
    std::str::from_utf8(stdout)
        .unwrap()
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| serde_json::from_str(l).expect("ndjson event"))
        .collect()
}

#[test]
fn all_succeed_produces_zero_exit_and_finished_events() {
    let spec = r#"{"nodes":{
        "a":{"command":["true"]},
        "b":{"command":["true"],"depends_on":["a"]}
    }}"#;
    let (output, _dir) = run_binary(spec);
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let events = parse_events(&output.stdout);

    let summary = events.iter().find(|e| e["event"] == "summary").expect("summary event");
    assert_eq!(summary["total"], 2);
    assert_eq!(summary["succeeded"], 2);
    assert_eq!(summary["failed"], 0);
    assert_eq!(summary["skipped"], 0);

    let finished: Vec<_> = events.iter().filter(|e| e["event"] == "node_finished").collect();
    assert_eq!(finished.len(), 2);
    for ev in finished {
        assert_eq!(ev["outcome"], "succeeded");
        assert!(ev["exit_code"].is_null());
    }
}

#[test]
fn failed_dep_skips_downstream_with_exit_one() {
    let spec = r#"{"nodes":{
        "a":{"command":["false"]},
        "b":{"command":["true"],"depends_on":["a"]}
    }}"#;
    let (output, _dir) = run_binary(spec);
    // `false` exits 1; skipped also contributes 1 → worst is 1.
    assert_eq!(output.status.code(), Some(1));
    let events = parse_events(&output.stdout);
    let summary = events.iter().find(|e| e["event"] == "summary").unwrap();
    assert_eq!(summary["failed"], 1);
    assert_eq!(summary["skipped"], 1);
    let b = events
        .iter()
        .find(|e| e["event"] == "node_finished" && e["node"] == "b")
        .unwrap();
    assert_eq!(b["outcome"], "skipped");
}

#[test]
fn worst_failure_drives_exit_code() {
    let spec = r#"{"nodes":{
        "a":{"command":["sh","-c","exit 3"]},
        "b":{"command":["sh","-c","exit 9"]}
    }}"#;
    let (output, _dir) = run_binary(spec);
    assert_eq!(output.status.code(), Some(9));
}

#[test]
fn cycle_is_rejected_before_running() {
    let spec = r#"{"nodes":{
        "a":{"command":["true"],"depends_on":["b"]},
        "b":{"command":["true"],"depends_on":["a"]}
    }}"#;
    let (output, _dir) = run_binary(spec);
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("cycle"), "expected cycle error, got: {stderr}");
}

#[test]
fn missing_dependency_is_rejected_before_running() {
    let spec = r#"{"nodes":{
        "a":{"command":["true"],"depends_on":["ghost"]}
    }}"#;
    let (output, _dir) = run_binary(spec);
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("ghost"), "expected missing-dep error to name 'ghost', got: {stderr}");
}
