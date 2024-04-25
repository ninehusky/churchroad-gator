use std::path::Path;

use egglog::EGraph;
use churchroad::import_churchroad;

fn main() {
    // Usage: cargo run <verilog_path> <top_module_name> <output_dir>
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!("Usage: cargo run <verilog_path> <top_module_name> <output_dir>");
        std::process::exit(1);
    }

    let verilog_path = &args[1];
    let top_module_name = &args[2];
    let output_dir = &args[3];

    verilog_to_json(std::path::Path::new(verilog_path), top_module_name, std::path::Path::new(output_dir)).unwrap();

    let mut egraph = EGraph::default();
}

pub fn verilog_to_json(
    verilog_module_path: &Path,
    top_module_name: &str,
    output_dir: &Path,
) -> Result<(), std::io::Error> {

    let churchroad_dir_str = std::env::var("CHURCHROAD_DIR").unwrap_or_else(|_| {
        panic!("Please set CHURCHROAD_DIR to the path of the churchroad repository.");
    });
    let churchroad_dir = std::path::Path::new(&churchroad_dir_str);

    let yosys_plugin_path = churchroad_dir.join("yosys-plugin/churchroad.so");

    println!("yosys_plugin_path: {:?}", yosys_plugin_path);

    if !yosys_plugin_path.exists() {
        panic!("Churchroad plugin not found. Please build the plugin first.");
    }

    // run yosys
    let make_churchroad_cmd = std::process::Command::new("yosys")
        .arg("-m")
        .arg(yosys_plugin_path.to_str().unwrap())
        .arg("-q")
        .arg("-p")
        .arg(format!(
            "read_verilog -sv {}; prep -top {}; pmuxtree; write_lakeroad",
            verilog_module_path.to_str().unwrap(),
            top_module_name
        ))
        .output()
        .expect("Failed to run yosys");

    if !make_churchroad_cmd.status.success() {
        panic!(
            "Yosys failed: {}",
            std::str::from_utf8(&make_churchroad_cmd.stderr).unwrap()
        );
    }

    let churchroad_prog = std::str::from_utf8(&make_churchroad_cmd.stdout).unwrap();

    std::fs::write(
        output_dir.join(format!("{}.egg", top_module_name)),
        churchroad_prog,
    )?;

    let mut egraph = egglog::EGraph::default();
    import_churchroad(&mut egraph);
    egraph.parse_and_run_program(churchroad_prog).unwrap();
    // now, run typing information
    egraph
        .parse_and_run_program("(run-schedule (saturate typing))")
        .unwrap();

    let json_file_name = format!("{}_egraph.json", top_module_name);

    let serialized = egraph.serialize(egglog::SerializeConfig::default());
    serialized
        .to_json_file(output_dir.join(json_file_name.clone()))
        .unwrap();

    println!("Output json to {}", json_file_name);

    Ok(())
}
