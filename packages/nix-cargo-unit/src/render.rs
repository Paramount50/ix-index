use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use askama::Template as _;
use color_eyre::eyre::{Result, eyre};

use crate::model::{Unit, UnitGraph};
use crate::shell;

pub struct RenderOptions {
    pub workspace_root: PathBuf,
    pub vendor_root: Option<PathBuf>,
    pub content_addressed: bool,
    pub toolchain_id: Option<String>,
    pub deny_unused_crate_dependencies: bool,
}

struct PreparedGraph {
    hashes: Vec<String>,
    names: Vec<String>,
    transitive_unit_deps: Vec<BTreeSet<usize>>,
    build_script_runs: BTreeMap<usize, BuildScriptRun>,
}

struct BuildScriptRun {
    compile_index: usize,
    dependency_runs: Vec<usize>,
}

#[derive(askama::Template)]
#[template(path = "units.nix.askama", escape = "none")]
struct UnitsNixTemplate {
    unit_entries: String,
    policy_check_entries: String,
    roots: String,
    checked_roots: String,
    package_entries: String,
    binary_entries: String,
    library_entries: String,
    test_entries: String,
    default_entry: String,
}

pub fn render_units_nix(graph: &UnitGraph, options: &RenderOptions) -> Result<String> {
    graph.ensure_supported()?;
    let prepared = prepare_graph(graph, options)?;
    let template = UnitsNixTemplate {
        unit_entries: render_unit_entries(graph, options, &prepared)?,
        policy_check_entries: render_policy_check_entries(graph, options, &prepared)?,
        roots: render_roots(graph, &prepared),
        checked_roots: render_checked_roots(graph, &prepared),
        package_entries: render_root_entries(graph, &prepared, |_| true),
        binary_entries: render_root_entries(graph, &prepared, Unit::is_bin),
        library_entries: render_root_entries(graph, &prepared, Unit::is_library),
        test_entries: render_test_entries(graph, &prepared),
        default_entry: render_default_entry(graph, &prepared),
    };

    Ok(template.render()?)
}

fn render_unit_entries(
    graph: &UnitGraph,
    options: &RenderOptions,
    prepared: &PreparedGraph,
) -> Result<String> {
    let mut entries = String::new();
    for (run_index, build_script_run) in &prepared.build_script_runs {
        write!(
            entries,
            "    {} = mkUnit {};\n\n",
            prepared.unit_attr(*run_index),
            render_build_script_run(graph, options, prepared, *run_index, build_script_run)?
        )?;
    }

    for (index, unit) in graph.units.iter().enumerate() {
        if unit.is_run_custom_build() {
            continue;
        }

        write!(
            entries,
            "    {} = mkUnit {};\n\n",
            prepared.unit_attr(index),
            render_rustc_unit(graph, options, prepared, index)?
        )?;
    }

    Ok(entries)
}

fn render_policy_check_entries(
    graph: &UnitGraph,
    options: &RenderOptions,
    prepared: &PreparedGraph,
) -> Result<String> {
    let mut entries = String::new();
    if options.deny_unused_crate_dependencies {
        writeln!(
            entries,
            "    unusedCrateDependencies = {};",
            render_unused_crate_dependencies_check(graph, options, prepared)
        )?;
    }

    Ok(entries)
}

fn render_default_entry(graph: &UnitGraph, prepared: &PreparedGraph) -> String {
    graph
        .roots
        .first()
        .map(|first_root| {
            format!(
                "  default = withPolicyChecks {};\n",
                prepared.unit_ref(*first_root)
            )
        })
        .unwrap_or_default()
}

impl PreparedGraph {
    fn unit_attr(&self, index: usize) -> String {
        nix_attr(&self.names[index])
    }

    fn unit_ref(&self, index: usize) -> String {
        format!("units.{}", self.unit_attr(index))
    }
}

fn prepare_graph(graph: &UnitGraph, options: &RenderOptions) -> Result<PreparedGraph> {
    let mut hashes = vec![None; graph.units.len()];
    for index in 0..graph.units.len() {
        compute_hash(graph, options, index, &mut hashes)?;
    }
    let hashes: Vec<String> = hashes.into_iter().map(Option::unwrap).collect();

    let names: Vec<String> = graph
        .units
        .iter()
        .enumerate()
        .map(|(index, unit)| {
            if unit.is_run_custom_build() {
                format!(
                    "{}-build-script-run-{}-{}",
                    unit.package_name(),
                    unit.package_version(),
                    hashes[index]
                )
            } else {
                format!(
                    "{}-{}-{}",
                    unit.target.name,
                    unit.package_version(),
                    hashes[index]
                )
            }
        })
        .collect();

    let transitive_unit_deps = (0..graph.units.len())
        .map(|index| {
            let mut deps = BTreeSet::new();
            collect_transitive_unit_deps(graph, index, &mut deps)?;
            Ok(deps)
        })
        .collect::<Result<Vec<_>>>()?;

    let mut build_script_runs = BTreeMap::new();
    for (index, unit) in graph.units.iter().enumerate() {
        if !unit.is_run_custom_build() {
            continue;
        }

        let compile_index = unit
            .dependencies
            .iter()
            .map(|dep| dep.index)
            .find(|dep_index| {
                graph
                    .units
                    .get(*dep_index)
                    .is_some_and(Unit::is_custom_build_compile)
            })
            .ok_or_else(|| eyre!("build script run unit {index} has no compile dependency"))?;

        let dependency_runs = unit
            .dependencies
            .iter()
            .map(|dep| dep.index)
            .filter(|dep_index| {
                *dep_index != compile_index
                    && graph
                        .units
                        .get(*dep_index)
                        .is_some_and(Unit::is_run_custom_build)
            })
            .collect();

        build_script_runs.insert(
            index,
            BuildScriptRun {
                compile_index,
                dependency_runs,
            },
        );
    }

    Ok(PreparedGraph {
        hashes,
        names,
        transitive_unit_deps,
        build_script_runs,
    })
}

fn compute_hash(
    graph: &UnitGraph,
    options: &RenderOptions,
    index: usize,
    hashes: &mut [Option<String>],
) -> Result<String> {
    if let Some(hash) = &hashes[index] {
        return Ok(hash.clone());
    }

    let unit = graph.unit(index)?;
    let mut dependency_hashes = Vec::new();
    for dependency in &unit.dependencies {
        let dependency_unit = graph.unit(dependency.index)?;
        if dependency_unit.is_run_custom_build() {
            continue;
        }
        dependency_hashes.push(format!(
            "{}:{}:{}:{}",
            dependency.extern_crate_name,
            dependency.public,
            dependency.noprelude,
            compute_hash(graph, options, dependency.index, hashes)?
        ));
    }

    let hash = unit.identity_hash(&dependency_hashes, options.toolchain_id.as_deref());
    hashes[index] = Some(hash.clone());
    Ok(hash)
}

fn collect_transitive_unit_deps(
    graph: &UnitGraph,
    index: usize,
    deps: &mut BTreeSet<usize>,
) -> Result<()> {
    let unit = graph.unit(index)?;
    for dependency in &unit.dependencies {
        let dependency_unit = graph.unit(dependency.index)?;
        if dependency_unit.is_run_custom_build() {
            continue;
        }
        if deps.insert(dependency.index) {
            collect_transitive_unit_deps(graph, dependency.index, deps)?;
        }
    }

    Ok(())
}

fn render_rustc_unit(
    graph: &UnitGraph,
    options: &RenderOptions,
    prepared: &PreparedGraph,
    index: usize,
) -> Result<String> {
    let unit = &graph.units[index];
    let mut attrs = Attrs::new();

    attrs.string("pname", &unit.target.name);
    attrs.string("version", unit.package_version());
    let native_build_inputs = if collects_unused_crate_dependencies(unit, options) {
        "[ rustToolchain pkgs.jq ] ++ extraNativeBuildInputs"
    } else {
        "[ rustToolchain ] ++ extraNativeBuildInputs"
    };
    attrs.expr("nativeBuildInputs", native_build_inputs);
    attrs.expr(
        "buildInputs",
        &render_build_inputs(graph, prepared, index, unit_build_script_run(graph, index)),
    );
    attrs.bool("dontStrip", true);
    if options.content_addressed {
        attrs.bool("__contentAddressed", true);
        attrs.string("outputHashMode", "recursive");
        attrs.string("outputHashAlgo", "sha256");
    }
    attrs.multiline(
        "buildPhase",
        &render_rustc_build_phase(graph, options, prepared, index)?,
    );
    attrs.multiline(
        "installPhase",
        &render_install_phase(unit, options, &prepared.hashes[index]),
    );

    Ok(attrs.render())
}

fn unit_build_script_run(graph: &UnitGraph, index: usize) -> Option<usize> {
    let unit = &graph.units[index];
    unit.dependencies
        .iter()
        .map(|dep| dep.index)
        .find(|dep_index| {
            graph.units.get(*dep_index).is_some_and(|dep_unit| {
                dep_unit.is_run_custom_build() && dep_unit.pkg_id == unit.pkg_id
            })
        })
}

fn render_build_inputs(
    graph: &UnitGraph,
    prepared: &PreparedGraph,
    index: usize,
    build_script_run: Option<usize>,
) -> String {
    let mut refs: Vec<String> = graph.units[index]
        .dependencies
        .iter()
        .filter_map(|dep| {
            let dep_unit = &graph.units[dep.index];
            (!dep_unit.is_run_custom_build())
                .then(|| format!("units.{}", nix_attr(&prepared.names[dep.index])))
        })
        .collect();

    if let Some(run_index) = build_script_run {
        refs.push(format!("units.{}", nix_attr(&prepared.names[run_index])));
    }

    if refs.is_empty() {
        "[]".to_string()
    } else {
        format!("[ {} ]", refs.join(" "))
    }
}

fn render_rustc_build_phase(
    graph: &UnitGraph,
    options: &RenderOptions,
    prepared: &PreparedGraph,
    index: usize,
) -> Result<String> {
    let unit = &graph.units[index];
    let mut script = String::new();

    script.push_str("mkdir -p build\n");
    script.push_str("build_script_flags=()\n");
    script.push_str("rustc_args=()\n\n");
    script.push_str(&cargo_package_exports(unit));
    writeln!(
        script,
        "export CARGO_MANIFEST_DIR={}",
        shell::double_quote(&path_expr(options, &crate_root_for_unit(unit)))
    )?;

    if let Some(run_index) = unit_build_script_run(graph, index) {
        let run_ref = format!("${{units.{}}}", nix_attr(&prepared.names[run_index]));
        append_build_script_flag_reader(&mut script, &run_ref);
    }

    push_rustc_args(&mut script, unit, &prepared.hashes[index]);
    script.push_str(
        "${pkgs.lib.concatStringsSep \"\\n\" (map (arg: \"rustc_args+=( ${pkgs.lib.escapeShellArg arg} )\") extraRustcArgs)}\n",
    );

    for dep_index in &prepared.transitive_unit_deps[index] {
        let dep = &graph.units[*dep_index];
        if dep.is_bin() {
            continue;
        }
        writeln!(
            script,
            "rustc_args+=( -L \"dependency=${{units.{}}}/lib\" )",
            nix_attr(&prepared.names[*dep_index])
        )?;
    }

    if unit.is_proc_macro() {
        script.push_str("rustc_args+=( --extern proc_macro )\n");
    }
    if collects_unused_crate_dependencies(unit, options) {
        script.push_str("rustc_args+=( --error-format=json --json=unused-externs-silent )\n");
        push_arg(&mut script, "-W");
        push_arg(&mut script, "unused-crate-dependencies");
    }

    for dependency in &unit.dependencies {
        let dep_unit = &graph.units[dependency.index];
        if dep_unit.is_run_custom_build() || dep_unit.is_bin() {
            continue;
        }
        writeln!(
            script,
            "rustc_args+=( --extern \"{}=$(cat ${{units.{}}}/nix-support/extern-path)\" )",
            dependency.extern_crate_name,
            nix_attr(&prepared.names[dependency.index])
        )?;
    }

    let source_path = path_expr(options, Path::new(&unit.target.src_path));
    writeln!(
        script,
        "rustc_args+=( {} )",
        shell::double_quote(&source_path)
    )?;

    if unit.is_bin() || unit.is_test() {
        writeln!(
            script,
            "rustc_args+=( -o {} )",
            shell::quote(&format!("build/{}", unit.target.name))
        )?;
    } else {
        script.push_str("rustc_args+=( --out-dir build )\n");
        if unit.is_proc_macro() {
            script.push_str("rustc_args+=( --emit dep-info,link )\n");
        } else {
            script.push_str("rustc_args+=( --emit dep-info,metadata,link )\n");
        }
    }

    script.push_str("rustc_args+=( \"''${build_script_flags[@]}\" )\n");
    if collects_unused_crate_dependencies(unit, options) {
        script.push_str("rustc_diagnostics=build/rustc-diagnostics.jsonl\n");
        script.push_str("set +e\n");
        script.push_str("set -x\n");
        script.push_str("rustc \"''${rustc_args[@]}\" 2> \"$rustc_diagnostics\"\n");
        script.push_str("rustc_status=$?\n");
        script.push_str("set +x\n");
        script.push_str("set -e\n");
        script.push_str("cat \"$rustc_diagnostics\" >&2\n");
        script.push_str("if [ \"$rustc_status\" -ne 0 ]; then\n");
        script.push_str("  exit \"$rustc_status\"\n");
        script.push_str("fi\n");
        script.push_str(
            r#"jq -r 'select(."$message_type" == "unused_extern") | .unused_extern_names[]' "$rustc_diagnostics" | sort -u > build/unused-crate-dependencies
"#,
        );
    } else {
        script.push_str("set -x\n");
        script.push_str("rustc \"''${rustc_args[@]}\"\n");
    }

    Ok(script)
}

fn collects_unused_crate_dependencies(unit: &Unit, options: &RenderOptions) -> bool {
    options.deny_unused_crate_dependencies && !unit.is_external()
}

fn push_rustc_args(script: &mut String, unit: &Unit, hash: &str) {
    push_arg(script, "--crate-name");
    push_arg(script, &unit.target.name.replace('-', "_"));
    push_arg(script, "--edition");
    push_arg(script, &unit.target.edition);

    for crate_type in &unit.target.crate_types {
        push_arg(script, "--crate-type");
        push_arg(script, crate_type);
    }
    if unit.is_proc_macro() {
        push_arg(script, "-C");
        push_arg(script, "prefer-dynamic");
    }

    push_codegen(script, "opt-level", &unit.profile.opt_level);
    push_codegen(script, "debuginfo", unit.profile.debuginfo.rustc_value());
    if let Some(lto) = lto_for_unit(unit) {
        push_codegen(script, "lto", lto);
    }
    if let Some(codegen_units) = unit.profile.codegen_units {
        push_codegen(script, "codegen-units", &codegen_units.to_string());
    }
    push_codegen(
        script,
        "debug-assertions",
        if unit.profile.debug_assertions {
            "yes"
        } else {
            "no"
        },
    );
    push_codegen(
        script,
        "overflow-checks",
        if unit.profile.overflow_checks {
            "yes"
        } else {
            "no"
        },
    );
    push_arg(script, "-C");
    push_arg(
        script,
        &format!("panic={}", unit.profile.panic.rustc_value()),
    );
    if let Some(strip) = unit.profile.strip.rustc_value() {
        push_arg(script, "-C");
        push_arg(script, &format!("strip={strip}"));
    }
    if let Some(split_debuginfo) = &unit.profile.split_debuginfo {
        push_arg(script, "-C");
        push_arg(script, &format!("split-debuginfo={split_debuginfo}"));
    }
    if unit.profile.rpath {
        push_arg(script, "-C");
        push_arg(script, "rpath=yes");
    }
    push_codegen(script, "metadata", hash);
    push_codegen(script, "extra-filename", &format!("-{hash}"));

    for rustflag in &unit.profile.rustflags {
        push_arg(script, rustflag);
    }
    for feature in &unit.features {
        push_arg(script, "--cfg");
        push_arg(script, &format!("feature=\"{feature}\""));
    }
    if unit.is_test() {
        push_arg(script, "--test");
    }
    if let Some(platform) = &unit.platform {
        push_arg(script, "--target");
        push_arg(script, platform);
    }
    if unit.is_external() {
        push_arg(script, "--cap-lints");
        push_arg(script, "warn");
    }
}

fn lto_for_unit(unit: &Unit) -> Option<&'static str> {
    let allowed = unit
        .target
        .crate_types
        .iter()
        .all(|crate_type| matches!(crate_type.as_str(), "bin" | "cdylib" | "staticlib"));
    allowed.then(|| unit.profile.lto.rustc_value()).flatten()
}

fn push_codegen(script: &mut String, key: &str, value: &str) {
    push_arg(script, "-C");
    push_arg(script, &format!("{key}={value}"));
}

fn push_arg(script: &mut String, value: &str) {
    let _ = writeln!(script, "rustc_args+=( {} )", shell::quote(value));
}

fn append_build_script_flag_reader(script: &mut String, run_ref: &str) {
    let quoted_run_ref = format!("\"{run_ref}\"");
    let snippets = [
        ("rustc-cfg", "--cfg"),
        ("rustc-link-lib", "-l"),
        ("rustc-link-search", "-L"),
    ];

    script.push('\n');
    for (file, flag) in snippets {
        let _ = writeln!(
            script,
            "if [ -f {run_ref}/{file} ]; then\n  while IFS= read -r line; do\n    [ -n \"$line\" ] && build_script_flags+=( {flag_arg} \"$line\" )\n  done < {run_ref}/{file}\nfi",
            run_ref = quoted_run_ref,
            file = file,
            flag_arg = shell::quote(flag),
        );
    }
    let _ = writeln!(
        script,
        "if [ -f {run_ref}/rustc-cdylib-link-arg ]; then\n  while IFS= read -r line; do\n    [ -n \"$line\" ] && build_script_flags+=( -C \"link-arg=$line\" )\n  done < {run_ref}/rustc-cdylib-link-arg\nfi",
        run_ref = quoted_run_ref,
    );
    let _ = writeln!(
        script,
        "if [ -f {run_ref}/rustc-env ]; then\n  while IFS= read -r line; do\n    [ -n \"$line\" ] && export \"$line\"\n  done < {run_ref}/rustc-env\nfi",
        run_ref = quoted_run_ref,
    );
    let _ = writeln!(script, "export OUT_DIR={quoted_run_ref}/out-dir\n");
}

fn render_install_phase(unit: &Unit, options: &RenderOptions, hash: &str) -> String {
    let unused_crate_dependencies_install = if collects_unused_crate_dependencies(unit, options) {
        "\
if [ -s build/unused-crate-dependencies ]; then
  cp build/unused-crate-dependencies $out/nix-support/unused-crate-dependencies
fi
"
    } else {
        ""
    };

    if unit.is_bin() || unit.is_test() {
        format!(
            "\
mkdir -p $out/bin $out/nix-support
cp {} $out/bin/{}
chmod 755 $out/bin/{}
{unused_crate_dependencies_install}
",
            shell::quote(&format!("build/{}", unit.target.name)),
            shell::quote(&unit.target.name),
            shell::quote(&unit.target.name)
        )
    } else {
        let lib_name = unit.target.name.replace('-', "_");
        format!(
            "\
mkdir -p $out/lib $out/nix-support
cp -R build/* $out/lib/
extern_path=\"\"
for artifact in \\
  \"$out/lib/lib{lib_name}-{hash}.rlib\" \\
  \"$out/lib/lib{lib_name}-{hash}.so\" \\
  \"$out/lib/lib{lib_name}-{hash}.dylib\" \\
  \"$out/lib/{lib_name}-{hash}.dll\" \\
  \"$out/lib/lib{lib_name}-{hash}.rmeta\"; do
  if [ -f \"$artifact\" ]; then
    extern_path=\"$artifact\"
    break
  fi
done
[ -n \"$extern_path\" ] && printf '%s\\n' \"$extern_path\" > $out/nix-support/extern-path
{unused_crate_dependencies_install}
"
        )
    }
}

fn render_build_script_run(
    graph: &UnitGraph,
    options: &RenderOptions,
    prepared: &PreparedGraph,
    run_index: usize,
    build_script_run: &BuildScriptRun,
) -> Result<String> {
    let run_unit = &graph.units[run_index];
    let compile_unit = &graph.units[build_script_run.compile_index];
    let mut attrs = Attrs::new();

    attrs.string(
        "pname",
        &format!("{}-build-script-output", run_unit.package_name()),
    );
    attrs.string("version", run_unit.package_version());
    attrs.expr(
        "nativeBuildInputs",
        "[ rustToolchain ] ++ extraNativeBuildInputs",
    );

    let mut inputs = vec![format!(
        "units.{}",
        nix_attr(&prepared.names[build_script_run.compile_index])
    )];
    inputs.extend(
        build_script_run
            .dependency_runs
            .iter()
            .map(|index| format!("units.{}", nix_attr(&prepared.names[*index]))),
    );
    attrs.expr("buildInputs", &format!("[ {} ]", inputs.join(" ")));
    attrs.bool("dontStrip", true);
    if options.content_addressed {
        attrs.bool("__contentAddressed", true);
        attrs.string("outputHashMode", "recursive");
        attrs.string("outputHashAlgo", "sha256");
    }
    attrs.multiline(
        "buildPhase",
        &render_build_script_run_phase(
            options,
            prepared,
            run_unit,
            compile_unit,
            build_script_run.compile_index,
        )?,
    );
    attrs.multiline("installPhase", "true\n");

    Ok(attrs.render())
}

fn render_build_script_run_phase(
    options: &RenderOptions,
    prepared: &PreparedGraph,
    run_unit: &Unit,
    compile_unit: &Unit,
    compile_index: usize,
) -> Result<String> {
    let mut script = String::new();
    let compile_ref = format!("${{units.{}}}", nix_attr(&prepared.names[compile_index]));

    script.push_str("mkdir -p $out/out-dir\n");
    script.push_str("export OUT_DIR=$out/out-dir\n");
    writeln!(
        script,
        "export CARGO_MANIFEST_DIR={}",
        shell::double_quote(&path_expr(options, &crate_root_for_unit(run_unit)))
    )?;
    script.push_str("export RUSTC=\"$(type -p rustc)\"\n");
    script.push_str("HOST_TRIPLE=\"$($RUSTC -vV | sed -n 's/^host: //p')\"\n");
    script.push_str("export HOST=\"$HOST_TRIPLE\"\n");
    if let Some(platform) = &run_unit.platform {
        writeln!(script, "export TARGET={}", shell::quote(platform))?;
    } else {
        script.push_str("export TARGET=\"$HOST_TRIPLE\"\n");
    }
    writeln!(
        script,
        "export PROFILE={}",
        shell::quote(&run_unit.profile.name)
    )?;
    writeln!(
        script,
        "export OPT_LEVEL={}",
        shell::quote(&run_unit.profile.opt_level)
    )?;
    writeln!(
        script,
        "export DEBUG={}",
        shell::quote(if run_unit.profile.debuginfo.is_enabled() {
            "true"
        } else {
            "false"
        })
    )?;
    script.push_str(&cargo_package_exports(run_unit));
    script.push_str("cd \"$CARGO_MANIFEST_DIR\"\n");
    script.push_str("build_script_stdout=$(mktemp)\n");
    script.push_str("build_script_stderr=$(mktemp)\n");
    script.push_str("set +e\n");
    writeln!(
        script,
        "{}/bin/{} > \"$build_script_stdout\" 2> \"$build_script_stderr\"",
        compile_ref,
        shell::quote(&compile_unit.target.name)
    )?;
    script.push_str("build_script_status=$?\n");
    script.push_str("set -e\n");
    script.push_str("cat \"$build_script_stderr\" >&2\n");
    script.push_str("if [ \"$build_script_status\" -ne 0 ]; then\n");
    script.push_str("  cat \"$build_script_stdout\" >&2\n");
    script.push_str("  exit \"$build_script_status\"\n");
    script.push_str("fi\n");
    script.push_str(
        r#"
while IFS= read -r line; do
  case "$line" in
    cargo::*)
      normalized="cargo:''${line#cargo::}"
      ;;
    *)
      normalized="$line"
      ;;
  esac

  case "$normalized" in
    cargo:rustc-cfg=*)
      printf '%s\n' "''${normalized#cargo:rustc-cfg=}" >> $out/rustc-cfg
      ;;
    cargo:rustc-link-lib=*)
      printf '%s\n' "''${normalized#cargo:rustc-link-lib=}" >> $out/rustc-link-lib
      ;;
    cargo:rustc-link-search=*)
      printf '%s\n' "''${normalized#cargo:rustc-link-search=}" >> $out/rustc-link-search
      ;;
    cargo:rustc-env=*)
      printf '%s\n' "''${normalized#cargo:rustc-env=}" >> $out/rustc-env
      ;;
    cargo:rustc-cdylib-link-arg=*)
      printf '%s\n' "''${normalized#cargo:rustc-cdylib-link-arg=}" >> $out/rustc-cdylib-link-arg
      ;;
    cargo:warning=*)
      printf '%s\n' "build script warning: ''${normalized#cargo:warning=}" >&2
      ;;
    cargo:rerun-if-changed=*|cargo:rerun-if-env-changed=*)
      ;;
    cargo:*)
      printf '%s\n' "''${normalized#cargo:}" >> $out/cargo-metadata
      ;;
  esac
done < "$build_script_stdout"
"#,
    );

    Ok(script)
}

#[derive(Debug, Eq, Ord, PartialEq, PartialOrd)]
struct DependencyPolicyKey {
    pkg_id: String,
    package_name: String,
    package_version: String,
    extern_crate_name: String,
}

fn render_unused_crate_dependencies_check(
    graph: &UnitGraph,
    options: &RenderOptions,
    prepared: &PreparedGraph,
) -> String {
    let mut dependency_units: BTreeMap<DependencyPolicyKey, BTreeSet<usize>> = BTreeMap::new();

    for (index, unit) in graph.units.iter().enumerate() {
        if unit.is_run_custom_build() || !collects_unused_crate_dependencies(unit, options) {
            continue;
        }

        for dependency in &unit.dependencies {
            let dep_unit = &graph.units[dependency.index];
            if dep_unit.is_run_custom_build() || dep_unit.is_bin() {
                continue;
            }

            dependency_units
                .entry(DependencyPolicyKey {
                    pkg_id: unit.pkg_id.clone(),
                    package_name: unit.package_name().to_string(),
                    package_version: unit.package_version().to_string(),
                    extern_crate_name: dependency.extern_crate_name.clone(),
                })
                .or_default()
                .insert(index);
        }
    }

    let mut script = String::new();
    script.push_str(
        "pkgs.runCommand \"cargo-unit-unused-crate-dependencies\" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''\n",
    );
    script.push_str("      failures=0\n");
    script.push_str("      check_unused() {\n");
    script.push_str("        package=\"$1\"\n");
    script.push_str("        dependency=\"$2\"\n");
    script.push_str("        shift 2\n");
    script.push_str("        unit_count=\"$#\"\n");
    script.push_str("        unused_count=0\n\n");
    script.push_str("        for unit in \"$@\"; do\n");
    script.push_str("          report=\"$unit/nix-support/unused-crate-dependencies\"\n");
    script.push_str(
        "          if [ -f \"$report\" ] && grep -Fxq \"$dependency\" \"$report\"; then\n",
    );
    script.push_str("            unused_count=$((unused_count + 1))\n");
    script.push_str("          fi\n");
    script.push_str("        done\n\n");
    script.push_str("        if [ \"$unused_count\" -eq \"$unit_count\" ]; then\n");
    script.push_str(
        "          printf 'unused dependency in %s: %s\\n' \"$package\" \"$dependency\" >&2\n",
    );
    script.push_str("          failures=1\n");
    script.push_str("        fi\n");
    script.push_str("      }\n\n");

    for (dependency, unit_indexes) in dependency_units {
        let unit_refs = unit_indexes
            .iter()
            .map(|index| format!("\"${{units.{}}}\"", nix_attr(&prepared.names[*index])))
            .collect::<Vec<_>>()
            .join(" ");
        let package = format!("{} {}", dependency.package_name, dependency.package_version);
        let _ = writeln!(
            script,
            "      check_unused {} {} {unit_refs}",
            shell::quote(&package),
            shell::quote(&dependency.extern_crate_name),
        );
    }

    script.push_str("\n      if [ \"$failures\" -ne 0 ]; then\n");
    script.push_str("        exit 1\n");
    script.push_str("      fi\n");
    script.push_str("      mkdir -p \"$out\"\n");
    script.push_str("    ''");
    script
}

fn cargo_package_exports(unit: &Unit) -> String {
    let mut script = String::new();
    let package_name = unit.package_name();
    let version = unit.package_version();
    let mut version_parts = version.split('.');
    let major = version_parts.next().unwrap_or("0");
    let minor = version_parts.next().unwrap_or("0");
    let patch = version_parts.next().unwrap_or("0");

    for (name, value) in [
        ("CARGO_PKG_NAME", package_name),
        ("CARGO_PKG_VERSION", version),
        ("CARGO_PKG_VERSION_MAJOR", major),
        ("CARGO_PKG_VERSION_MINOR", minor),
        ("CARGO_PKG_VERSION_PATCH", patch),
    ] {
        let _ = writeln!(script, "export {name}={}", shell::quote(value));
    }

    script
}

fn crate_root_for_unit(unit: &Unit) -> PathBuf {
    let source = Path::new(&unit.target.src_path);
    if source.file_name().is_some_and(|name| name == "build.rs") {
        return source.parent().unwrap_or(source).to_path_buf();
    }

    let raw = unit.target.src_path.as_str();
    if let Some((root, _)) = raw.split_once("/src/") {
        return PathBuf::from(root);
    }

    source.parent().unwrap_or(source).to_path_buf()
}

fn path_expr(options: &RenderOptions, path: &Path) -> String {
    if let Some(expr) = path_under(path, &options.workspace_root, "src") {
        return expr;
    }
    if let Some(vendor_root) = &options.vendor_root
        && let Some(expr) = path_under(path, vendor_root, "vendorDir")
    {
        return expr;
    }
    if let Some(expr) = registry_path_expr(path) {
        return expr;
    }

    path.to_string_lossy().into_owned()
}

fn path_under(path: &Path, root: &Path, nix_var: &str) -> Option<String> {
    let relative = path.strip_prefix(root).ok()?;
    let relative = relative.to_string_lossy();
    if relative.is_empty() {
        Some(format!("${{{nix_var}}}"))
    } else {
        Some(format!("${{{nix_var}}}/{relative}"))
    }
}

fn registry_path_expr(path: &Path) -> Option<String> {
    let value = path.to_string_lossy();
    let (_, after_registry) = value.split_once("/registry/src/")?;
    let (_, after_index) = after_registry.split_once('/')?;
    Some(format!("${{vendorDir}}/{after_index}"))
}

fn render_roots(graph: &UnitGraph, prepared: &PreparedGraph) -> String {
    graph
        .roots
        .iter()
        .map(|index| format!("units.{}", nix_attr(&prepared.names[*index])))
        .collect::<Vec<_>>()
        .join(" ")
}

fn render_root_entries(
    graph: &UnitGraph,
    prepared: &PreparedGraph,
    include: impl Fn(&Unit) -> bool,
) -> String {
    let mut entries = String::new();
    let mut seen = BTreeSet::new();
    for index in &graph.roots {
        let unit = &graph.units[*index];
        if !include(unit) || !seen.insert(unit.target.name.clone()) {
            continue;
        }
        let _ = writeln!(
            entries,
            "    {} = withPolicyChecks units.{};",
            nix_attr(&unit.target.name),
            nix_attr(&prepared.names[*index])
        );
    }
    entries
}

fn render_checked_roots(graph: &UnitGraph, prepared: &PreparedGraph) -> String {
    graph
        .roots
        .iter()
        .map(|index| {
            format!(
                "withPolicyChecks units.{}",
                nix_attr(&prepared.names[*index])
            )
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn render_test_entries(graph: &UnitGraph, prepared: &PreparedGraph) -> String {
    let mut entries = String::new();
    let mut seen = BTreeSet::new();
    for index in &graph.roots {
        let unit = &graph.units[*index];
        if !unit.is_test() {
            continue;
        }

        let key = if seen.insert(unit.target.name.clone()) {
            unit.target.name.clone()
        } else {
            prepared.names[*index].clone()
        };
        let unit_ref = format!("${{units.{}}}", nix_attr(&prepared.names[*index]));
        let binary = format!("\"{unit_ref}/bin/{}\"", unit.target.name);
        let _ = writeln!(
            entries,
            "    {} = pkgs.runCommand {} {{ }} ''\n      export RUST_TEST_THREADS=\"$NIX_BUILD_CORES\"\n      {binary}\n      mkdir -p \"$out\"\n    '';",
            nix_attr(&key),
            nix_attr(&format!("cargo-unit-test-{key}")),
        );
    }

    entries
}

fn nix_attr(value: &str) -> String {
    serde_json::to_string(value).expect("serialize Nix string")
}

struct Attrs {
    values: Vec<(String, String)>,
}

impl Attrs {
    fn new() -> Self {
        Self { values: Vec::new() }
    }

    fn string(&mut self, name: &str, value: &str) {
        self.values
            .push((name.to_string(), format!("{};", nix_attr(value))));
    }

    fn bool(&mut self, name: &str, value: bool) {
        self.values.push((
            name.to_string(),
            format!("{};", if value { "true" } else { "false" }),
        ));
    }

    fn expr(&mut self, name: &str, value: &str) {
        self.values.push((name.to_string(), format!("{value};")));
    }

    fn multiline(&mut self, name: &str, value: &str) {
        self.values
            .push((name.to_string(), format!("''\n{value}  '';")));
    }

    fn render(self) -> String {
        let mut out = String::new();
        out.push_str("{\n");
        for (name, value) in self.values {
            let _ = writeln!(out, "      {name} = {value}");
        }
        out.push_str("    }");
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_one_derivation_per_build_unit() {
        let graph: UnitGraph = serde_json::from_str(
            r#"{
              "version": 1,
              "units": [
                {
                  "pkg_id": "path+file:///workspace#hello@0.1.0",
                  "target": {
                    "kind": ["bin"],
                    "crate_types": ["bin"],
                    "name": "hello",
                    "src_path": "/workspace/src/main.rs",
                    "edition": "2024"
                  },
                  "profile": { "name": "release", "opt_level": "3" },
                  "features": [],
                  "mode": "build",
                  "dependencies": []
                }
              ],
              "roots": [0]
            }"#,
        )
        .unwrap();

        let rendered = render_units_nix(
            &graph,
            &RenderOptions {
                workspace_root: PathBuf::from("/workspace"),
                vendor_root: None,
                content_addressed: false,
                toolchain_id: Some("rustc-test".to_string()),
                deny_unused_crate_dependencies: true,
            },
        )
        .unwrap();

        assert!(rendered.contains("units = rec"));
        assert!(rendered.contains("--crate-name"));
        assert!(rendered.contains("${src}/src/main.rs"));
        assert!(rendered.contains("default = withPolicyChecks units."));
        assert!(rendered.contains("policyChecks"));
        assert!(rendered.contains("extraRustcArgs"));
        assert!(rendered.contains("tests ="));
        assert!(rendered.contains("--json=unused-externs-silent"));
        assert!(rendered.contains("withPolicyChecks"));
    }

    #[test]
    fn exposes_test_roots_as_runnable_checks() {
        let graph: UnitGraph = serde_json::from_str(
            r#"{
              "version": 1,
              "units": [
                {
                  "pkg_id": "path+file:///workspace#hello@0.1.0",
                  "target": {
                    "kind": ["lib"],
                    "crate_types": ["lib"],
                    "name": "hello",
                    "src_path": "/workspace/src/lib.rs",
                    "edition": "2024",
                    "test": true
                  },
                  "profile": { "name": "test", "opt_level": "0" },
                  "features": [],
                  "mode": "test",
                  "dependencies": []
                }
              ],
              "roots": [0]
            }"#,
        )
        .unwrap();

        let rendered = render_units_nix(
            &graph,
            &RenderOptions {
                workspace_root: PathBuf::from("/workspace"),
                vendor_root: None,
                content_addressed: false,
                toolchain_id: None,
                deny_unused_crate_dependencies: false,
            },
        )
        .unwrap();

        assert!(rendered.contains("tests = {"));
        assert!(rendered.contains("\"hello\" = pkgs.runCommand \"cargo-unit-test-hello\""));
        assert!(rendered.contains("RUST_TEST_THREADS"));
        assert!(rendered.contains("/bin/hello"));
    }

    #[test]
    fn aggregates_unused_crate_dependency_reports_by_package() {
        let graph: UnitGraph = serde_json::from_str(
            r#"{
              "version": 1,
              "units": [
                {
                  "pkg_id": "registry+https://github.com/rust-lang/crates.io-index#serde@1.0.0",
                  "target": {
                    "kind": ["lib"],
                    "crate_types": ["lib"],
                    "name": "serde",
                    "src_path": "/vendor/serde/src/lib.rs",
                    "edition": "2021"
                  },
                  "profile": { "name": "release", "opt_level": "3" },
                  "mode": "build",
                  "dependencies": []
                },
                {
                  "pkg_id": "path+file:///workspace#hello@0.1.0",
                  "target": {
                    "kind": ["lib"],
                    "crate_types": ["lib"],
                    "name": "hello",
                    "src_path": "/workspace/src/lib.rs",
                    "edition": "2024"
                  },
                  "profile": { "name": "release", "opt_level": "3" },
                  "mode": "build",
                  "dependencies": [
                    { "index": 0, "extern_crate_name": "serde" }
                  ]
                },
                {
                  "pkg_id": "path+file:///workspace#hello@0.1.0",
                  "target": {
                    "kind": ["bin"],
                    "crate_types": ["bin"],
                    "name": "hello",
                    "src_path": "/workspace/src/main.rs",
                    "edition": "2024"
                  },
                  "profile": { "name": "release", "opt_level": "3" },
                  "mode": "build",
                  "dependencies": [
                    { "index": 0, "extern_crate_name": "serde" }
                  ]
                }
              ],
              "roots": [1, 2]
            }"#,
        )
        .unwrap();

        let rendered = render_units_nix(
            &graph,
            &RenderOptions {
                workspace_root: PathBuf::from("/workspace"),
                vendor_root: Some(PathBuf::from("/vendor")),
                content_addressed: false,
                toolchain_id: None,
                deny_unused_crate_dependencies: true,
            },
        )
        .unwrap();

        assert_eq!(
            rendered
                .matches("check_unused 'hello 0.1.0' 'serde'")
                .count(),
            1
        );
        assert!(rendered.contains("$out/nix-support/unused-crate-dependencies"));
    }

    #[test]
    fn content_addressed_is_explicitly_opt_in() {
        let graph: UnitGraph = serde_json::from_str(
            r#"{
              "version": 1,
              "units": [
                {
                  "pkg_id": "hello 0.1.0 (path+file:///workspace)",
                  "target": {
                    "kind": ["lib"],
                    "crate_types": ["lib"],
                    "name": "hello",
                    "src_path": "/workspace/src/lib.rs",
                    "edition": "2024"
                  },
                  "profile": { "name": "dev", "opt_level": "0" },
                  "mode": "build",
                  "dependencies": []
                }
              ],
              "roots": [0]
            }"#,
        )
        .unwrap();

        let rendered = render_units_nix(
            &graph,
            &RenderOptions {
                workspace_root: PathBuf::from("/workspace"),
                vendor_root: None,
                content_addressed: true,
                toolchain_id: None,
                deny_unused_crate_dependencies: false,
            },
        )
        .unwrap();

        assert!(rendered.contains("__contentAddressed = true"));
        assert!(rendered.contains("outputHashMode = \"recursive\""));
    }
}
