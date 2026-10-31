package axi4l_gpio_tb_cfg_pkg;
  // Keep the DUT and all UVM components on one shared set of widths/defaults.
  parameter int AXI4L_ADDR_WIDTH = 5;
  parameter int AXI4L_DATA_WIDTH = 32;

`ifdef C3_GPIO_NOUT
  parameter int GPIO_NOUT        = `C3_GPIO_NOUT;
`else
  parameter int GPIO_NOUT        = 30;
`endif

`ifdef C3_GPIO_NIN
  parameter int GPIO_NIN         = `C3_GPIO_NIN;
`else
  parameter int GPIO_NIN         = 5;
`endif

`ifdef C3_GPIO_OPT_SKIDBUFFER
  parameter bit GPIO_OPT_SKIDBUFFER = `C3_GPIO_OPT_SKIDBUFFER;
`else
  parameter bit GPIO_OPT_SKIDBUFFER = 1'b1;
`endif

`ifdef C3_GPIO_OPT_LOWPOWER
  parameter bit GPIO_OPT_LOWPOWER = `C3_GPIO_OPT_LOWPOWER;
`else
  parameter bit GPIO_OPT_LOWPOWER = 1'b0;
`endif

`ifdef C3_GPIO_DEFAULT_OUTPUT
  parameter bit [GPIO_NOUT-1:0] GPIO_DEFAULT_OUTPUT = `C3_GPIO_DEFAULT_OUTPUT;
`else
  parameter bit [GPIO_NOUT-1:0] GPIO_DEFAULT_OUTPUT = '0;
`endif
endpackage

