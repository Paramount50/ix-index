use tango_bench::{benchmark_fn, tango_benchmarks, tango_main, IntoBenchmarks};

fn benchmarks() -> impl IntoBenchmarks {
    [benchmark_fn("greeting", |b| {
        b.iter(cargo_unit_hello::greeting)
    })]
}

tango_benchmarks!(benchmarks());
tango_main!();
