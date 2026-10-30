package gpio_agent_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi4l_gpio_tb_cfg_pkg::*;

  `include "gpio_seq_item.sv"
  `include "gpio_observation.sv"
  `include "gpio_sequencer.sv"
  `include "gpio_driver.sv"
  `include "gpio_monitor.sv"
  `include "gpio_agent.sv"
endpackage
