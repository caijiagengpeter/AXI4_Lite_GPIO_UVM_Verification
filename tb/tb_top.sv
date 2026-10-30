`timescale 1ns/1ps
`default_nettype none

module tb_top;
  import uvm_pkg::*;
  import axi4l_gpio_tb_cfg_pkg::GPIO_NOUT;
  import axi4l_gpio_tb_cfg_pkg::GPIO_NIN;
  import axi4l_gpio_tb_cfg_pkg::GPIO_DEFAULT_OUTPUT;
  import axi4l_agent_pkg::*;
  import axi4l_env_pkg::*;
  import axi4l_test_pkg::*;

  localparam int ADDR_WIDTH = AXI4L_ADDR_WIDTH;
  localparam int DATA_WIDTH = AXI4L_DATA_WIDTH;
  localparam int NOUT       = GPIO_NOUT;
  localparam int NIN        = GPIO_NIN;

  logic            clk;
  logic [NIN-1:0]  i_gpio;
  wire  [NOUT-1:0] o_gpio;
  wire             o_int;

  axi4l_if #(ADDR_WIDTH, DATA_WIDTH) axi_if (.ACLK(clk));
  axi4l_if #(ADDR_WIDTH, DATA_WIDTH) v4_axi_if (.ACLK(clk));
  gpio_if #(NIN, NOUT) gpio_vif (
    .ACLK   (clk),
    .ARESETN(axi_if.ARESETN),
    .i_gpio (i_gpio),
    .o_gpio (o_gpio),
    .o_int  (o_int)
  );

  axilgpio #(
    .C_AXI_ADDR_WIDTH(ADDR_WIDTH),
    .OPT_SKIDBUFFER  (1'b1),
    .OPT_LOWPOWER    (1'b0),
    .NOUT            (NOUT),
    .NIN             (NIN),
    .DEFAULT_OUTPUT  (GPIO_DEFAULT_OUTPUT)
  ) dut (
    .S_AXI_ACLK   (clk),
    .S_AXI_ARESETN(axi_if.ARESETN),
    .S_AXI_AWVALID(axi_if.AWVALID),
    .S_AXI_AWREADY(axi_if.AWREADY),
    .S_AXI_AWADDR (axi_if.AWADDR),
    .S_AXI_AWPROT (axi_if.AWPROT),
    .S_AXI_WVALID (axi_if.WVALID),
    .S_AXI_WREADY (axi_if.WREADY),
    .S_AXI_WDATA  (axi_if.WDATA),
    .S_AXI_WSTRB  (axi_if.WSTRB),
    .S_AXI_BVALID (axi_if.BVALID),
    .S_AXI_BREADY (axi_if.BREADY),
    .S_AXI_BRESP  (axi_if.BRESP),
    .S_AXI_ARVALID(axi_if.ARVALID),
    .S_AXI_ARREADY(axi_if.ARREADY),
    .S_AXI_ARADDR (axi_if.ARADDR),
    .S_AXI_ARPROT (axi_if.ARPROT),
    .S_AXI_RVALID (axi_if.RVALID),
    .S_AXI_RREADY (axi_if.RREADY),
    .S_AXI_RDATA  (axi_if.RDATA),
    .S_AXI_RRESP  (axi_if.RRESP),
    .o_gpio       (o_gpio),
    .i_gpio       (i_gpio),
    .o_int        (o_int)
  );

  axi4l_v4_test_slave #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH),
    .MAX_DEPTH (8)
  ) v4_slave (
    .ACLK(clk), .ARESETN(v4_axi_if.ARESETN),
    .AWADDR(v4_axi_if.AWADDR), .AWPROT(v4_axi_if.AWPROT),
    .AWVALID(v4_axi_if.AWVALID), .AWREADY(v4_axi_if.AWREADY),
    .WDATA(v4_axi_if.WDATA), .WSTRB(v4_axi_if.WSTRB),
    .WVALID(v4_axi_if.WVALID), .WREADY(v4_axi_if.WREADY),
    .BRESP(v4_axi_if.BRESP), .BVALID(v4_axi_if.BVALID),
    .BREADY(v4_axi_if.BREADY),
    .ARADDR(v4_axi_if.ARADDR), .ARPROT(v4_axi_if.ARPROT),
    .ARVALID(v4_axi_if.ARVALID), .ARREADY(v4_axi_if.ARREADY),
    .RDATA(v4_axi_if.RDATA), .RRESP(v4_axi_if.RRESP),
    .RVALID(v4_axi_if.RVALID), .RREADY(v4_axi_if.RREADY),
    .max_write_outstanding(v4_axi_if.test_max_write_outstanding),
    .max_read_outstanding(v4_axi_if.test_max_read_outstanding)
  );

  initial begin
    clk = 1'b0;
    forever #5ns clk = ~clk;
  end

  initial begin
    axi_if.ARESETN = 1'b0;
    v4_axi_if.ARESETN = 1'b0;
    gpio_vif.i_gpio = '0;
    repeat (5) @(posedge clk);
    axi_if.ARESETN <= 1'b1;
    v4_axi_if.ARESETN <= 1'b1;
  end

  initial begin
    if ($test$plusargs("V4_TEST_SLAVE"))
      uvm_config_db#(virtual axi4l_if #(ADDR_WIDTH, DATA_WIDTH))::set(
        null, "*", "vif", v4_axi_if);
    else
      uvm_config_db#(virtual axi4l_if #(ADDR_WIDTH, DATA_WIDTH))::set(
        null, "*", "vif", axi_if);
    uvm_config_db#(virtual gpio_if #(NIN, NOUT))::set(
      null, "*", "gpio_vif", gpio_vif);
    run_test();
  end

  initial begin
    #100us;
    $fatal(1, "Global timeout: smoke test did not finish");
  end
endmodule

`default_nettype wire

