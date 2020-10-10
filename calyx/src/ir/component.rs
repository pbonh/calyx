use crate::lang::ast::Id;
use super::{control::Control};
use derivative::Derivative;
use std::collections::HashMap;
use std::rc::{Weak, Rc};
use std::cell::RefCell;

pub type WRC<T> = Weak<RefCell<T>>;
pub type RRC<T> = Rc<RefCell<T>>;

/// Direction of a port on a cell.
pub enum Direction {
    Input,
    Output,
}

/// Represents a port on a cell.
pub struct Port {
    /// Name of the port
    pub id: Id,
    /// Width of the port
    pub width: u64,
    /// Direction of the port
    pub direction: Direction,
    /// Weak pointer to this port's parent
    pub cell: WRC<Cell>,
}

/// The type for a Cell
pub enum CellType {
    /// Cell constructed using a primitive definition
    Primitive,
    /// Cell constructed using a FuTIL component
    Component,
    /// This cell represents the current component
    ThisComponent,
    /// Cell representing a Constant
    Constant,
}

/// Represents an instantiated cell.
// XXX(rachit): Each port should probably have a weak pointer to its parent.
pub struct Cell {
    /// Ports on this cell
    pub ports: Vec<RRC<Port>>,
    /// Underlying type for this cell
    pub prototype: CellType,
}

/// A guard which has pointers to the various ports from which it reads.
pub struct Guard {
    // TODO
    val: RRC<Port>,
}

/// Represents a guarded assignment in the program
pub struct Assignment {
    /// The destination for the assignment.
    pub dst: RRC<Port>,

    /// The source for the assignment.
    pub src: RRC<Port>,

    /// The guard for this assignment.
    pub guard: Option<Guard>,
}

pub struct Group {
    /// Name of this group
    pub name: Id,

    /// The assignments used in this group
    pub assignments: Vec<Assignment>,
}

/// In memory representation of a Component.
//#[derive(Debug, Clone)]
pub struct Component<'a> {
    /// Name of the component.
    pub name: Id,
    ///// The input/output signature of this component.
    pub signature: Cell,
    /// The cells instantiated for this component.
    pub cells: Vec<Cell>,
    ///// Groups of assignment wires.
    ///// Maps the name of a group to the assignments in it.
    pub groups: Vec<Group>,
    ///// The set of "continuous assignments", i.e., assignments that are always
    ///// active.
    //pub continuous_assignments: Vec<Assignment>,
    ///// The control program for this component.
    pub control: Control<'a>,
}
