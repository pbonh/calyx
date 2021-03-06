//! Defines update methods for the various primitive cells in the Calyx standard library.
use super::environment::Environment;
use calyx::{errors::FutilResult, ir};

/// Uses the cell's inputs ports to perform any required updates to the
/// cell's output ports.
/// TODO: how to get input and output ports in general? How to "standardize" for combinational or not operations
pub fn update_cell_state(
    cell: &ir::Id,
    inputs: &[ir::Id],
    output: &[ir::Id],
    env: &Environment, // should this be a reference
) -> FutilResult<Environment> {
    // get the actual cell, based on the id
    // let cell_r = cell.as_ref();

    let mut new_env = env.clone();

    let cell_r = new_env
        .get_cell(cell)
        .unwrap_or_else(|| panic!("Cannot find cell with name"));

    let temp = cell_r.borrow();

    // get the cell type
    let cell_type = temp.type_name().unwrap_or_else(|| panic!("Futil Const?"));

    match cell_type.id.as_str() {
        "std_reg" => {
            let write_en = ir::Id::from("write_en");

            // register's write_en must be high to write reg.out and reg.done
            if new_env.get(&cell, &write_en) != 0 {
                let out = ir::Id::from("out"); //assuming reg.in = cell.out, always
                let inp = ir::Id::from("in"); //assuming reg.in = cell.out, always
                let done = ir::Id::from("done"); //done id

                new_env.put(cell, &output[0], env.get(&inputs[0], &out)); //reg.in = cell.out; should this be in init?

                if output[0].id == "in" {
                    new_env.put(cell, &out, new_env.get(cell, &inp)); // reg.out = reg.in
                    new_env.put(cell, &done, 1); // reg.done = 1'd1
                    new_env.remove_update(cell); // remove from update queue
                }
            }
        }
        "std_sqrt" => {
            //TODO; wrong implementation
            new_env.put(
                cell,
                &output[0],
                ((new_env.get(cell, &inputs[0]) as f64).sqrt()) as u64, // cast to f64 to use sqrt
            );
        }
        "std_add" => new_env.put(
            cell,
            &output[0],
            new_env.get(cell, &inputs[0]) + env.get(cell, &inputs[1]),
        ),
        "std_sub" => new_env.put(
            cell,
            &output[0],
            new_env.get(cell, &inputs[0]) - env.get(cell, &inputs[1]),
        ),
        "std_mod" => {
            if env.get(cell, &inputs[1]) != 0 {
                new_env.put(
                    cell,
                    &output[0],
                    new_env.get(cell, &inputs[0]) % env.get(cell, &inputs[1]),
                )
            }
        }
        "std_mult" => new_env.put(
            cell,
            &output[0],
            new_env.get(cell, &inputs[0]) * env.get(cell, &inputs[1]),
        ),
        "std_div" => {
            // need this condition to avoid divide by 0
            // (e.g. if only one of left/right ports has been updated from the initial nonzero value?)
            // TODO: what if the program specifies a divide by 0? how to catch??
            if env.get(cell, &inputs[1]) != 0 {
                new_env.put(
                    cell,
                    &output[0],
                    new_env.get(cell, &inputs[0]) / env.get(cell, &inputs[1]),
                )
            }
        }
        "std_not" => {
            new_env.put(cell, &output[0], !new_env.get(cell, &inputs[0]))
        }
        "std_and" => new_env.put(
            cell,
            &output[0],
            new_env.get(cell, &inputs[0]) & env.get(cell, &inputs[1]),
        ),
        "std_or" => new_env.put(
            cell,
            &output[0],
            new_env.get(cell, &inputs[0]) | env.get(cell, &inputs[1]),
        ),
        "std_xor" => new_env.put(
            cell,
            &output[0],
            new_env.get(cell, &inputs[0]) ^ env.get(cell, &inputs[1]),
        ),
        "std_gt" => new_env.put(
            cell,
            &output[0],
            (new_env.get(cell, &inputs[0]) > env.get(cell, &inputs[1])) as u64,
        ),
        "std_lt" => new_env.put(
            cell,
            &output[0],
            (new_env.get(cell, &inputs[0]) > env.get(cell, &inputs[1])) as u64,
        ),
        "std_eq" => new_env.put(
            cell,
            &output[0],
            (new_env.get(cell, &inputs[0]) == env.get(cell, &inputs[1])) as u64,
        ),
        "std_neq" => new_env.put(
            cell,
            &output[0],
            (new_env.get(cell, &inputs[0]) != env.get(cell, &inputs[1])) as u64,
        ),
        "std_ge" => new_env.put(
            cell,
            &output[0],
            (new_env.get(cell, &inputs[0]) >= env.get(cell, &inputs[1])) as u64,
        ),
        "std_le" => new_env.put(
            cell,
            &output[0],
            (new_env.get(cell, &inputs[0]) <= env.get(cell, &inputs[1])) as u64,
        ),
        _ => unimplemented!("{}", cell_type),
    }

    // TODO
    Ok(new_env)
}
