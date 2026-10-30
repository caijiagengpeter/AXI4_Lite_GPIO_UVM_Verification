package axi4l_coverage_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi4l_gpio_tb_cfg_pkg::AXI4L_ADDR_WIDTH;
  import axi4l_gpio_tb_cfg_pkg::AXI4L_DATA_WIDTH;
  import axi4l_gpio_tb_cfg_pkg::GPIO_NOUT;
  import axi4l_gpio_tb_cfg_pkg::GPIO_NIN;
  import axi4l_agent_pkg::axi4l_seq_item;
  import axi4l_agent_pkg::AXI4L_WRITE;
  import gpio_agent_pkg::gpio_observation;

  `uvm_analysis_imp_decl(_cov_axi_req)
  `uvm_analysis_imp_decl(_cov_gpio)

  `include "axi4l_gpio_coverage.sv"
endpackage
