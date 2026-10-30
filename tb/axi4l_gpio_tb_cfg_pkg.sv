package axi4l_gpio_tb_cfg_pkg;
  // Keep the DUT and all UVM components on one shared set of widths/defaults.
  parameter int AXI4L_ADDR_WIDTH = 5;
  parameter int AXI4L_DATA_WIDTH = 32;
  parameter int GPIO_NOUT        = 30;
  parameter int GPIO_NIN         = 5;

  parameter bit [GPIO_NOUT-1:0] GPIO_DEFAULT_OUTPUT = '0;
endpackage

