package axi4l_agent_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi4l_agent_types_pkg::*;
  import axi4l_v4_lifecycle_pkg::*;

  // Explicit aliases preserve the historical axi4l_agent_pkg public API;
  // SystemVerilog wildcard imports are not automatically re-exported.
  parameter int AXI4L_ADDR_WIDTH = axi4l_agent_types_pkg::AXI4L_ADDR_WIDTH;
  parameter int AXI4L_DATA_WIDTH = axi4l_agent_types_pkg::AXI4L_DATA_WIDTH;
  typedef axi4l_agent_types_pkg::axi4l_access_e axi4l_access_e;
  typedef axi4l_agent_types_pkg::axi4l_seq_item axi4l_seq_item;
  localparam axi4l_access_e AXI4L_READ  = axi4l_agent_types_pkg::AXI4L_READ;
  localparam axi4l_access_e AXI4L_WRITE = axi4l_agent_types_pkg::AXI4L_WRITE;

  `include "axi4l_coverage_observation.sv"
  `include "axi4l_sequencer.sv"
  `include "axi4l_driver.sv"
  `include "axi4l_monitor.sv"
  `include "axi4l_agent.sv"
endpackage

