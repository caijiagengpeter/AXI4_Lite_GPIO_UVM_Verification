package axi4l_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi4l_gpio_tb_cfg_pkg::GPIO_NOUT;
  import axi4l_gpio_tb_cfg_pkg::GPIO_NIN;
  import axi4l_gpio_tb_cfg_pkg::GPIO_DEFAULT_OUTPUT;
  import axi4l_agent_pkg::*;
  import gpio_agent_pkg::*;
  import axi4l_coverage_pkg::*;

  `uvm_analysis_imp_decl(_axi)
  `uvm_analysis_imp_decl(_axi_req)
  `uvm_analysis_imp_decl(_axi_rsp)
  `uvm_analysis_imp_decl(_gpio)

  `include "axi4l_gpio_scoreboard.sv"
  `include "axi4l_gpio_env.sv"
endpackage

