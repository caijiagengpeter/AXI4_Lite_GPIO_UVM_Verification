package axi4l_agent_types_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  parameter int AXI4L_ADDR_WIDTH =
    axi4l_gpio_tb_cfg_pkg::AXI4L_ADDR_WIDTH;
  parameter int AXI4L_DATA_WIDTH =
    axi4l_gpio_tb_cfg_pkg::AXI4L_DATA_WIDTH;

  `include "axi4l_seq_item.sv"
endpackage
